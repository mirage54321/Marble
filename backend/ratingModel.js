'use strict';

const FOREVER_DAYS = 1e9;

const DEFAULT_RATING_PARAMS = {
  mode: 'online',
  update: 'lms',
  lr: 0.15,
  playoffFactor: 0.5,
  lrDecayMatches: FOREVER_DAYS,
  halfLifeDays: 60,
  priorWeight: 3,
  carry: 0,
  defense: 0,
  ridgeLambda: 5,
  tau: 0.35,
  noiseRel: 0.25,
  drift: 0.03,
  beta: 0,
  foul: 0,
  epaWeight: 0,
};

const TUNING_GRID = {
  mode: ['online', 'ridge'],
  update: ['lms', 'kalman'],
  halfLifeDays: [30, 60, 120, FOREVER_DAYS],
  priorWeight: [1, 3, 8],
  carry: [0, 0.5, 1],
  epaWeight: [0, 0.5, 1],
  playoffFactor: [0.5, 1],
  lr: [0.05, 0.1, 0.15, 0.25, 0.4],
  lrDecayMatches: [4, 8, 16, FOREVER_DAYS],
  defense: [0, 0.3, 0.6],
  ridgeLambda: [2, 5, 12],
  tau: [0.2, 0.35, 0.5],
  noiseRel: [0.15, 0.25, 0.4],
  drift: [0, 0.03, 0.08],
  beta: [0, 0.3, 0.6],
  foul: [0, 0.5, 1],
};

const LEGACY_KEYS = new Set([
  'mode', 'halfLifeDays', 'priorWeight', 'carry', 'playoffFactor',
  'lr', 'lrDecayMatches', 'defense', 'ridgeLambda',
]);

const RIDGE_REFIT_EVERY = 3;
const MIN_TUNING_GAMES = 200;
const MIN_HOLDOUT_GAMES = 300;
const DEFAULT_WIN_PROB_SCALE = 20;
const WIN_PROB_SCALE_CANDIDATES = [4, 6, 8, 10, 12, 15, 18, 22, 26, 32, 40, 50, 65, 80, 100, 130];
const LEVEL_ORDER = { p: 0, qm: 1, ef: 2, qf: 3, sf: 4, f: 5 };
const MS_PER_DAY = 86400000;
const LIVE_RATINGS_TTL_MS = 60 * 1000;
const KALMAN_WEIGHT_SCALE = 6;
const KALMAN_MIN_VAR_REL = 0.03;
const FOUL_LR = 0.3;
const FOUL_CARRY = 0.5;
const MIN_ENSEMBLE_GAIN = 0.0005;

function winProbability(margin, scale) {
  const s = scale > 0 ? scale : DEFAULT_WIN_PROB_SCALE;
  return 1 / (1 + Math.exp(-margin / s));
}

function hashString(text) {
  let h = 0;
  for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) >>> 0;
  return h;
}

function ownPoints(match, color) {
  const raw = match.alliances?.[color]?.score;
  if (typeof raw !== 'number' || raw < 0) return null;
  const foul = match.score_breakdown?.[color]?.foulPoints;
  return typeof foul === 'number' ? raw - foul : raw;
}

function awardedFouls(match, color) {
  const foul = match.score_breakdown?.[color]?.foulPoints;
  return typeof foul === 'number' ? foul : null;
}

function slimMatch(m) {
  const redScore = m.alliances?.red?.score;
  const blueScore = m.alliances?.blue?.score;
  const played = typeof redScore === 'number' && typeof blueScore === 'number' && redScore >= 0 && blueScore >= 0;
  const redFoul = played ? awardedFouls(m, 'red') : null;
  const blueFoul = played ? awardedFouls(m, 'blue') : null;
  return {
    level: m.comp_level,
    set: m.set_number || 0,
    num: m.match_number || 0,
    red: m.alliances?.red?.team_keys || [],
    blue: m.alliances?.blue?.team_keys || [],
    redScore: played ? redScore : null,
    blueScore: played ? blueScore : null,
    redOwn: played ? ownPoints(m, 'red') : null,
    blueOwn: played ? ownPoints(m, 'blue') : null,
    redFoul,
    blueFoul,
  };
}

function eventSeasonData(event, rows, rawMatches) {
  return {
    event,
    rows,
    matches: (Array.isArray(rawMatches) ? rawMatches : []).map(slimMatch),
    startMs: Date.parse(`${event.start_date}T00:00:00Z`),
    endMs: Date.parse(`${event.end_date}T23:59:59Z`),
  };
}

