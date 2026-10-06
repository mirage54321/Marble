'use strict';

const fs = require('fs');
const M = require('./ratingModel');

function erfc(x) {

  const z = Math.abs(x);
  const t = 1 / (1 + 0.5 * z);
  const r = t * Math.exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 +
    t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 +
    t * (-0.82215223 + t * 0.17087277)))))))));
  return x >= 0 ? r : 2 - r;
}

function mcnemar(a, b) {

  let onlyA = 0;
  let onlyB = 0;
  for (const [gid, ca] of a) {
    const cb = b.get(gid);
    if (cb === undefined) continue;
    if (ca && !cb) onlyA += 1;
    if (!ca && cb) onlyB += 1;
  }
  const n = onlyA + onlyB;
  if (n === 0) return { onlyA, onlyB, p: 1 };
  const chi2 = (Math.abs(onlyA - onlyB) - 1) ** 2 / n;
  return { onlyA, onlyB, p: erfc(Math.sqrt(Math.max(chi2, 0) / 2)) };
}

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function args(argv) {
  const flags = {};
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) { flags[argv[i].slice(2)] = argv[i + 1]; i += 1; } else rest.push(argv[i]);
  }
  return { flags, rest };
}

async function dump(year, outPath) {
  const key = process.env.TBA_AUTH_KEY;
  if (!key) throw new Error('Set TBA_AUTH_KEY');
  const tbaGet = async (path) => {
    for (let attempt = 0; attempt < 3; attempt++) {
      const res = await fetch(`https://www.thebluealliance.com/api/v3${path}`, { headers: { 'X-TBA-Auth-Key': key } });
      if (res.ok) return res.json();
      if (res.status === 404) throw new Error(`404 ${path}`);
      await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
    }
    throw new Error(`TBA failed ${path}`);
  };
  const tbaGetOprs = async (eventKey) => { try { return await tbaGet(`/event/${eventKey}/oprs`); } catch { return { oprs: {} }; } };
  const mapWithConcurrency = async (items, limit, work) => {
    const results = [];
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const item = items[next++];
        try { results.push(await work(item)); } catch (err) { console.warn(`skip ${item.key}: ${err.message}`); }
      }
    }));
    return results;
  };
  const fetchers = { tbaGet, tbaGetOprs, mapWithConcurrency };
  console.log(`Collecting ${year}...`);
  const eventData = await M.collectEventData(year, fetchers);
  console.log(`Collecting ${year - 1} for the prior...`);
  const prevEvents = await M.collectEventData(year - 1, fetchers, { withRows: false });
  const prev = M.buildPriorSeason(prevEvents);
  if (prev) {
    try {
      const epa = await M.fetchEpaPrior(async (url) => (await fetch(url)).json(), year - 1);
      if (epa) prev.zEpa = epa.z;
      console.log(epa ? `EPA prior: ${Object.keys(epa.z).length} teams` : 'EPA prior unavailable');
    } catch (err) { console.warn(`EPA fetch failed: ${err.message}`); }
  }
  fs.writeFileSync(outPath, JSON.stringify({ year, eventData, prev }));
  const games = eventData.reduce((t, d) => t + d.matches.length, 0);
  console.log(`Wrote ${outPath}: ${eventData.length} events, ${games} matches`);
}