function solveSPD(matrix, rhs, n) {
  const L = new Float64Array(n * n);
  for (let i = 0; i < n; i++) {
    for (let j = 0; j <= i; j++) {
      let sum = matrix[i * n + j];
      for (let k = 0; k < j; k++) sum -= L[i * n + k] * L[j * n + k];
      if (i === j) L[i * n + i] = Math.sqrt(Math.max(sum, 1e-9));
      else L[i * n + j] = sum / L[j * n + j];
    }
  }
  const y = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let sum = rhs[i];
    for (let k = 0; k < i; k++) sum -= L[i * n + k] * y[k];
    y[i] = sum / L[i * n + i];
  }
  const x = new Float64Array(n);
  for (let i = n - 1; i >= 0; i--) {
    let sum = y[i];
    for (let k = i + 1; k < n; k++) sum -= L[k * n + i] * x[k];
    x[i] = sum / L[i * n + i];
  }
  return x;
}

function priorZ(teamNumber, params, prev) {
  const z1 = prev.z?.[teamNumber];
  const z2 = prev.zEpa?.[teamNumber];
  const w = params.epaWeight || 0;
  if (!(w > 0)) return z1;
  if (z1 === undefined) return z2;
  if (z2 === undefined) return z1;
  return (1 - w) * z1 + w * z2;
}

function seasonPrior(teamKey, base, params, prev) {
  if (!prev || !(base > 0) || !(params.carry > 0)) return null;
  const z = priorZ(teamKey.replace(/^frc/, ''), params, prev);
  if (z === undefined) return null;
  return Math.max(0.2 * base, base * (1 + params.carry * prev.cv * z));
}

function zScores(entries) {
  const vals = entries.filter(([, v]) => Number.isFinite(v));
  if (vals.length < 100) return null;
  const mean = vals.reduce((t, [, v]) => t + v, 0) / vals.length;
  const sd = Math.sqrt(vals.reduce((t, [, v]) => t + (v - mean) ** 2, 0) / vals.length);
  if (!(sd > 0)) return null;
  const z = {};
  for (const [num, v] of vals) z[num] = Number(((v - mean) / sd).toFixed(3));
  return z;
}

function extractEpa(row) {
  const candidates = [
    row?.epa?.total_points?.mean,
    row?.epa?.norm,
    row?.epa?.unitless,
    row?.epa?.end,
    row?.norm_epa,
    row?.epa_end,
    row?.epa_mean,
  ];
  for (const v of candidates) if (typeof v === 'number' && Number.isFinite(v)) return v;
  return null;
}

async function fetchEpaPrior(getJson, seasonYear) {
  const entries = [];
  for (let offset = 0; offset < 8000; offset += 1000) {
    const rows = await getJson(`https://api.statbotics.io/v3/team_years?year=${seasonYear}&limit=1000&offset=${offset}`);
    if (!Array.isArray(rows) || rows.length === 0) break;
    for (const row of rows) {
      const team = row?.team ?? row?.team_number;
      const epa = extractEpa(row);
      if (team !== undefined && epa !== null) entries.push([String(team), epa]);
    }
    if (rows.length < 1000) break;
  }
  const z = zScores(entries);
  return z ? { z } : null;
}

async function collectEventData(year, fetchers, { withRows = true } = {}) {
  const { tbaGet, tbaGetOprs, mapWithConcurrency } = fetchers;
  const events = await tbaGet(`/events/${year}/simple`);
  const official = events.filter((event) =>
    [0, 1, 2, 3, 4].includes(event.event_type) && event.start_date && event.end_date &&
    new Date(`${event.end_date}T23:59:59Z`) <= new Date());
  return mapWithConcurrency(official, 6, async (event) => {
    if (!withRows) return eventSeasonData(event, [], await tbaGet(`/event/${event.key}/matches`));
    const [teams, oprData, rankings, rawMatches] = await Promise.all([
      tbaGet(`/event/${event.key}/teams/simple`),
      tbaGetOprs(event.key),
      tbaGet(`/event/${event.key}/rankings`).catch(() => ({ rankings: [] })),
      tbaGet(`/event/${event.key}/matches`).catch(() => []),
    ]);
    const names = new Map(teams.map((team) => [team.key, team.nickname || `Team ${team.team_number}`]));
    const records = new Map((rankings.rankings || []).map((r) => [r.team_key, r.record || {}]));
    const rows = Object.entries(oprData.oprs || {}).map(([teamKey, rawOpr]) => {
      const record = records.get(teamKey) || {};
      const playedCount = (record.wins || 0) + (record.losses || 0) + (record.ties || 0);
      return {
        teamKey, name: names.get(teamKey) || `Team ${teamKey.replace(/^frc/, '')}`,
        opr: Number(rawOpr || 0), weight: Math.max(1, playedCount),
        wins: record.wins || 0, losses: record.losses || 0, ties: record.ties || 0,
      };
    });
    return eventSeasonData(event, rows, rawMatches);
  });
}

function buildPriorSeason(eventData) {
  if (!eventData.length) return null;
  const run = runSeasonModel(eventData, { ...DEFAULT_RATING_PARAMS }, {});
  const refMs = eventData.reduce((latest, d) => Math.max(latest, d.endMs), 0) + MS_PER_DAY;
  const ratings = [];
  for (const [teamKey, hist] of run.history) {
    const { s, w } = decayedHistory(hist, refMs, 120);
    if (w >= 4) ratings.push([teamKey.replace(/^frc/, ''), s / w]);
  }
  if (ratings.length < 100) return null;
  const mean = ratings.reduce((total, r) => total + r[1], 0) / ratings.length;
  const sd = Math.sqrt(ratings.reduce((total, r) => total + (r[1] - mean) ** 2, 0) / ratings.length);
  if (!(mean > 0) || !(sd > 0)) return null;
  const z = {};
  for (const [number, rating] of ratings) z[number] = Number(((rating - mean) / sd).toFixed(3));
  return { z, cv: Number((sd / mean).toFixed(4)) };
}

function replayEvent(matches, priorFn, meanFn, params, hooks, ctx = {}) {
  const live = new Map();
  const played = new Map();
  const defense = new Map();
  const hasPrior = new Set();
  const ridge = params.mode === 'ridge';
  const kalman = !ridge && params.update === 'kalman';
  const foulWeight = params.foul > 0 ? params.foul : 0;
  const lrPlayoff = params.lr * params.playoffFactor;
  const qualCount = matches.filter((m) => m.level === 'qm').length || 1;
  let eventPoints = 0;
  let eventSlots = 0;
  let playoffShift = 0;
  let playoffCount = 0;
  const out = { games: 0, correct: 0, marginErr: 0, ratings: live, played, foul: null, foulSides: 0, effective: null };

  const baseNow = () => {
    const mean = meanFn();
    return mean > 0 ? mean : (eventSlots > 0 ? eventPoints / eventSlots : 0);
  };
  const startingRating = (teamKey) => {
    const base = baseNow();
    const prior = priorFn(teamKey, base);
    if (prior !== null && prior !== undefined) {
      hasPrior.add(teamKey);
      return prior;
    }
    return base;
  };
  const ratingFor = (teamKey) => {
    if (live.has(teamKey)) return live.get(teamKey);
    const rating = startingRating(teamKey);
    live.set(teamKey, rating);
    return rating;
  };
  const sumOf = (keys) => keys.reduce((total, key) => total + ratingFor(key), 0);
  const defenseOf = (keys) => keys.reduce((total, key) => total + (defense.get(key) || 0), 0);

  const varOf = new Map();
  const varFor = (teamKey) => {
    if (!varOf.has(teamKey)) {
      const base = Math.max(baseNow(), 1);
      const w = ctx.weightFn ? ctx.weightFn(teamKey) || 0 : 0;
      varOf.set(teamKey, (params.tau * base) ** 2 / (1 + w / KALMAN_WEIGHT_SCALE));
    }
    return varOf.get(teamKey);
  };

  const foulLive = new Map();
  const foulSeen = new Map();
  let foulTotal = 0;
  let foulSides = 0;
  const foulOf = (teamKey) => {
    if (!foulLive.has(teamKey)) foulLive.set(teamKey, ctx.foulPriorFn ? ctx.foulPriorFn(teamKey) || 0 : 0);
    return foulLive.get(teamKey);
  };
  const foulSum = (keys) => keys.reduce((total, key) => total + foulOf(key), 0);

  let teamIndex = null;
  let normal = null;
  let target = null;
  let teamCount = 0;
  let dirty = false;
  let sinceSolve = 0;
  const solve = () => {
    if (teamCount === 0) return;
    const system = Float64Array.from(normal);
    const rhs = new Float64Array(teamCount);
    for (const [teamKey, i] of teamIndex) {
      system[i * teamCount + i] += params.ridgeLambda;
      rhs[i] = target[i] + params.ridgeLambda * startingRating(teamKey);
    }
    const x = solveSPD(system, rhs, teamCount);
    for (const [teamKey, i] of teamIndex) live.set(teamKey, x[i]);
    dirty = false;
    sinceSolve = 0;
  };
  if (ridge) {
    teamIndex = new Map();
    for (const m of matches) {
      for (const key of [...m.red, ...m.blue]) if (!teamIndex.has(key)) teamIndex.set(key, teamIndex.size);
    }
    teamCount = teamIndex.size;
    normal = new Float64Array(teamCount * teamCount);
    target = new Float64Array(teamCount);
    solve();
  }

  const ordered = [...matches].sort((a, b) =>
    ((LEVEL_ORDER[a.level] ?? 9) - (LEVEL_ORDER[b.level] ?? 9)) || (a.set - b.set) || (a.num - b.num));

  for (const m of ordered) {
    if (m.redScore === null || m.blueScore === null || m.level === 'p') continue;
    if (ridge && dirty && sinceSolve >= RIDGE_REFIT_EVERY) solve();

    const redPred = sumOf(m.red) - defenseOf(m.blue);
    const bluePred = sumOf(m.blue) - defenseOf(m.red);
    const foulMargin = foulWeight > 0 ? foulWeight * (foulSum(m.blue) - foulSum(m.red)) : 0;
    const margin = redPred - bluePred + foulMargin;

    if (m.redScore !== m.blueScore && margin !== 0) {
      const redWon = m.redScore > m.blueScore;
      const correct = (margin > 0) === redWon;
      out.games += 1;
      if (correct) out.correct += 1;
      out.marginErr += Math.abs(margin - (m.redScore - m.blueScore));
      if (hooks?.preds) hooks.preds.push(margin, redWon ? 1 : 0);
      if (hooks?.onGame) {
        const unseen = [...m.red, ...m.blue].filter((key) => !hasPrior.has(key)).length;
        hooks.onGame({
          id: `${m.level}${m.set}-${m.num}`,
          level: m.level, num: m.num, qualCount, correct, redWon,
          margin, avg: (redPred + bluePred) / 2, unseen,
          actual: m.redScore - m.blueScore,
        });
      }
    }

    if (typeof m.redFoul === 'number' && typeof m.blueFoul === 'number') {
      const foulMean = foulSides > 0 ? foulTotal / foulSides : 0;
      for (const [keys, committed] of [[m.red, m.blueFoul], [m.blue, m.redFoul]]) {
        const size = Math.max(1, keys.length);
        const err = committed - (foulMean + foulSum(keys));
        for (const key of keys) {
          const seen = foulSeen.get(key) || 0;
          const lr = Math.max(FOUL_LR * 0.25, FOUL_LR / (1 + seen / 8));
          foulLive.set(key, foulOf(key) + lr * err / size);
          foulSeen.set(key, seen + 1);
        }
        foulTotal += committed;
        foulSides += 1;
      }
    }

    const playoff = m.level !== 'qm';
    const baseLr = playoff ? lrPlayoff : params.lr;
    const sides = [
      { keys: m.red, opp: m.blue, own: m.redOwn, pred: redPred },
      { keys: m.blue, opp: m.red, own: m.blueOwn, pred: bluePred },
    ];
    const rawErrors = [];
    for (const side of sides) {
      const own = side.own ?? 0;
      const rawErr = own - side.pred;
      rawErrors.push(rawErr);
      const err = playoff ? rawErr - playoffShift : rawErr;
      const size = Math.max(1, side.keys.length);
      if (ridge) {
        const weight = playoff ? params.playoffFactor : 1;
        const y = own - (playoff ? playoffShift : 0);
        for (const a of side.keys) {
          const i = teamIndex.get(a);
          target[i] += weight * y;
          for (const b of side.keys) normal[i * teamCount + teamIndex.get(b)] += weight;
        }
      } else if (kalman) {
        const base = Math.max(baseNow(), 1);
        const noise = (params.noiseRel * base * size) ** 2 / (playoff ? Math.max(params.playoffFactor, 0.1) : 1);
        const variances = side.keys.map(varFor);
        const total = variances.reduce((a, b) => a + b, 0) + noise;
        const drift = (params.drift * base) ** 2;
        const floor = (KALMAN_MIN_VAR_REL * base) ** 2;
        side.keys.forEach((key, i) => {
          const gain = variances[i] / total;
          live.set(key, ratingFor(key) + gain * err);
          varOf.set(key, Math.max(floor, variances[i] * (1 - gain)) + drift);
        });
      } else {
        for (const key of side.keys) {
          const seen = played.get(key) || 0;
          const lr = Math.max(baseLr * 0.2, baseLr / (1 + seen / params.lrDecayMatches));
          live.set(key, ratingFor(key) + lr * err / size);
          if (params.defense > 0) {
            for (const oppKey of side.opp) {
              defense.set(oppKey, (defense.get(oppKey) || 0) - lr * params.defense * err / (size * size));
            }
          }
        }
      }
      for (const key of side.keys) played.set(key, (played.get(key) || 0) + 1);
      eventPoints += own;
      eventSlots += side.keys.length;
    }
    if (ridge) {
      dirty = true;
      sinceSolve += 1;
    }
    if (playoff) {
      for (const e of rawErrors) {
        playoffCount += 1;
        playoffShift += (e - playoffShift) / playoffCount;
      }
    }
  }
  if (ridge && dirty) solve();

  out.foul = foulLive;
  out.foulSides = foulSides;

  out.effective = (key) => ratingFor(key) + (defense.get(key) || 0) - foulWeight * (foulLive.get(key) || 0);
  return out;
}