function synth(outPath, seed = 7) {
  const rand = mulberry32(seed);
  const gauss = () => Math.sqrt(-2 * Math.log(rand() + 1e-12)) * Math.cos(2 * Math.PI * rand());
  const nTeams = 700;
  const teams = Array.from({ length: nTeams }, (_, i) => ({
    num: 100 + i,
    skill: Math.max(4, 28 * Math.exp(0.35 * gauss())),
    growth: 0.03 + 0.03 * rand(),
    foul: Math.max(0, 1.2 + 1.0 * gauss()),
  }));
  const weeks = 6;
  const eventsPerWeek = 7;
  const attend = new Map(teams.map((t) => [t.num, 0]));
  const eventData = [];
  const day = 86400000;
  const season0 = Date.parse('2026-03-01T00:00:00Z');
  const makeMatch = (level, set, num, red, blue, week) => {
    const perf = (keys) => keys.reduce((t, k) => {
      const tm = teams[k - 100];
      return t + tm.skill * (1 + tm.growth * week) * (1 + 0.22 * gauss());
    }, 0);
    const committed = (keys) => keys.reduce((t, k) => t + Math.max(0, teams[k - 100].foul * (0.5 + rand())), 0);
    const redOwn = Math.max(0, perf(red) + 5 * gauss());
    const blueOwn = Math.max(0, perf(blue) + 5 * gauss());
    const redFoul = Math.round(committed(blue));
    const blueFoul = Math.round(committed(red));
    return {
      level, set, num, red: red.map((k) => `frc${k}`), blue: blue.map((k) => `frc${k}`),
      redScore: Math.round(redOwn) + redFoul, blueScore: Math.round(blueOwn) + blueFoul,
      redOwn: Math.round(redOwn), blueOwn: Math.round(blueOwn), redFoul, blueFoul,
    };
  };
  let eventIndex = 0;
  for (let week = 1; week <= weeks; week++) {
    for (let e = 0; e < eventsPerWeek; e++) {
      const pool = [...teams].sort((a, b) => attend.get(a.num) - attend.get(b.num) + (rand() - 0.5) * 2).slice(0, 36 + Math.floor(rand() * 10));
      const nums = pool.map((t) => t.num);
      nums.forEach((n) => attend.set(n, attend.get(n) + 1));
      const matches = [];
      let num = 1;
      for (let round = 0; round < 12; round++) {
        const order = [...nums].sort(() => rand() - 0.5);
        for (let i = 0; i + 5 < order.length; i += 6) {
          matches.push(makeMatch('qm', 1, num++, order.slice(i, i + 3), order.slice(i + 3, i + 6), week));
        }
      }
      const ranked = [...pool].sort((a, b) => b.skill - a.skill).map((t) => t.num);
      const alliances = Array.from({ length: 8 }, (_, i) => [ranked[i], ranked[15 - i], ranked[16 + i]]);
      for (let s = 1; s <= 13; s++) {
        const a = Math.floor(rand() * 8);
        let b = Math.floor(rand() * 8);
        if (b === a) b = (b + 1) % 8;
        matches.push(makeMatch('sf', s, 1, alliances[a], alliances[b], week));
      }
      for (let f = 1; f <= 2; f++) matches.push(makeMatch('f', 1, f, alliances[0], alliances[1], week));
      const start = season0 + (week - 1) * 7 * day;
      const event = {
        key: `2026synth${eventIndex++}`,
        start_date: new Date(start).toISOString().slice(0, 10),
        end_date: new Date(start + 2 * day).toISOString().slice(0, 10),
      };
      const rows = pool.map((t) => ({
        teamKey: `frc${t.num}`, name: `Team ${t.num}`,
        opr: t.skill * (1 + t.growth * week) + 3 * gauss(), weight: 12, wins: 0, losses: 0, ties: 0,
      }));
      eventData.push(M.eventSeasonData(event, rows, []));
      eventData[eventData.length - 1].matches = matches;
    }
  }
  const prevEntries = teams.map((t) => [String(t.num), t.skill + 0.35 * 28 * 0.5 * gauss()]);
  const epaEntries = teams.map((t) => [String(t.num), t.skill + 0.35 * 28 * 0.3 * gauss()]);
  const prev = { z: M.zScores(prevEntries), cv: 0.35, zEpa: M.zScores(epaEntries) };
  fs.writeFileSync(outPath, JSON.stringify({ year: 2026, eventData, prev }));
  const games = eventData.reduce((t, d) => t + d.matches.length, 0);
  console.log(`Wrote ${outPath}: ${eventData.length} events, ${games} matches`);
}