function decayedHistory(hist, refMs, halfLifeDays) {
  let s = 0;
  let w = 0;
  for (const h of hist) {
    if (h.endMs >= refMs) continue;
    const decay = Math.pow(0.5, (refMs - h.endMs) / MS_PER_DAY / halfLifeDays);
    s += h.rating * h.weight * decay;
    w += h.weight * decay;
  }
  return { s, w };
}

function runSeasonModel(eventData, params, options = {}) {
  const { prev = null, isHoldout = null, collect = false, onGame = null } = options;
  const ordered = [...eventData].sort((a, b) => a.startMs - b.startMs || a.endMs - b.endMs);
  const firstStart = ordered.length ? ordered[0].startMs : 0;
  const history = new Map();
  const foulCarry = new Map();
  const makeTally = () => ({ games: 0, correct: 0, marginErr: 0, events: 0, preds: collect ? [] : null });
  const tune = makeTally();
  const hold = makeTally();
  const beta = params.beta > 0 ? params.beta : 0;

  for (const d of ordered) {
    const held = Boolean(isHoldout && isHoldout(d));
    const tally = held ? hold : tune;
    const priors = new Map();
    let meanSum = 0;
    for (const [teamKey, hist] of history) {
      const { s, w } = decayedHistory(hist, d.startMs, params.halfLifeDays);
      if (w > 0) { priors.set(teamKey, { s, w }); meanSum += s / w; }
    }
    const mean = priors.size ? meanSum / priors.size : 0;
    const priorFn = (teamKey, base) => {
      const p = priors.get(teamKey);
      const seasonal = seasonPrior(teamKey, base, params, prev);
      if (p) return (p.s + (seasonal ?? mean) * params.priorWeight) / (p.w + params.priorWeight);
      return seasonal;
    };
    const week = Math.floor((d.startMs - firstStart) / (7 * MS_PER_DAY)) + 1;

    const res = replayEvent(d.matches, priorFn, () => mean, params, {
      preds: tally.preds,
      onGame: onGame ? (g) => onGame({ ...g, week, event: d.event.key, holdout: held }) : null,
    }, {
      weightFn: (teamKey) => priors.get(teamKey)?.w || 0,
      foulPriorFn: (teamKey) => foulCarry.get(teamKey) || 0,
    });
    tally.games += res.games;
    tally.correct += res.correct;
    tally.marginErr += res.marginErr;
    if (res.games > 0) tally.events += 1;

    if (res.foulSides > 0) {
      for (const [teamKey, value] of res.foul) {
        foulCarry.set(teamKey, FOUL_CARRY * (foulCarry.get(teamKey) || 0) + (1 - FOUL_CARRY) * value);
      }
    }

    const oprMap = new Map(d.rows.map((row) => [row.teamKey, row.opr]));
    let shift = 0;
    if (beta > 0) {
      let onSum = 0;
      let oprSum = 0;
      let n = 0;
      for (const [teamKey] of res.played) {
        const opr = oprMap.get(teamKey);
        const online = res.ratings.get(teamKey);
        if (opr !== undefined && Number.isFinite(online)) { onSum += online; oprSum += opr; n += 1; }
      }
      shift = n > 0 ? (onSum - oprSum) / n : 0;
    }

    const seen = new Set();
    for (const [teamKey, count] of res.played) {
      seen.add(teamKey);
      if (!history.has(teamKey)) history.set(teamKey, []);
      const online = res.ratings.get(teamKey);
      const opr = oprMap.get(teamKey);
      const rating = beta > 0 && opr !== undefined ? (1 - beta) * online + beta * (opr + shift) : online;
      history.get(teamKey).push({ endMs: d.endMs, rating, weight: count });
    }
    for (const row of d.rows) {
      if (seen.has(row.teamKey)) continue;
      if (!history.has(row.teamKey)) history.set(row.teamKey, []);
      history.get(row.teamKey).push({ endMs: d.endMs, rating: row.opr, weight: row.weight });
    }
  }
  return { history, tune, hold, foulCarry };
}

function fitWinProbScale(preds) {
  const n = preds ? preds.length / 2 : 0;
  if (n < 50) return { scale: DEFAULT_WIN_PROB_SCALE, loss: Infinity };
  let bestScale = DEFAULT_WIN_PROB_SCALE;
  let bestLoss = Infinity;
  for (const scale of WIN_PROB_SCALE_CANDIDATES) {
    let loss = 0;
    for (let i = 0; i < preds.length; i += 2) {
      const p = Math.min(0.999, Math.max(0.001, winProbability(preds[i], scale)));
      loss -= preds[i + 1] ? Math.log(p) : Math.log(1 - p);
    }
    if (loss < bestLoss) { bestLoss = loss; bestScale = scale; }
  }
  return { scale: bestScale, loss: bestLoss / n };
}

function scorePreds(preds, scale) {
  const n = preds ? preds.length / 2 : 0;
  if (n === 0) return { logLoss: null, brier: null };
  let loss = 0;
  let brier = 0;
  for (let i = 0; i < preds.length; i += 2) {
    const p = Math.min(0.999, Math.max(0.001, winProbability(preds[i], scale)));
    const y = preds[i + 1];
    loss -= y ? Math.log(p) : Math.log(1 - p);
    brier += (p - y) * (p - y);
  }
  return { logLoss: Number((loss / n).toFixed(4)), brier: Number((brier / n).toFixed(4)) };
}