async function pipelineMembers(name, eventData, prev, isHoldout, budgetMs) {
  if (name === 'legacy') {
    const best = await M.tuneRatingParams(eventData, prev, isHoldout, { allowedKeys: M.LEGACY_KEYS });
    return [best.params];
  }
  if (name === 'full') {
    const best = await M.tuneRatingParams(eventData, prev, isHoldout, { deadline: Date.now() + budgetMs });
    return [best.params];
  }
  const tuned = await M.tuneEnsemble(eventData, prev, isHoldout, { budgetMs });
  return tuned.members;
}

function summarize(games) {
  const preds = [];
  let correct = 0;
  let marginErr = 0;
  for (const g of games.values()) {
    if (g.correct) correct += 1;
    marginErr += Math.abs(g.margin - g.actual);
    preds.push(g.margin, g.redWon ? 1 : 0);
  }
  const n = games.size;
  const { scale } = M.fitWinProbScale(preds);
  const q = M.scorePreds(preds, scale);
  return { n, acc: (100 * correct) / Math.max(n, 1), logLoss: q.logLoss, brier: q.brier, marginErr: marginErr / Math.max(n, 1) };
}

async function run(path, flags) {
  const { eventData, prev } = JSON.parse(fs.readFileSync(path, 'utf8'));
  const folds = Number(flags.folds || 2);
  const budgetMs = Number(flags['budget-sec'] || 120) * 1000;
  const names = ['legacy', 'full', 'ensemble'];
  const results = new Map(names.map((n) => [n, new Map()]));
  const chosen = new Map(names.map((n) => [n, []]));
  console.log(`${eventData.length} events, ${folds} folds, EPA prior ${prev?.zEpa ? 'present' : 'absent'}`);

  for (let fold = 0; fold < folds; fold++) {
    const isHoldout = (d) => M.hashString(d.event.key) % folds === fold;
    for (const name of names) {
      const started = Date.now();
      const members = await pipelineMembers(name, eventData, prev, isHoldout, budgetMs);
      chosen.get(name).push(members);
      M.runEnsemble(eventData, members, {
        prev, isHoldout,
        onGame: (g) => { if (g.holdout) results.get(name).set(`${g.event}|${g.id}`, g); },
      });
      console.log(`fold ${fold} ${name}: ${((Date.now() - started) / 1000).toFixed(1)}s, ${members.length} member(s)`);
    }
  }

  const base = results.get('legacy');
  const baseCorrect = new Map([...base].map(([id, g]) => [id, g.correct]));
  console.log('\npipeline   games   acc%   logloss  brier   margin-err   vs legacy (paired)');
  for (const name of names) {
    const s = summarize(results.get(name));
    let note = '';
    if (name !== 'legacy') {
      const correct = new Map([...results.get(name)].map(([id, g]) => [id, g.correct]));
      const t = mcnemar(correct, baseCorrect);
      note = `+${t.onlyA} / -${t.onlyB} games, p=${t.p.toFixed(3)}, diff ${(s.acc - summarize(base).acc).toFixed(2)} pt`;
    }
    console.log(`${name.padEnd(10)} ${String(s.n).padStart(6)} ${s.acc.toFixed(2).padStart(6)} ${String(s.logLoss).padStart(8)} ${String(s.brier).padStart(7)} ${s.marginErr.toFixed(2).padStart(10)}   ${note}`);
  }
  console.log('\nChosen parameters (last fold):');
  for (const name of names) {
    const members = chosen.get(name).at(-1);
    console.log(`- ${name}: ${JSON.stringify(members.map((p) => {
      const out = {};
      for (const key of Object.keys(M.TUNING_GRID)) if (M.paramApplies(p, key)) out[key] = p[key];
      return out;
    }))}`);
  }
}

(async () => {
  const { flags, rest } = args(process.argv.slice(2));
  const [cmd, a, b] = rest;
  if (cmd === 'dump') await dump(Number(a), b || `season_${a}.json`);
  else if (cmd === 'run') await run(a, flags);
  else if (cmd === 'synth') synth(a || 'synth.json');
  else console.log('Usage: dump <year> [out.json] | run <data.json> [--folds N] [--budget-sec S] | synth [out.json]');
})().catch((err) => { console.error(err); process.exit(1); });