function combineTallies(a, b) {
  return {
    games: a.games + b.games,
    correct: a.correct + b.correct,
    marginErr: a.marginErr + b.marginErr,
    events: a.events + b.events,
    preds: a.preds && b.preds ? a.preds.concat(b.preds) : null,
  };
}

function runEnsemble(eventData, paramsList, options = {}) {
  const { prev = null, isHoldout = null, onGame = null } = options;
  const games = new Map();
  const runs = paramsList.map((params) => runSeasonModel(eventData, params, {
    prev, isHoldout,
    onGame: (g) => {
      const id = `${g.event}|${g.id}`;
      const list = games.get(id);
      if (list) list.push(g); else games.set(id, [g]);
    },
  }));

  const makeTally = () => ({ games: 0, correct: 0, marginErr: 0, events: 0, preds: [], eventSet: new Set() });
  const tune = makeTally();
  const hold = makeTally();
  for (const list of games.values()) {
    if (list.length !== paramsList.length) continue;
    const g0 = list[0];
    const margin = list.reduce((t, g) => t + g.margin, 0) / list.length;
    if (margin === 0) continue;
    const avg = list.reduce((t, g) => t + g.avg, 0) / list.length;
    const correct = (margin > 0) === g0.redWon;
    const tally = g0.holdout ? hold : tune;
    tally.games += 1;
    if (correct) tally.correct += 1;
    tally.marginErr += Math.abs(margin - g0.actual);
    tally.preds.push(margin, g0.redWon ? 1 : 0);
    tally.eventSet.add(g0.event);
    if (onGame) onGame({ ...g0, margin, avg, correct });
  }
  tune.events = tune.eventSet.size;
  hold.events = hold.eventSet.size;
  return { tune, hold, runs };
}

function paramApplies(params, key) {
  const ridge = params.mode === 'ridge';
  const kalman = !ridge && params.update === 'kalman';
  if (key === 'update') return !ridge;
  if (key === 'lr' || key === 'lrDecayMatches' || key === 'defense') return !ridge && !kalman;
  if (key === 'tau' || key === 'noiseRel' || key === 'drift') return kalman;
  if (key === 'ridgeLambda') return ridge;
  return true;
}

async function tuneRatingParams(eventData, prev, isHoldout, opts = {}) {
  const { seed = {}, lockMode = null, deadline = Infinity, allowedKeys = null } = opts;
  const memo = new Map();
  const evaluate = async (params) => {
    const key = JSON.stringify(params);
    if (memo.has(key)) return memo.get(key);
    const run = runSeasonModel(eventData, params, { prev, isHoldout, collect: true });
    const result = { params, games: run.tune.games, loss: fitWinProbScale(run.tune.preds).loss };
    memo.set(key, result);
    await new Promise((resolve) => setImmediate(resolve));
    return result;
  };

  const start = { ...DEFAULT_RATING_PARAMS, ...seed, ...(lockMode ? { mode: lockMode } : {}) };
  let best = await evaluate(start);
  if (best.games < MIN_TUNING_GAMES) return best;
  for (let pass = 0; pass < 2; pass++) {
    let improved = false;
    for (const key of Object.keys(TUNING_GRID)) {
      if (Date.now() > deadline) return best;
      if (allowedKeys && !allowedKeys.has(key)) continue;
      if (!paramApplies(best.params, key)) continue;
      let options = TUNING_GRID[key];
      if (key === 'mode' && lockMode) options = [lockMode];
      else if (key === 'carry' && !prev) options = [0];
      else if (key === 'epaWeight' && !prev?.zEpa) options = [0];
      for (const value of options) {
        if (value === best.params[key]) continue;
        if (Date.now() > deadline) return best;
        const candidate = await evaluate({ ...best.params, [key]: value });
        if (candidate.loss < best.loss - 1e-9) {
          best = candidate;
          improved = true;
        }
      }
    }
    if (!improved) break;
  }
  return best;
}

async function tuneEnsemble(eventData, prev, isHoldout, opts = {}) {
  const budgetMs = opts.budgetMs ?? 6 * 60 * 1000;
  const start = Date.now();
  const a = await tuneRatingParams(eventData, prev, isHoldout, { lockMode: 'online', deadline: start + budgetMs * 0.5 });
  const b = await tuneRatingParams(eventData, prev, isHoldout, { seed: a.params, lockMode: 'ridge', deadline: start + budgetMs * 0.85 });
  const singles = [a, b].sort((x, y) => x.loss - y.loss);
  let members = [singles[0].params];
  let ensembleLoss = null;
  if (Number.isFinite(a.loss) && Number.isFinite(b.loss)) {
    const ens = runEnsemble(eventData, [a.params, b.params], { prev, isHoldout });
    ensembleLoss = fitWinProbScale(ens.tune.preds).loss;
    if (ensembleLoss < singles[0].loss - MIN_ENSEMBLE_GAIN) members = [a.params, b.params];
  }
  return { members, singleLoss: singles[0].loss, ensembleLoss };
}

function createBreakdown() {
  const groups = ['Event week', 'Stage', 'Qual progress', 'Predicted gap', 'Teams without history'];
  const rows = new Map();
  const add = (group, label, order, correct) => {
    const key = `${group}|${label}`;
    const row = rows.get(key) || { group, label, order, games: 0, correct: 0 };
    row.games += 1;
    if (correct) row.correct += 1;
    rows.set(key, row);
  };
  return {
    record(g) {
      add('Event week', `Week ${g.week}`, g.week, g.correct);
      add('Stage', g.level === 'qm' ? 'Qualifications' : 'Playoffs', g.level === 'qm' ? 0 : 1, g.correct);
      if (g.level === 'qm') {
        const fraction = g.num / g.qualCount;
        const idx = fraction <= 1 / 3 ? 0 : fraction <= 2 / 3 ? 1 : 2;
        add('Qual progress', ['First third', 'Middle third', 'Last third'][idx], idx, g.correct);
      }
      const gap = g.avg > 0 ? Math.abs(g.margin) / g.avg : 0;
      const gapIdx = gap < 0.05 ? 0 : gap < 0.15 ? 1 : gap < 0.3 ? 2 : 3;
      add('Predicted gap', ['Under 5%', '5-15%', '15-30%', 'Over 30%'][gapIdx], gapIdx, g.correct);
      const unseenIdx = g.unseen === 0 ? 0 : g.unseen <= 2 ? 1 : 2;
      add('Teams without history', ['None', '1-2 teams', '3+ teams'][unseenIdx], unseenIdx, g.correct);
    },
    rows() {
      return [...rows.values()]
        .filter((row) => row.games >= 10)
        .sort((a, b) => groups.indexOf(a.group) - groups.indexOf(b.group) || a.order - b.order)
        .map((row) => ({
          group: row.group,
          label: row.label,
          games: row.games,
          accuracyPct: Number(((row.correct / row.games) * 100).toFixed(1)),
        }));
    },
  };
}

function snapshotMember(run, params, prev, nowMs) {
  const decayed = new Map();
  let meanSum = 0;
  for (const [teamKey, hist] of run.history) {
    const { s, w } = decayedHistory(hist, nowMs, params.halfLifeDays);
    if (w > 0) { decayed.set(teamKey, { s, w }); meanSum += s / w; }
  }
  const mean = decayed.size ? meanSum / decayed.size : 0;
  const ratings = {};
  for (const [teamKey, { s, w }] of decayed) {
    const shrinkTarget = seasonPrior(teamKey, mean, params, prev) ?? mean;
    const opr = (s + shrinkTarget * params.priorWeight) / (w + params.priorWeight);
    ratings[teamKey.replace(/^frc/, '')] = [
      Number(opr.toFixed(2)),
      Number(w.toFixed(2)),
      Number((run.foulCarry.get(teamKey) || 0).toFixed(2)),
    ];
  }
  return { params, mean: Number(mean.toFixed(2)), ratings };
}

function worldMembers(world) {
  if (world?.members?.length) return world.members;
  if (!world?.teams?.length) return [];
  const ratings = {};
  for (const t of world.teams) ratings[t.team_number] = [t.opr, t.weight || 0, 0];
  return [{ params: world.params, mean: world.meanRating || 0, ratings }];
}

function computeLiveRatings(matches, world, prev) {
  const members = worldMembers(world);
  const scale = world?.winProbScale || DEFAULT_WIN_PROB_SCALE;
  const runMembers = members.length ? members : [{ params: {}, mean: 0, ratings: {} }];
  const keys = new Set();
  for (const m of matches) for (const key of [...m.red, ...m.blue]) keys.add(key);

  const sums = new Map();
  for (const member of runMembers) {
    const params = { ...DEFAULT_RATING_PARAMS, ...(member.params || {}) };
    const entry = (key) => member.ratings[key.replace(/^frc/, '')];
    const priorFn = (key, base) => {
      const e = entry(key);
      return e ? e[0] : seasonPrior(key, base, params, prev);
    };
    const res = replayEvent(matches, priorFn, () => member.mean || 0, params, null, {
      weightFn: (key) => entry(key)?.[1] || 0,
      foulPriorFn: (key) => entry(key)?.[2] || 0,
    });
    const foulWeight = params.foul > 0 ? params.foul : 0;
    for (const key of keys) {
      let value;
      if (res.ratings.has(key)) value = res.effective(key);
      else if (entry(key)) value = entry(key)[0] - foulWeight * entry(key)[2];
      if (typeof value !== 'number' || !Number.isFinite(value)) continue;
      const s = sums.get(key) || { total: 0, n: 0 };
      s.total += value;
      s.n += 1;
      sums.set(key, s);
    }
  }
  const ratings = {};
  for (const [key, { total, n }] of sums) ratings[key] = Number((total / n).toFixed(2));
  const values = Object.values(ratings);
  const fallbackMean = runMembers.reduce((t, m) => t + (m.mean || 0), 0) / runMembers.length;
  const liveMean = values.length ? values.reduce((a, b) => a + b, 0) / values.length : fallbackMean;
  return { ratings, mean: Number(liveMean.toFixed(2)), scale };
}

module.exports = {
  FOREVER_DAYS, DEFAULT_RATING_PARAMS, TUNING_GRID, LEGACY_KEYS,
  MIN_HOLDOUT_GAMES, DEFAULT_WIN_PROB_SCALE, LIVE_RATINGS_TTL_MS, MS_PER_DAY,
  winProbability, hashString, slimMatch, eventSeasonData, zScores, extractEpa, fetchEpaPrior,
  collectEventData, buildPriorSeason, replayEvent, decayedHistory, runSeasonModel,
  fitWinProbScale, scorePreds, combineTallies, runEnsemble, paramApplies,
  tuneRatingParams, tuneEnsemble, createBreakdown, snapshotMember, worldMembers, computeLiveRatings,
};