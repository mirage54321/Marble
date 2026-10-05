// https://frc-events.firstinspires.org/2026/allteams
const express = require('express');
const cors = require('cors');
const fetch = require('node-fetch');
const webpush = require('web-push');
const { MongoClient } = require('mongodb');
const FIRST_USERNAME = process.env.FIRST_USERNAME;
const FIRST_TOKEN = process.env.FIRST_TOKEN;
const app = express();

const PORT = process.env.PORT || 3000;
const MONGODB_URI = process.env.MONGODB_URI;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GEMINI_SEGMENT_API_KEYS = [
  process.env.GEMINI_API_KEY_1,
  process.env.GEMINI_API_KEY_2,
  process.env.GEMINI_API_KEY_3,
].filter(Boolean);
if (GEMINI_SEGMENT_API_KEYS.length === 0 && GEMINI_API_KEY) {
  GEMINI_SEGMENT_API_KEYS.push(GEMINI_API_KEY);
}
const DB_NAME = process.env.DB_NAME || 'ridgebotics';
const FRONTEND_ORIGIN = process.env.FRONTEND_ORIGIN || '*';

const GEMINI_SCAN_MODELS = ['gemini-3.6-flash', 'gemini-2.5-flash', 'gemini-3.5-flash'];
function geminiModelUrl(model) {
  return `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
}
function isModelUnavailableError(status, data) {
  if (status !== 404) return false;
  const msg = ((data && data.error && data.error.message) || '').toLowerCase();
  return msg.includes('no longer available') || msg.includes('not found');
}
const GEMINI_TEXT_URL =
  'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent';


const GEMINI_MAX_CONCURRENT = Number(process.env.GEMINI_MAX_CONCURRENT || 2);
const GEMINI_MAX_RETRIES = Number(process.env.GEMINI_MAX_RETRIES || 3);
const GEMINI_BASE_DELAY_MS = Number(process.env.GEMINI_BASE_DELAY_MS || 2000);

let geminiActiveCount = 0;
const geminiWaitQueue = [];

function acquireGeminiSlot() {
  if (geminiActiveCount < GEMINI_MAX_CONCURRENT) {
    geminiActiveCount++;
    return Promise.resolve();
  }
  return new Promise((resolve) => geminiWaitQueue.push(resolve));
}

function releaseGeminiSlot() {
  const next = geminiWaitQueue.shift();
  if (next) {
    next();
  } else {
    geminiActiveCount--;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableGeminiStatus(status) {
  // 429 = rate limited 
  // 503 = model temporarily overloaded.
  return status === 429 || status === 503;
}

function retryDelayMsFromResponse(response, attempt) {
  const retryAfter = response.headers.get('retry-after');
  const parsed = Number(retryAfter);
  if (Number.isFinite(parsed) && parsed > 0) {
    return parsed * 1000;
  }
  return GEMINI_BASE_DELAY_MS * Math.pow(2, attempt); 
}

async function callGeminiWithRetry(url, body, maxRetries = GEMINI_MAX_RETRIES) {
  await acquireGeminiSlot();
  try {
    let lastResponse;
    let lastData;
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await response.json();

      if (response.ok || !isRetryableGeminiStatus(response.status)) {
        return { status: response.status, data };
      }

      lastResponse = response;
      lastData = data;

      const isLastAttempt = attempt === maxRetries - 1;
      if (isLastAttempt) break;

      const delay = retryDelayMsFromResponse(response, attempt);
      console.warn(
        `Gemini ${response.status}, retrying in ${delay}ms (attempt ${attempt + 1}/${maxRetries})`,
      );
      await sleep(delay);
    }
    return { status: lastResponse.status, data: lastData };
  } finally {
    releaseGeminiSlot();
  }
}

let segmentKeyCursor = 0;
const segmentKeyExhaustedUntil = new Map();

async function callGeminiSegmentWithKeyRotation(body) {
  const keys = GEMINI_SEGMENT_API_KEYS;
  if (keys.length === 0) {
    return { status: 503, data: { error: 'No Gemini segmentation keys configured' } };
  }

  const order = [];
  for (let i = 0; i < keys.length; i++) {
    order.push(keys[(segmentKeyCursor + i) % keys.length]);
  }
  segmentKeyCursor = (segmentKeyCursor + 1) % keys.length;

  let lastStatus = 503;
  let lastData = { error: 'All segmentation keys are exhausted for today' };

  for (const key of order) {
    const exhaustedUntil = segmentKeyExhaustedUntil.get(key) || 0;
    if (Date.now() < exhaustedUntil) {
      continue;
    }

    for (const model of GEMINI_SCAN_MODELS) {
      await acquireGeminiSlot();
      let response;
      let data;
      try {
        response = await fetch(`${geminiModelUrl(model)}?key=${key}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        data = await response.json();
      } finally {
        releaseGeminiSlot();
      }

      if (response.ok) {
        return { status: response.status, data };
      }

      lastStatus = response.status;
      lastData = data;

      if (isModelUnavailableError(response.status, data)) {
        console.warn(`Model ${model} unavailable for segment key ...${key.slice(-4)}, trying next model`);
        continue;
      }

      if (response.status === 429) {
        segmentKeyExhaustedUntil.set(key, Date.now() + 20 * 60 * 60 * 1000);
        console.warn(`Segment key ...${key.slice(-4)} hit its daily quota, rotating to next key`);
        break;
      }

      if (response.status === 503) {
        console.warn(`Segment key ...${key.slice(-4)} got 503 (overloaded), rotating to next key`);
        break;
      }

      return { status: response.status, data };
    }
  }

  return { status: lastStatus, data: lastData };
}

const TBA_AUTH_KEY = process.env.TBA_AUTH_KEY;
const TBA_BASE = 'https://www.thebluealliance.com/api/v3';
const NOTIFY_WINDOW_MIN = 12;
const FINAL_SCORE_WINDOW_MIN = 180;


const NOTIFY_STAGES = [
  { stage: 'alliance', minMinutesAway: 15, maxMinutesAway: 20 },
  { stage: 'queue', minMinutesAway: 10, maxMinutesAway: 15 },
  { stage: 'matchup', minMinutesAway: 5, maxMinutesAway: 10 },
  { stage: 'field', minMinutesAway: 0, maxMinutesAway: 5 },
  { stage: 'start', minMinutesAway: -NOTIFY_WINDOW_MIN, maxMinutesAway: 0 },
];

function stageForMinutesAway(minsAway) {
  for (const { stage, minMinutesAway, maxMinutesAway } of NOTIFY_STAGES) {
    if (minsAway > minMinutesAway && minsAway <= maxMinutesAway) return stage;
  }
  return null;
}

function joinWithAnd(items) {
  if (items.length === 0) return '';
  if (items.length === 1) return items[0];
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}


function allianceTeammates(match, teamKey) {
  const onRed = (match.alliances?.red?.team_keys || []).includes(teamKey);
  const list = onRed ? match.alliances?.red?.team_keys : match.alliances?.blue?.team_keys;
  return (list || []).filter((key) => key !== teamKey).map((key) => key.replace(/^frc/, ''));
}


function allianceSlotLabel(match, teamKey) {
  const onRed = (match.alliances?.red?.team_keys || []).includes(teamKey);
  const list = onRed ? match.alliances?.red?.team_keys : match.alliances?.blue?.team_keys;
  if (!list) return null;
  const idx = list.indexOf(teamKey);
  if (idx === -1) return null;
  return `${onRed ? 'Red' : 'Blue'} ${idx + 1}`;
}


function buildMatchupContext(match, teamKey, ratingData) {
  const onRed = (match.alliances?.red?.team_keys || []).includes(teamKey);
  const myAlliance = onRed ? match.alliances.red.team_keys : match.alliances.blue.team_keys;
  const oppAlliance = onRed ? match.alliances.blue.team_keys : match.alliances.red.team_keys;
  if (!myAlliance || !oppAlliance) return null;

  const ratings = ratingData?.ratings || {};
  const mean = ratingData?.mean || 0;
  const rate = (key) => (typeof ratings[key] === 'number' ? ratings[key] : mean);
  const sum = (keys) => keys.reduce((total, key) => total + rate(key), 0);

  const mySum = sum(myAlliance);
  const oppSum = sum(oppAlliance);
  const hasData = Object.keys(ratings).length > 0 && (mySum !== 0 || oppSum !== 0);
  const winProbPct = hasData
    ? Math.round(Math.min(0.99, Math.max(0.01, winProbability(mySum - oppSum, ratingData?.scale))) * 100)
    : null;

  let topOpponentKey = null;
  for (const key of oppAlliance) {
    if (key === teamKey) continue;
    if (topOpponentKey === null || rate(key) > rate(topOpponentKey)) topOpponentKey = key;
  }

  return {
    winProbPct,
    topOpponentNumber: topOpponentKey ? topOpponentKey.replace(/^frc/, '') : null,
  };
}

function finalScoreSummary(match, teamKey) {
  const onRed = (match.alliances?.red?.team_keys || []).includes(teamKey);
  const myScore = onRed ? match.alliances?.red?.score : match.alliances?.blue?.score;
  const oppScore = onRed ? match.alliances?.blue?.score : match.alliances?.red?.score;
  if (myScore == null || oppScore == null) return null;
  const teamNumber = teamKey.replace(/^frc/, '');
  const result = myScore > oppScore ? 'won' : myScore < oppScore ? 'lost' : 'tied';
  return `Team ${teamNumber} ${result} ${myScore}-${oppScore}.`;
}

function notificationForStage(teamNumber, label, stage, extra = {}) {
  switch (stage) {
    case 'alliance': {
      const teammates = (extra.teammates || []).map((n) => `Team ${n}`);
      return {
        title: `Team ${teamNumber}: ${label} in 20 min`,
        body: teammates.length
          ? `Your alliance this match: you + ${joinWithAnd(teammates)}.`
          : "Your match is coming up in 20 minutes. Alliance info isn't available yet.",
      };
    }
    case 'queue': {
      const slot = extra.slotLabel;
      return {
        title: `Team ${teamNumber}: ${label} in 15 min`,
        body: slot
          ? `You're on queue. You'll be ${slot} this match.`
          : "You're on queue. Head to the queuing line.",
      };
    }
    case 'matchup': {
      const { winProbPct, topOpponentNumber } = extra;
      const parts = [];
      if (winProbPct != null) parts.push(`You have about a ${winProbPct}% chance of winning this match.`);
      if (topOpponentNumber) parts.push(`Watch Team ${topOpponentNumber} on the other alliance. They're projected to contribute the most, so they're the one to defend.`);
      return {
        title: `Team ${teamNumber}: ${label} in 10 min`,
        body: parts.length ? parts.join(' ') : 'Your match is coming up in 10 minutes.',
      };
    }
    case 'field':
      return {
        title: `Team ${teamNumber}: ${label} in 5 min`,
        body: 'Be on the field. Your match starts in 5 minutes.',
      };
    case 'start':
      return {
        title: `Team ${teamNumber}: ${label} is starting`,
        body: 'Game starting now!',
      };
    case 'final':
      return {
        title: `Team ${teamNumber}: ${label} final score`,
        body: extra.summary || 'Your match has finished.',
      };
    default:
      return {
        title: `Team ${teamNumber}: ${label}`,
        body: 'Match update.',
      };
  }
}

const VAPID_PUBLIC_KEY = process.env.VAPID_PUBLIC_KEY;
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY;
const VAPID_SUBJECT = process.env.VAPID_SUBJECT;
const PUSH_CHECK_SECRET = process.env.PUSH_CHECK_SECRET;
const REPORTS_ADMIN_SECRET = process.env.REPORTS_ADMIN_SECRET;

const webpushConfigured = Boolean(VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY && VAPID_SUBJECT);
if (webpushConfigured) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
} else {
  console.warn('VAPID keys not fully configured. /push/* routes will be disabled');
}

const PUSH_BURST_COUNT = Number(process.env.PUSH_BURST_COUNT || 3);
const PUSH_BURST_INTERVAL_MS = Number(process.env.PUSH_BURST_INTERVAL_MS || 200);


const PUSH_VIBRATE_PATTERN = [200, 100, 300, 200, 300];

async function sendSingleNotification(sub, payload) {
  try {
    await webpush.sendNotification(sub.subscription, payload);
    return true;
  } catch (err) {
    console.error(`webpush send failed (status ${err.statusCode}): ${err.body || err.message}`);
    if (err.statusCode === 404 || err.statusCode === 410) {
      await pushSubscriptionsCollection.deleteOne({ endpoint: sub.subscription.endpoint });
    }
    return false;
  }
}

async function sendPushBurst(sub, basePayload, tagSeed) {
  const isIos = sub.platform === 'ios';
  const payload = JSON.stringify({
    ...basePayload,
    tag: tagSeed,
    renotify: true,
    ...(isIos ? {} : { vibrate: PUSH_VIBRATE_PATTERN }),
  });

  // if (!isIos) {
    return sendSingleNotification(sub, payload);
  // }

  // let deliveredAtLeastOnce = false;
  // for (let i = 0; i < PUSH_BURST_COUNT; i++) {
  //   const delivered = await sendSingleNotification(sub, payload);
  //   if (!delivered) {

  //     break;
  //   }
  //   deliveredAtLeastOnce = true;
  //   if (i < PUSH_BURST_COUNT - 1) {
  //     await sleep(PUSH_BURST_INTERVAL_MS);
  //   }
  // }
  // return deliveredAtLeastOnce;
}

if (!MONGODB_URI) {
  console.error('Missing MONGODB_URI');
  process.exit(1);
}

const corsOptions = {
  origin: FRONTEND_ORIGIN,
  methods: ['GET', 'POST', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'X-Reports-Admin-Secret'],
};

app.use(cors(corsOptions));
app.options('*', cors(corsOptions));
app.use(express.json({ limit: '50mb' }));

const mongoClient = new MongoClient(MONGODB_URI);
let teamsCollection;
let batteriesCollection;
let pushSubscriptionsCollection;
let notifiedMatchesCollection;
let eventRostersCollection;
let reportsCollection;
let worldRatingsCollection;
let eventTeamsCollection;
let countersCollection;
let worldRatingRefresh;

async function connectToMongo() {
  await mongoClient.connect();

  const db = mongoClient.db(DB_NAME);
  teamsCollection = db.collection('teams');
  batteriesCollection = db.collection('batteries');
  pushSubscriptionsCollection = db.collection('pushSubscriptions');
  notifiedMatchesCollection = db.collection('notifiedMatches');
  eventRostersCollection = db.collection('eventRosters');
  reportsCollection = db.collection('reports');
  worldRatingsCollection = db.collection('worldRatings');
  eventTeamsCollection = db.collection('eventTeams');
  countersCollection = db.collection('counters');

  await teamsCollection.createIndex({ teamNumber: 1 }, { unique: true });
  await batteriesCollection.createIndex({ teamNumber: 1, label: 1 }, { unique: true });
  await batteriesCollection.createIndex({ teamNumber: 1, lastUsedAt: 1 });
  await pushSubscriptionsCollection.createIndex({ endpoint: 1 }, { unique: true });
  await pushSubscriptionsCollection.createIndex({ teamNumber: 1, eventKey: 1 });
  await notifiedMatchesCollection.createIndex(
    { teamNumber: 1, eventKey: 1, matchKey: 1 },
    { unique: true },
  );

  await notifiedMatchesCollection.createIndex(
    { createdAt: 1 },
    { expireAfterSeconds: 7 * 24 * 60 * 60 },
  );
  await eventRostersCollection.createIndex({ teamNumber: 1, eventKey: 1 }, { unique: true });
  await reportsCollection.createIndex({ createdAt: -1 });
  await reportsCollection.createIndex({ findingType: 1, errorType: 1, createdAt: -1 });
  await reportsCollection.createIndex({ scanId: 1, findingId: 1 });
  await worldRatingsCollection.createIndex({ refreshedAt: -1 });
  await eventTeamsCollection.createIndex({ refreshedAt: -1 });

  console.log(`Connected to MongoDB database: ${DB_NAME}`);
}

async function getFIRSTTeamName(teamNumber) {
  try {
    const response = await fetch(
      `https://frc-api.firstinspires.org/v3.0/2026/teams?teamNumber=${teamNumber}`,
      {
        headers: {
          Authorization:
            'Basic ' +
            Buffer.from(
              `${FIRST_USERNAME}:${FIRST_TOKEN}`
            ).toString('base64'),
        },
      }
    );

    const data = await response.json();

    if (data.teams && data.teams.length > 0) {
      return data.teams[0].nameShort;
    }

    return null;

  } catch (err) {
    console.error("FIRST lookup failed:", err);
    return null;
  }
}

async function tbaGet(path) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  let res;
  try {
    res = await fetch(`${TBA_BASE}${path}`, {
      headers: { 'X-TBA-Auth-Key': TBA_AUTH_KEY }, signal: controller.signal,
    });
  } catch (err) {
    if (err.name === 'AbortError') {
      const timeoutError = new Error(`TBA ${path} timed out`);
      timeoutError.status = 504;
      throw timeoutError;
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }
  if (!res.ok) {
    const err = new Error(`TBA ${path} failed: ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return res.json();
}


async function tbaGetOprs(eventKey) {
  try {
    const data = await tbaGet(`/event/${eventKey}/oprs`);
    return data && typeof data === 'object' ? data : { oprs: {} };
  } catch (err) {
    return { oprs: {} };
  }
}

function cleanString(value) {
  if (value === undefined || value === null) return null;
  const cleaned = String(value).trim();
  return cleaned || null;
}

function checkReportsAdmin(req, res) {
  if (!REPORTS_ADMIN_SECRET) {
    res.status(503).json({ error: 'Report dashboard is not configured' });
    return false;
  }
  if (req.get('X-Reports-Admin-Secret') !== REPORTS_ADMIN_SECRET) {
    res.status(401).json({ error: 'Unauthorized' });
    return false;
  }
  return true;
}

async function getTeam(teamNumber) {
  const cleanedTeamNumber = cleanString(teamNumber);
  if (!cleanedTeamNumber) return null;
  return teamsCollection.findOne({ teamNumber: cleanedTeamNumber });
}

async function checkTeamAuth(req, res) {
  const teamNumber = cleanString(req.body.teamNumber || req.query.teamNumber);
  const passcode = cleanString(req.body.passcode || req.query.passcode);

  if (!teamNumber || !passcode) {
    res.status(400).json({ error: 'teamNumber and passcode required' });
    return null;
  }

  const team = await getTeam(teamNumber);
  if (!team || team.passcode !== passcode) {
    res.status(401).json({ error: 'Invalid team number or passcode' });
    return null;
  }

  return team;
}

const BATTERY_CHARGE_MINUTES = 35;
const BATTERY_COOLDOWN_MINUTES = 30;
const BATTERY_EPOCH_MS = new Date('2000-01-01').getTime();

function getBatteryState(battery, now = Date.now()) {
  if (battery.isInUse) return { state: 'in_use' };

  const lastUsed = battery.lastUsedAt ? new Date(battery.lastUsedAt).getTime() : 0;
  const charged = battery.chargedAt ? new Date(battery.chargedAt).getTime() : null;
  const hasBeenUsed = lastUsed > BATTERY_EPOCH_MS;

  if (hasBeenUsed && (charged === null || lastUsed > charged)) {
    const cooldownLeft = Math.ceil(BATTERY_COOLDOWN_MINUTES - (now - lastUsed) / 60000);
    return cooldownLeft > 0
      ? { state: 'dead_cooling_down', cooldownLeft }
      : { state: 'dead_needs_charge' };
  }

  if (battery.isCharging) {
    const elapsed = charged ? (now - charged) / 60000 : 0;
    const chargeLeft = Math.ceil(BATTERY_CHARGE_MINUTES - elapsed);
    return chargeLeft > 0
      ? { state: 'charging', chargeLeft }
      : { state: 'charged_ready' };
  }

  return { state: 'available' };
}

function formatAge(ms) {
  const min = Math.max(0, Math.round(ms / 60000));
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h}h ${min % 60}m ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function flagSeverity(note) {
  const t = String(note || '').toLowerCase();
  if (!t.trim()) return 0.5;
  const bad = /(\b0\s?v\b|\bdead\b|\bdied\b|\bdying\b|brown\s?-?out|\bbad+\b|\bweak\b|\blow\b|\bdrop|\bswoll|\bpuff|\bhot\b|\bsmok|\bcrack|\bdamag|\bfail|\bcut out|\bdies\b|\bpoor\b|\bterrible\b|\bworst\b)/;
  const good = /(\bgreat\b|\bgood\b|\bsolid\b|\bstrong\b|\bperfect\b|\bbest\b|\breliable\b|\bfine\b|\bno issues?\b)/;
  if (bad.test(t)) return 3;
  if (good.test(t)) return -0.5;
  return 1;
}

function batteryFlagScore(battery, now = Date.now()) {
  const flags = Array.isArray(battery.flags) ? battery.flags : [];
  return flags.reduce((sum, f) => {
    const ageDays = Math.max(0, (now - new Date(f.flaggedAt).getTime()) / 86400000);
    const recency = ageDays < 1 ? 1 : ageDays < 7 ? 0.6 : 0.3;
    return sum + Math.max(0, flagSeverity(f.note)) * recency;
  }, 0);
}

const STATE_RANK = { charged_ready: 0, available: 0, charging: 1 };

function recommendableBatteries(batteries, now = Date.now()) {
  return batteries
    .map((battery) => ({ battery, info: getBatteryState(battery, now) }))
    .filter(({ info }) => info.state in STATE_RANK);
}

function fallbackRecommendation(batteries, reason) {
  const now = Date.now();
  const candidates = recommendableBatteries(batteries, now);

  if (candidates.length > 0) {
    candidates.sort((a, b) => {
      const rank = STATE_RANK[a.info.state] - STATE_RANK[b.info.state];
      if (rank !== 0) return rank;
      const flags = batteryFlagScore(a.battery, now) - batteryFlagScore(b.battery, now);
      if (flags !== 0) return flags;
      if (a.info.state === 'charging') return a.info.chargeLeft - b.info.chargeLeft;
      return (
        new Date(a.battery.lastUsedAt).getTime() - new Date(b.battery.lastUsedAt).getTime()
      );
    });
    return {
      recommendedLabel: candidates[0].battery.label,
      reason: reason || 'Charged and has the fewest recent problems',
    };
  }

  const notInUse = batteries
    .map((battery) => ({ battery, info: getBatteryState(battery, now) }))
    .filter(({ info }) => info.state !== 'in_use');
  const pick = notInUse[0];
  return {
    recommendedLabel: pick ? pick.battery.label : batteries[0] ? batteries[0].label : null,
    reason: batteries.length
      ? 'Nothing is charged right now, charge one first'
      : 'No batteries logged yet',
  };
}

async function incrementScanCount() {
  if (!countersCollection) return;
  try {
    await countersCollection.updateOne(
      { _id: 'scans' },
      { $inc: { count: 1 } },
      { upsert: true },
    );
  } catch (err) {
    console.error('Scan counter increment failed:', err);
  }
}

app.get('/', (req, res) => {
  res.send('Backend running');
});

app.get('/health', (req, res) => {
  res.json({
    ok: true,
    mongo: Boolean(teamsCollection && batteriesCollection),
    reportsMongo: Boolean(reportsCollection),
    geminiConfigured: Boolean(GEMINI_API_KEY),
    geminiSegmentConfigured: GEMINI_SEGMENT_API_KEYS.length > 0,
    geminiSegmentKeyCount: GEMINI_SEGMENT_API_KEYS.length,
    tbaConfigured: Boolean(TBA_AUTH_KEY),
    webpushConfigured,
  });
});

app.get('/scans/count', async (req, res) => {
  if (!countersCollection) {
    return res.status(503).json({ error: 'Scan counter is not configured' });
  }
  try {
    const doc = await countersCollection.findOne({ _id: 'scans' });
    res.json({ totalScans: doc?.count || 0 });
  } catch (err) {
    console.error('Scan count fetch error:', err);
    res.status(500).json({ error: 'Could not load scan count' });
  }
});

const scanComboExhaustedUntil = new Map();

function scanKeyPool() {
  const pool = [];
  if (GEMINI_API_KEY) pool.push(GEMINI_API_KEY);
  for (const k of GEMINI_SEGMENT_API_KEYS) {
    if (!pool.includes(k)) pool.push(k);
  }
  return pool;
}

async function callGeminiScanWithModelFallback(primaryKey, body) {
  const keys = [primaryKey, ...scanKeyPool().filter((k) => k !== primaryKey)];

  let anyAttemptMade = false;
  let lastStatus = 503;
  let lastData = { error: 'All Gemini keys/models are exhausted for today' };

  for (const key of keys) {
    for (const model of GEMINI_SCAN_MODELS) {
      const comboId = `${key}|${model}`;
      const exhaustedUntil = scanComboExhaustedUntil.get(comboId) || 0;
      if (Date.now() < exhaustedUntil) {
        continue;
      }

      const { status, data } = await callGeminiWithRetry(`${geminiModelUrl(model)}?key=${key}`, body, 1);
      anyAttemptMade = true;
      if (status >= 200 && status < 300) {
        return { status, data };
      }

      lastStatus = status;
      lastData = data;

      if (isModelUnavailableError(status, data)) {
        console.warn(`Model ${model} unavailable on this key, trying next model`);
        continue;
      }

      if (status === 429) {
        scanComboExhaustedUntil.set(comboId, Date.now() + 20 * 60 * 60 * 1000);
        console.warn(`${model} hit its daily quota on this key, rotating`);
        continue;
      }

      if (status === 503) {
        console.warn(`${model} overloaded on this key, rotating`);
        continue;
      }

      return { status, data };
    }
  }

  if (!anyAttemptMade) {
    return {
      status: 429,
      data: {
        error: 'all_quota_exhausted_for_today',
        message: 'Every configured Gemini key/model is out of quota for today.',
      },
    };
  }

  return { status: lastStatus, data: lastData };
}

app.post('/analyzeImage', async (req, res) => {
  try {
    if (!GEMINI_API_KEY) {
      return res.status(503).json({ error: 'GEMINI_API_KEY is not configured on the server' });
    }

    const { status, data } = await callGeminiScanWithModelFallback(GEMINI_API_KEY, req.body);
    if (status >= 200 && status < 300) {
      incrementScanCount();
    }
    res.status(status).json(data);
  } catch (err) {
    console.error('Analyze image error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/segmentImage', async (req, res) => {
  try {
    if (GEMINI_SEGMENT_API_KEYS.length === 0) {
      return res
        .status(503)
        .json({ error: 'No GEMINI_API_KEY_1/2/3 configured on the server' });
    }

    const { status, data } = await callGeminiSegmentWithKeyRotation(req.body);
    res.status(status).json(data);
  } catch (err) {
    console.error('Segment image error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/reportFinding', async (req, res) => {
  if (!reportsCollection) {
    return res.status(503).json({ error: 'Scan reporting is not configured' });
  }

  const title = cleanString(req.body.title);
  const scanId = cleanString(req.body.scanId);
  const findingId = cleanString(req.body.findingId);
  const errorType = cleanString(req.body.errorType) || 'other';
  const allowedErrorTypes = new Set([
    'false_positive',
    'wrong_location',
    'wrong_description',
    'missed_problem',
    'other',
  ]);

  if (!title || !scanId || !findingId) {
    return res.status(400).json({ error: 'scanId, findingId, and title are required' });
  }
  if (!allowedErrorTypes.has(errorType)) {
    return res.status(400).json({ error: 'Invalid errorType' });
  }

  const report = {
    scanId,
    findingId,
    scanMode: cleanString(req.body.scanMode) || 'physical',
    errorType,
    findingType: title.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''),
    title,
    description: cleanString(req.body.description) || '',
    userComment: cleanString(req.body.userComment) || '',
    severity: cleanString(req.body.severity) || 'unknown',
    status: 'pending',
    createdAt: new Date(),
  };

  try {
    const result = await reportsCollection.insertOne(report);
    res.status(201).json({ ok: true, reportId: result.insertedId.toString() });
  } catch (err) {
    console.error('Report finding error:', err);
    res.status(500).json({ error: 'Could not save report' });
  }
});

app.get('/reports', async (req, res) => {
  if (!checkReportsAdmin(req, res)) return;
  if (!reportsCollection) {
    return res.status(503).json({ error: 'Scan reporting is not configured' });
  }
  try {
    const reports = await reportsCollection.find({}).sort({ createdAt: -1 }).limit(50).toArray();
    res.json({ reports });
  } catch (err) {
    console.error('List reports error:', err);
    res.status(500).json({ error: 'Could not load reports' });
  }
});

app.get('/reports/summary', async (req, res) => {
  if (!checkReportsAdmin(req, res)) return;
  if (!reportsCollection) {
    return res.status(503).json({ error: 'Scan reporting is not configured' });
  }
  try {
    const summary = await reportsCollection.aggregate([
      { $group: { _id: { findingType: '$findingType', errorType: '$errorType' }, count: { $sum: 1 } } },
      { $sort: { count: -1 } },
    ]).toArray();
    res.json({ summary });
  } catch (err) {
    console.error('Report summary error:', err);
    res.status(500).json({ error: 'Could not load report summary' });
  }
});

app.post('/battery/register', async (req, res) => {
  try {
    const teamNumber = cleanString(req.body.teamNumber);
    const passcode = cleanString(req.body.passcode);

    if (!teamNumber || !passcode) {
      return res.status(400).json({ error: 'teamNumber and passcode required' });
    }

    if (passcode.length < 4) {
      return res.status(400).json({ error: 'Passcode must be at least 4 characters' });
    }

    const existing = await getTeam(teamNumber);
    if (existing) {
      return res.status(409).json({ error: 'Team already registered. \n\nClick the report button on the bottom right corner of the home page if you don\'t have access to your team account.' });
    }

const teamName = await getFIRSTTeamName(teamNumber);

    await teamsCollection.insertOne({
      teamNumber,
      passcode,
      teamName,
      createdAt: new Date().toISOString(),
    });

    res.json({ ok: true, teamName });
  } catch (err) {
    console.error('Register error:', err);

    if (err.code === 11000) {
      return res.status(409).json({ error: 'Team already registered. \n\nClick the report button on the bottom right corner of the home page if you don\'t have access to your team account.' });
    }

    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/login', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    res.json({ ok: true, teamName: team.teamName || null });
  } catch (err) {
    console.error('Login error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/changeTeamName', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const teamName = cleanString(req.body.teamName);

    await teamsCollection.updateOne(
      { teamNumber: team.teamNumber },
      { $set: { teamName } },
    );

    res.json({ ok: true, teamName });
  } catch (err) {
    console.error('Change team name error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/changePasscode', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const newPasscode = cleanString(req.body.newPasscode);
    if (!newPasscode || newPasscode.length < 4) {
      return res.status(400).json({ error: 'New passcode must be at least 4 characters' });
    }

    await teamsCollection.updateOne(
      { teamNumber: team.teamNumber },
      { $set: { passcode: newPasscode } },
    );

    res.json({ ok: true });
  } catch (err) {
    console.error('Change passcode error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/reset', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const result = await batteriesCollection.deleteMany({ teamNumber: team.teamNumber });
    res.json({ ok: true, deletedCount: result.deletedCount });
  } catch (err) {
    console.error('Reset error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/battery/list', async (req, res) => {
  try {
    const teamNumber = cleanString(req.query.teamNumber);
    const passcode = cleanString(req.query.passcode);
    const guest = req.query.guest === 'true';

    if (!teamNumber) {
      return res.status(400).json({ error: 'teamNumber required' });
    }

    const team = await getTeam(teamNumber);
    if (!team) {
      return res.status(404).json({ error: 'Team not found' });
    }

    if (!guest && team.passcode !== passcode) {
      return res.status(401).json({ error: 'Invalid team number or passcode' });
    }

    const batteries = await batteriesCollection
      .find({ teamNumber })
      .sort({ lastUsedAt: 1 })
      .toArray();

    res.json({ batteries, teamName: team.teamName || null });
  } catch (err) {
    console.error('List error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/add', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const count = await batteriesCollection.countDocuments({ teamNumber: team.teamNumber });
    const label = `B${count + 1}`;
    const battery = {
      teamNumber: team.teamNumber,
      label,
      lastUsedAt: new Date(0).toISOString(),
      flags: [],
      isCharging: false,
      isInUse: false,
      createdAt: new Date().toISOString(),
    };

    await batteriesCollection.insertOne(battery);
    res.json({ battery });
  } catch (err) {
    console.error('Add battery error:', err);

    if (err.code === 11000) {
      return res.status(409).json({ error: 'Battery already exists' });
    }

    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/use', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const label = cleanString(req.body.label);
    if (!label) {
      return res.status(400).json({ error: 'label is required' });
    }

    const battery = await batteriesCollection.findOne({ teamNumber: team.teamNumber, label });
    if (!battery) {
      return res.status(404).json({ error: 'Battery not found' });
    }

    const nextInUse = !battery.isInUse;

    await batteriesCollection.updateOne(
      { teamNumber: team.teamNumber, label },
      {
        $set: {
          isInUse: nextInUse,
          isCharging: false,
          lastUsedAt: new Date().toISOString(),
        },
      },
    );

    res.json({ ok: true, isInUse: nextInUse });
  } catch (err) {
    console.error('Use battery error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/charging', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const label = cleanString(req.body.label);
    if (!label) {
      return res.status(400).json({ error: 'label is required' });
    }

    const battery = await batteriesCollection.findOne({ teamNumber: team.teamNumber, label });
    if (!battery) {
      return res.status(404).json({ error: 'Battery not found' });
    }

    const nextCharging = !battery.isCharging;

    await batteriesCollection.updateOne(
      { teamNumber: team.teamNumber, label },
      {
        $set: {
          isCharging: nextCharging,
          isInUse: false,
          chargedAt: nextCharging ? new Date().toISOString() : battery.chargedAt || null,
        },
      },
    );

    res.json({ ok: true, isCharging: nextCharging });
  } catch (err) {
    console.error('Charging battery error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/flag', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const label = cleanString(req.body.label);
    if (!label) {
      return res.status(400).json({ error: 'label is required' });
    }

    const result = await batteriesCollection.updateOne(
      { teamNumber: team.teamNumber, label },
      {
        $push: {
          flags: {
            note: cleanString(req.body.note) || '',
            flaggedAt: new Date().toISOString(),
          },
        },
      },
    );

    if (result.matchedCount === 0) {
      return res.status(404).json({ error: 'Battery not found' });
    }

    res.json({ ok: true });
  } catch (err) {
    console.error('Flag error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.delete('/battery/:label', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const result = await batteriesCollection.deleteOne({
      teamNumber: team.teamNumber,
      label: req.params.label,
    });

    res.json({ ok: true, deletedCount: result.deletedCount });
  } catch (err) {
    console.error('Delete battery error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/battery/recommend', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const batteries = await batteriesCollection
      .find({ teamNumber: team.teamNumber })
      .sort({ lastUsedAt: 1 })
      .toArray();

    if (batteries.length === 0) {
      return res.json({ recommendedLabel: null, reason: 'No batteries logged yet' });
    }

    const now = Date.now();
    const candidates = recommendableBatteries(batteries, now);

    if (candidates.length === 0) {
      return res.json(fallbackRecommendation(batteries));
    }

    if (candidates.length === 1) {
      return res.json({
        recommendedLabel: candidates[0].battery.label,
        reason: 'Only battery that is ready to use',
      });
    }

    if (!GEMINI_API_KEY) {
      return res.json(fallbackRecommendation(batteries));
    }

    const summary = candidates
      .map(({ battery, info }) => {
        const status =
          info.state === 'charging'
            ? `still charging (${info.chargeLeft} min left)`
            : info.state === 'charged_ready'
              ? 'fully charged and ready'
              : 'available';

        const lastUsed = new Date(battery.lastUsedAt).getTime();
        const lastUsedText =
          lastUsed > BATTERY_EPOCH_MS ? `last used ${formatAge(now - lastUsed)}` : 'never used yet';

        const flags = Array.isArray(battery.flags) ? battery.flags : [];
        const recentFlags = flags.slice(-15).reverse();
        const flagText =
          flags.length === 0
            ? 'no flags'
            : `${flags.length} flag(s) total. Notes, newest first:\n` +
              recentFlags
                .map(
                  (f) =>
                    `    - "${(f.note || 'no reason given').slice(0, 200)}" (${formatAge(
                      now - new Date(f.flaggedAt).getTime(),
                    )})`,
                )
                .join('\n');

        return `${battery.label}: ${status}, ${lastUsedText}, ${flagText}`;
      })
      .join('\n\n');

    const prompt =
      `You are helping an FRC robotics team pick which battery to grab for their next match.\n\n` +
      `Here are the batteries that are available right now:\n\n${summary}\n\n` +
      `Rules:\n` +
      `- A "flag" is just a note someone left about a battery. Flags can be POSITIVE ("great battery") or NEGATIVE ("0v", "died after auto", "SO BAD", "brownout"). ` +
      `Read what each note actually says. NEVER judge by the number of flags.\n` +
      `- Ignore positive or neutral notes when looking for problems. Treat notes about low or 0 voltage, dying mid-match, brownouts, swelling, or overheating as serious.\n` +
      `- Recent notes matter more than old ones. One serious recent problem outweighs many old or positive notes.\n` +
      `- Strongly prefer fully charged/available batteries over ones still charging.\n` +
      `- If batteries are otherwise equal, prefer the one used least recently so use is spread evenly.\n\n` +
      `Respond ONLY with valid JSON, no markdown, and recommendedLabel must be one of the labels above:\n` +
      `{"recommendedLabel":"B1","reason":"one sentence under 15 words, mention the note that mattered if any"}`;

    const { status, data } = await callGeminiWithRetry(
      `${GEMINI_TEXT_URL}?key=${GEMINI_API_KEY}`,
      {
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0, maxOutputTokens: 150 },
      },
    );
    const rawText = data.candidates?.[0]?.content?.parts?.[0]?.text
      ?.replace(/```json/g, '')
      ?.replace(/```/g, '')
      ?.trim();

    if (status < 200 || status >= 300 || !rawText) {
      return res.json(fallbackRecommendation(batteries));
    }

    try {
      const parsed = JSON.parse(rawText);
      const valid = candidates.some(({ battery }) => battery.label === parsed.recommendedLabel);
      if (!valid) {
        return res.json(fallbackRecommendation(batteries));
      }
      return res.json({
        recommendedLabel: parsed.recommendedLabel,
        reason: parsed.reason || 'Recommended by battery history',
      });
    } catch (parseErr) {
      console.error('Gemini JSON parse error:', parseErr);
      return res.json(fallbackRecommendation(batteries));
    }
  } catch (err) {
    console.error('Recommend error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/match/events', async (req, res) => {
  const teamNumber = cleanString(req.query.teamNumber);
  const year = cleanString(req.query.year);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!teamNumber || !year) {
    return res.status(400).json({ error: 'teamNumber and year are required' });
  }

  try {
    const events = await tbaGet(`/team/frc${teamNumber}/events/${year}/simple`);
    res.json(events);
  } catch (err) {
    console.error('Match events error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load events' });
  }
});


app.get('/events', async (req, res) => {
  const year = cleanString(req.query.year) || String(new Date().getFullYear());

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }

  try {
    const events = await tbaGet(`/events/${year}/simple`);
    res.json(events);
  } catch (err) {
    console.error('Events list error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load events' });
  }
});

app.get('/match/data', async (req, res) => {
  const teamNumber = cleanString(req.query.teamNumber);
  const eventKey = cleanString(req.query.eventKey);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!teamNumber || !eventKey) {
    return res.status(400).json({ error: 'teamNumber and eventKey are required' });
  }

  const teamKey = `frc${teamNumber}`;
  try {
    const [matches, oprs, status] = await Promise.all([
      tbaGet(`/team/${teamKey}/event/${eventKey}/matches/simple`),
      tbaGetOprs(eventKey),
      tbaGet(`/team/${teamKey}/event/${eventKey}/status`).catch(() => null),
    ]);
    res.json({
      matches,
      oprs: oprs.oprs || {},
      status,
    });
  } catch (err) {
    console.error('Match data error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load match data' });
  }
});


app.get('/event/matches', async (req, res) => {
  const eventKey = cleanString(req.query.eventKey);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!eventKey) {
    return res.status(400).json({ error: 'eventKey is required' });
  }

  try {
    const matches = await tbaGet(`/event/${eventKey}/matches/simple`);
    res.json({ matches });
  } catch (err) {
    console.error('Event matches error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load event matches' });
  }
});

app.get('/event/alliances', async (req, res) => {
  const eventKey = cleanString(req.query.eventKey);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!eventKey) {
    return res.status(400).json({ error: 'eventKey is required' });
  }

  try {
    const alliances = await tbaGet(`/event/${eventKey}/alliances`);
    res.json({ alliances: alliances || [] });
  } catch (err) {
    console.error('Event alliances error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load event alliances' });
  }
});

app.get('/event/roster', async (req, res) => {
  const teamNumber = cleanString(req.query.teamNumber);
  const eventKey = cleanString(req.query.eventKey);

  if (!teamNumber || !eventKey) {
    return res.status(400).json({ error: 'teamNumber and eventKey are required' });
  }

  try {
    const doc = await eventRostersCollection.findOne({ teamNumber, eventKey });
    res.json({ people: doc?.people || [] });
  } catch (err) {
    console.error('Roster fetch error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/event/roster/add', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const eventKey = cleanString(req.body.eventKey);
    const name = cleanString(req.body.name);
    if (!eventKey || !name) {
      return res.status(400).json({ error: 'eventKey and name are required' });
    }

    await eventRostersCollection.updateOne(
      { teamNumber: team.teamNumber, eventKey },
      { $addToSet: { people: name }, $set: { updatedAt: new Date().toISOString() } },
      { upsert: true },
    );

    res.json({ ok: true });
  } catch (err) {
    console.error('Roster add error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/event/roster/remove', async (req, res) => {
  try {
    const team = await checkTeamAuth(req, res);
    if (!team) return;

    const eventKey = cleanString(req.body.eventKey);
    const name = cleanString(req.body.name);
    if (!eventKey || !name) {
      return res.status(400).json({ error: 'eventKey and name are required' });
    }

    await eventRostersCollection.updateOne(
      { teamNumber: team.teamNumber, eventKey },
      { $pull: { people: name }, $set: { updatedAt: new Date().toISOString() } },
    );

    res.json({ ok: true });
  } catch (err) {
    console.error('Roster remove error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/push/config', (req, res) => {
  if (!webpushConfigured) {
    return res.status(503).json({ error: 'Push notifications are not configured on the server' });
  }
  res.json({ vapidPublicKey: VAPID_PUBLIC_KEY });
});

app.post('/push/subscribe', async (req, res) => {
  if (!webpushConfigured) {
    return res.status(503).json({ error: 'Push notifications are not configured on the server' });
  }

  const teamNumber = cleanString(req.body.teamNumber);
  const eventKey = cleanString(req.body.eventKey);
  const subscription = req.body.subscription;
  const platform = cleanString(req.body.platform) === 'ios' ? 'ios' : 'web';

  if (!teamNumber || !eventKey || !subscription?.endpoint) {
    return res.status(400).json({ error: 'Missing fields' });
  }

  try {
    await pushSubscriptionsCollection.updateOne(
      { endpoint: subscription.endpoint },
      { $set: { teamNumber, eventKey, subscription, platform, updatedAt: new Date().toISOString() } },
      { upsert: true },
    );
    let testSent = false;
    try {
      testSent = await sendPushBurst(
      { subscription, platform },
      { title: 'Marble alerts are on', body: `You will get a reminder before Team ${teamNumber}'s matches.`, url: '/' },
      `confirm:${teamNumber}:${eventKey}`
      );
    } catch (err) {
    console.warn('Push test notification failed:', err.message);
    }
    res.json({ ok: true, testSent });
  } catch (err) {
    console.error('Push subscribe error:', err);
    res.status(500).json({ error: 'Could not save subscription' });
  }
});

app.post('/push/unsubscribe', async (req, res) => {
  const endpoint = cleanString(req.body.endpoint);
  if (!endpoint) {
    return res.status(400).json({ error: 'endpoint required' });
  }

  try {
    await pushSubscriptionsCollection.deleteOne({ endpoint });
    res.json({ ok: true });
  } catch (err) {
    console.error('Push unsubscribe error:', err);
    res.status(500).json({ error: 'Could not remove subscription' });
  }
});

app.get('/push/check', async (req, res) => {
  if (!webpushConfigured) {
    return res.status(503).json({ error: 'Push notifications are not fully configured' });
  }
  if (!PUSH_CHECK_SECRET || req.query.secret !== PUSH_CHECK_SECRET) {
    return res.status(403).json({ error: 'Forbidden' });
  }

  try {
    const subs = await pushSubscriptionsCollection.find({}).toArray();
    if (subs.length === 0) {
      return res.json({ checked: 0, sent: 0 });
    }

    const groups = new Map();
    for (const sub of subs) {
      const key = `${sub.teamNumber}|${sub.eventKey}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(sub);
    }

    let sent = 0;
    for (const [key, groupSubs] of groups) {
      try {
        const [teamNumber, eventKey] = key.split('|');
        const teamKey = `frc${teamNumber}`;

        if (!TBA_AUTH_KEY) continue;
        let matches;
        try {
          matches = await tbaGet(`/team/${teamKey}/event/${eventKey}/matches/simple`);
        } catch (err) {
          continue;
        }

        matches = matches.filter(
          (m) =>
            m.alliances?.red?.team_keys?.includes(teamKey) ||
            m.alliances?.blue?.team_keys?.includes(teamKey),
        );

        const now = Date.now();
        const label = (match) =>
          match.comp_level === 'qm'
            ? `Quals ${match.match_number}`
            : match.comp_level === 'f'
              ? `Finals ${match.match_number}`
              : match.comp_level === 'sf'
                ? `Playoff ${match.set_number}`
                : `${match.comp_level.toUpperCase()} ${match.match_number}`;

        let oprMapPromise = null;
        const getOprMap = () => {
          if (!oprMapPromise) {
            oprMapPromise = getLiveEventRatings(eventKey).catch(async () => ({
              ratings: (await tbaGetOprs(eventKey)).oprs || {}, mean: 0, scale: DEFAULT_WIN_PROB_SCALE,
            }));
          }
          return oprMapPromise;
        };

        for (const match of matches) {
          const played =
            match.alliances?.red?.score >= 0 && match.alliances?.blue?.score >= 0;

          if (played) {
            const matchTimeSec = match.actual_time || match.predicted_time;
            if (!matchTimeSec) continue;
            const minsSincePlayed = (now - matchTimeSec * 1000) / 60000;
            if (minsSincePlayed < 0 || minsSincePlayed > FINAL_SCORE_WINDOW_MIN) continue;

            const finalMatchKey = `${match.key}::final`;
            const alreadyNotified = await notifiedMatchesCollection.findOne({
              teamNumber,
              eventKey,
              matchKey: finalMatchKey,
            });
            if (alreadyNotified) continue;

            const summary = finalScoreSummary(match, teamKey);
            const { title, body } = notificationForStage(teamNumber, label(match), 'final', { summary });
            const tagSeed = finalMatchKey;
            let deliveredAny = false;
            for (const sub of groupSubs) {
              if (await sendPushBurst(sub, { title, body, url: '/' }, tagSeed)) {
                sent++;
                deliveredAny = true;
              }
            }

            if (deliveredAny) {
              try {
                await notifiedMatchesCollection.insertOne({
                  teamNumber,
                  eventKey,
                  matchKey: finalMatchKey,
                  createdAt: new Date(),
                });
              } catch (err) {

              }
            }
            continue;
          }

          if (!match.predicted_time) continue;

          const minsAway = (match.predicted_time * 1000 - now) / 60000;
          const stage = stageForMinutesAway(minsAway);
          if (!stage) continue;

          const stageMatchKey = `${match.key}::${stage}`;
          const alreadyNotifiedStage = await notifiedMatchesCollection.findOne({
            teamNumber,
            eventKey,
            matchKey: stageMatchKey,
          });
          if (alreadyNotifiedStage) continue;

          let extra = {};
          if (stage === 'alliance') {
            extra = { teammates: allianceTeammates(match, teamKey) };
          } else if (stage === 'queue') {
            extra = { slotLabel: allianceSlotLabel(match, teamKey) };
          } else if (stage === 'matchup') {
            try {
              const oprMap = await getOprMap();
              extra = buildMatchupContext(match, teamKey, oprMap) || {};
            } catch (err) {
              extra = {};
            }
          }

          const { title, body } = notificationForStage(teamNumber, label(match), stage, extra);
          const tagSeed = stageMatchKey;

          let deliveredAnyStage = false;
          for (const sub of groupSubs) {
            if (await sendPushBurst(sub, { title, body, url: '/' }, tagSeed)) {
              sent++;
              deliveredAnyStage = true;
            }
          }
          if (deliveredAnyStage) {
            try {
              await notifiedMatchesCollection.insertOne({
                teamNumber,
                eventKey,
                matchKey: stageMatchKey,
                createdAt: new Date(),
              });
            } catch (err) {

            }
          }
        }
      } catch (err) {

        console.error(`Push check failed for group ${key}:`, err);
      }
    }

    res.json({ checked: groups.size, sent });
  } catch (err) {
    console.error('Push check error:', err);
    res.status(500).json({ error: 'Check failed' });
  }
});

app.get('/event/stats', async (req, res) => {
  const eventKey = cleanString(req.query.eventKey);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!eventKey) {
    return res.status(400).json({ error: 'eventKey is required' });
  }

  try {
    const [teams, rankings, oprData] = await Promise.all([
      tbaGet(`/event/${eventKey}/teams/simple`),
      tbaGet(`/event/${eventKey}/rankings`).catch(() => ({ rankings: [] })),
      tbaGetOprs(eventKey),
    ]);
    const names = new Map(teams.map((team) => [team.key, team.nickname || `Team ${team.team_number}`]));
    const rankingByTeam = new Map((rankings.rankings || []).map((ranking) => [ranking.team_key, ranking]));
    const teamKeys = new Set([...names.keys(), ...Object.keys(oprData.oprs || {})]);

    const stats = [...teamKeys].map((teamKey) => {
      const ranking = rankingByTeam.get(teamKey);
      const record = ranking?.record || {};
      const rawOpr = oprData.oprs?.[teamKey];
      return {
        team_number: teamKey.replace(/^frc/, ''),
        name: names.get(teamKey) || `Team ${teamKey.replace(/^frc/, '')}`,
        opr: rawOpr === undefined ? null : Number(rawOpr),
        rank: ranking?.rank ?? 0,
        wins: record.wins || 0,
        losses: record.losses || 0,
        ties: record.ties || 0,
      };
    });
    stats.sort((a, b) => (a.rank || Number.MAX_SAFE_INTEGER) - (b.rank || Number.MAX_SAFE_INTEGER) || (b.opr ?? 0) - (a.opr ?? 0));
    res.json(stats);
  } catch (err) {
    console.error('Event stats error:', err.message);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load event stats' });
  }
});

const WORLD_RATING_CACHE_MS = 12 * 60 * 60 * 1000;
const RATING_MODEL_VERSION = 3;

async function mapWithConcurrency(items, limit, work) {
  const results = [];
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const index = next++;
      try {
        results.push(await work(items[index]));
      } catch (err) {
        console.warn(`World rating skipped ${items[index].key}: ${err.message}`);
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

const FOREVER_DAYS = 1e9;
const DEFAULT_RATING_PARAMS = {
  mode: 'online',
  lr: 0.15,
  playoffFactor: 0.5,
  lrDecayMatches: FOREVER_DAYS,
  halfLifeDays: 60,
  priorWeight: 3,
  carry: 0,
  defense: 0,
  ridgeLambda: 5,
};
const TUNING_GRID = {
  mode: ['online', 'ridge'],
  halfLifeDays: [30, 60, 120, FOREVER_DAYS],
  priorWeight: [1, 3, 8],
  carry: [0, 0.5, 1],
  playoffFactor: [0.5, 1],
  lr: [0.05, 0.1, 0.15, 0.25, 0.4],
  lrDecayMatches: [4, 8, 16, FOREVER_DAYS],
  defense: [0, 0.3, 0.6],
  ridgeLambda: [2, 5, 12],
};
const ONLINE_ONLY_PARAMS = new Set(['lr', 'lrDecayMatches', 'defense']);
const RIDGE_ONLY_PARAMS = new Set(['ridgeLambda']);
const RIDGE_REFIT_EVERY = 3;
const MIN_TUNING_GAMES = 200;
const MIN_HOLDOUT_GAMES = 300;
const PRIOR_SEASON_VERSION = 1;
const DEFAULT_WIN_PROB_SCALE = 20;
const WIN_PROB_SCALE_CANDIDATES = [4, 6, 8, 10, 12, 15, 18, 22, 26, 32, 40, 50, 65, 80, 100, 130];
const LEVEL_ORDER = { p: 0, qm: 1, ef: 2, qf: 3, sf: 4, f: 5 };
const MS_PER_DAY = 86400000;
const LIVE_RATINGS_TTL_MS = 60 * 1000;

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

function slimMatch(m) {
  const redScore = m.alliances?.red?.score;
  const blueScore = m.alliances?.blue?.score;
  const played = typeof redScore === 'number' && typeof blueScore === 'number' && redScore >= 0 && blueScore >= 0;
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

function seasonPrior(teamKey, base, params, prev) {
  if (!prev || !(base > 0) || !(params.carry > 0)) return null;
  const z = prev.z[teamKey.replace(/^frc/, '')];
  if (z === undefined) return null;
  return Math.max(0.2 * base, base * (1 + params.carry * prev.cv * z));
}

function replayEvent(matches, priorFn, meanFn, params, hooks) {
  const live = new Map();
  const played = new Map();
  const defense = new Map();
  const hasPrior = new Set();
  const ridge = params.mode === 'ridge';
  const lrPlayoff = params.lr * params.playoffFactor;
  const qualCount = matches.filter((m) => m.level === 'qm').length || 1;
  let eventPoints = 0;
  let eventSlots = 0;
  let playoffShift = 0;
  let playoffCount = 0;
  const out = { games: 0, correct: 0, marginErr: 0, ratings: live, played };

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

    if (m.redScore !== m.blueScore && redPred !== bluePred) {
      const redWon = m.redScore > m.blueScore;
      const correct = (redPred > bluePred) === redWon;
      out.games += 1;
      if (correct) out.correct += 1;
      out.marginErr += Math.abs((redPred - bluePred) - (m.redScore - m.blueScore));
      if (hooks?.preds) hooks.preds.push(redPred - bluePred, redWon ? 1 : 0);
      if (hooks?.onGame) {
        const unseen = [...m.red, ...m.blue].filter((key) => !hasPrior.has(key)).length;
        hooks.onGame({
          level: m.level, num: m.num, qualCount, correct,
          margin: redPred - bluePred, avg: (redPred + bluePred) / 2, unseen,
        });
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
  const makeTally = () => ({ games: 0, correct: 0, marginErr: 0, events: 0, preds: collect ? [] : null });
  const tune = makeTally();
  const hold = makeTally();

  for (const d of ordered) {
    const tally = isHoldout && isHoldout(d) ? hold : tune;
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
      onGame: onGame ? (g) => onGame({ ...g, week }) : null,
    });
    tally.games += res.games;
    tally.correct += res.correct;
    tally.marginErr += res.marginErr;
    if (res.games > 0) tally.events += 1;

    const seen = new Set();
    for (const [teamKey, count] of res.played) {
      seen.add(teamKey);
      if (!history.has(teamKey)) history.set(teamKey, []);
      history.get(teamKey).push({ endMs: d.endMs, rating: res.ratings.get(teamKey), weight: count });
    }
    for (const row of d.rows) {
      if (seen.has(row.teamKey)) continue;
      if (!history.has(row.teamKey)) history.set(row.teamKey, []);
      history.get(row.teamKey).push({ endMs: d.endMs, rating: row.opr, weight: row.weight });
    }
  }
  return { history, tune, hold };
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

async function tuneRatingParams(eventData, prev, isHoldout) {
  const memo = new Map();
  const evaluate = async (params) => {
    const key = JSON.stringify(params);
    if (memo.has(key)) return memo.get(key);
    const run = runSeasonModel(eventData, params, { prev, isHoldout, collect: true });
    const result = {
      params,
      games: run.tune.games,
      loss: fitWinProbScale(run.tune.preds).loss,
    };
    memo.set(key, result);
    await new Promise((resolve) => setImmediate(resolve));
    return result;
  };

  let best = await evaluate({ ...DEFAULT_RATING_PARAMS });
  if (best.games < MIN_TUNING_GAMES) return best.params;
  for (let pass = 0; pass < 2; pass++) {
    let improved = false;
    for (const key of Object.keys(TUNING_GRID)) {
      if (best.params.mode === 'ridge' && ONLINE_ONLY_PARAMS.has(key)) continue;
      if (best.params.mode !== 'ridge' && RIDGE_ONLY_PARAMS.has(key)) continue;
      const options = key === 'carry' && !prev ? [0] : TUNING_GRID[key];
      for (const value of options) {
        if (value === best.params[key]) continue;
        const candidate = await evaluate({ ...best.params, [key]: value });
        if (candidate.loss < best.loss - 1e-9) {
          best = candidate;
          improved = true;
        }
      }
    }
    if (!improved) break;
  }
  return best.params;
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

function eventSeasonData(event, rows, rawMatches) {
  return {
    event,
    rows,
    matches: (Array.isArray(rawMatches) ? rawMatches : []).map(slimMatch),
    startMs: Date.parse(`${event.start_date}T00:00:00Z`),
    endMs: Date.parse(`${event.end_date}T23:59:59Z`),
  };
}

async function loadPreviousSeason(year) {
  const id = `priorSeason_${year - 1}`;
  const cached = await worldRatingsCollection.findOne({ _id: id });
  if (cached && cached.version === PRIOR_SEASON_VERSION) return cached;

  const events = await tbaGet(`/events/${year - 1}/simple`);
  const official = events.filter((event) =>
    [0, 1, 2, 3, 4].includes(event.event_type) && event.start_date && event.end_date);
  const eventData = await mapWithConcurrency(official, 6, async (event) =>
    eventSeasonData(event, [], await tbaGet(`/event/${event.key}/matches`)));
  if (eventData.length === 0) return null;

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
  const doc = {
    _id: id, version: PRIOR_SEASON_VERSION, year: year - 1, z,
    cv: Number((sd / mean).toFixed(4)), refreshedAt: new Date(),
  };
  await worldRatingsCollection.replaceOne({ _id: id }, doc, { upsert: true });
  return doc;
}

async function rebuildWorldRatings(year) {
  const events = await tbaGet(`/events/${year}/simple`);
  const official = events.filter((event) =>
    [0, 1, 2, 3, 4].includes(event.event_type) && event.end_date &&
    new Date(`${event.end_date}T23:59:59Z`) <= new Date(),
  );
  const eventData = await mapWithConcurrency(official, 6, async (event) => {
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
      return { teamKey, name: names.get(teamKey) || `Team ${teamKey.replace(/^frc/, '')}`,
        opr: Number(rawOpr || 0), weight: Math.max(1, playedCount),
        wins: record.wins || 0, losses: record.losses || 0, ties: record.ties || 0 };
    });
    return eventSeasonData(event, rows, rawMatches);
  });

  const prev = await loadPreviousSeason(year).catch((err) => {
    console.warn(`Previous season prior unavailable: ${err.message}`);
    return null;
  });
  const isHoldout = (d) => hashString(d.event.key) % 2 === 1;
  const params = await tuneRatingParams(eventData, prev, isHoldout);
  const breakdown = createBreakdown();
  const run = runSeasonModel(eventData, params, {
    prev, isHoldout, collect: true, onGame: (g) => breakdown.record(g),
  });

  const allPreds = run.tune.preds.concat(run.hold.preds);
  const winProbScale = fitWinProbScale(allPreds).scale;
  const useHoldout = run.hold.games >= MIN_HOLDOUT_GAMES;
  const reported = useHoldout ? run.hold : combineTallies(run.tune, run.hold);
  const reportScale = useHoldout ? fitWinProbScale(run.tune.preds).scale : winProbScale;
  const quality = scorePreds(reported.preds, reportScale);

  const nowMs = Date.now();
  const decayed = new Map();
  let meanSum = 0;
  for (const [teamKey, hist] of run.history) {
    const { s, w } = decayedHistory(hist, nowMs, params.halfLifeDays);
    if (w > 0) { decayed.set(teamKey, { s, w }); meanSum += s / w; }
  }
  const mean = decayed.size ? meanSum / decayed.size : 0;

  const info = new Map();
  for (const d of eventData) for (const row of d.rows) {
    const old = info.get(row.teamKey) || { name: row.name, wins: 0, losses: 0, ties: 0 };
    old.name = row.name;
    old.wins += row.wins; old.losses += row.losses; old.ties += row.ties;
    info.set(row.teamKey, old);
  }
  const teams = [];
  for (const [teamKey, { s, w }] of decayed) {
    const i = info.get(teamKey) || { name: `Team ${teamKey.replace(/^frc/, '')}`, wins: 0, losses: 0, ties: 0 };
    const shrinkTarget = seasonPrior(teamKey, mean, params, prev) ?? mean;
    teams.push({
      team_number: teamKey.replace(/^frc/, ''), name: i.name,
      opr: Number(((s + shrinkTarget * params.priorWeight) / (w + params.priorWeight)).toFixed(2)),
      weight: Number(w.toFixed(2)),
      wins: i.wins, losses: i.losses, ties: i.ties,
    });
  }
  teams.sort((a, b) => b.opr - a.opr);
  teams.forEach((team, index) => { team.rank = index + 1; });

  const doc = { _id: String(year), year, teams, refreshedAt: new Date(), eventCount: official.length,
    params, winProbScale, meanRating: Number(mean.toFixed(2)), modelVersion: RATING_MODEL_VERSION };
  await worldRatingsCollection.replaceOne({ _id: doc._id }, doc, { upsert: true });
  try {
    await worldRatingsCollection.replaceOne(
      { _id: `accuracy_${year}` },
      {
        _id: `accuracy_${year}`, year, params, winProbScale, modelVersion: RATING_MODEL_VERSION,
        gradedOn: useHoldout ? 'holdout' : 'all',
        games: reported.games, correct: reported.correct, eventsCounted: reported.events,
        accuracyPct: reported.games > 0 ? Number(((reported.correct / reported.games) * 100).toFixed(1)) : null,
        avgMarginError: reported.games > 0 ? Number((reported.marginErr / reported.games).toFixed(1)) : null,
        logLoss: quality.logLoss, brier: quality.brier,
        tunedGames: run.tune.games,
        tunedAccuracyPct: run.tune.games > 0 ? Number(((run.tune.correct / run.tune.games) * 100).toFixed(1)) : null,
        breakdown: breakdown.rows(),
        refreshedAt: new Date(),
      },
      { upsert: true },
    );
  } catch (err) {
    console.error('Model accuracy calculation failed:', err.message);
  }
  liveRatingCache.clear();
  return doc;
}

const liveRatingCache = new Map();
async function getLiveEventRatings(eventKey) {
  const cached = liveRatingCache.get(eventKey);
  if (cached && Date.now() - cached.at < LIVE_RATINGS_TTL_MS) return cached.data;

  const year = String(eventKey).slice(0, 4);
  const world = await worldRatingsCollection.findOne({ _id: year }).catch(() => null);
  const prev = await worldRatingsCollection.findOne({ _id: `priorSeason_${Number(year) - 1}` }).catch(() => null);
  const priors = new Map((world?.teams || []).map((t) => [`frc${t.team_number}`, t.opr]));
  const mean = world?.meanRating || 0;
  const params = { ...DEFAULT_RATING_PARAMS, ...(world?.params || {}) };
  const scale = world?.winProbScale || DEFAULT_WIN_PROB_SCALE;

  const rawMatches = await tbaGet(`/event/${eventKey}/matches`);
  const matches = (Array.isArray(rawMatches) ? rawMatches : []).map(slimMatch);
  const priorFn = (key, base) => (priors.has(key) ? priors.get(key) : seasonPrior(key, base, params, prev));
  const res = replayEvent(matches, priorFn, () => mean, params, null);

  const ratings = {};
  for (const m of matches) {
    for (const key of [...m.red, ...m.blue]) {
      if (key in ratings) continue;
      const value = res.ratings.has(key) ? res.ratings.get(key) : priors.get(key);
      if (typeof value === 'number') ratings[key] = Number(value.toFixed(2));
    }
  }
  const values = Object.values(ratings);
  const liveMean = values.length ? values.reduce((a, b) => a + b, 0) / values.length : mean;
  const data = { ratings, mean: Number(liveMean.toFixed(2)), scale, eventKey };
  liveRatingCache.set(eventKey, { at: Date.now(), data });
  return data;
}

function startWorldRatingRefresh(year) {
  if (!worldRatingRefresh) {
    worldRatingRefresh = rebuildWorldRatings(year)
      .catch((err) => console.error('World rating refresh failed:', err.message))
      .finally(() => { worldRatingRefresh = null; });
  }
  return worldRatingRefresh;
}

app.get('/world/stats', async (req, res) => {
  if (!TBA_AUTH_KEY) return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  const year = Number(cleanString(req.query.year) || new Date().getFullYear());
  try {
    const cached = await worldRatingsCollection.findOne({ _id: String(year) });
    const stale = !cached || cached.modelVersion !== RATING_MODEL_VERSION || Date.now() - new Date(cached.refreshedAt).getTime() > WORLD_RATING_CACHE_MS;
    if (stale) startWorldRatingRefresh(year);
    if (cached) return res.json({ teams: cached.teams, year, eventCount: cached.eventCount, refreshedAt: cached.refreshedAt, refreshing: stale, winProbScale: cached.winProbScale || DEFAULT_WIN_PROB_SCALE });
    res.status(202).json({ teams: [], year, refreshing: true, message: 'World rating is being calculated. Try again shortly.' });
  } catch (err) {
    console.error('World stats error:', err.message);
    res.status(500).json({ error: 'Could not load world stats' });
  }
});


app.get('/event/ratings', async (req, res) => {
  if (!TBA_AUTH_KEY) return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  const eventKey = cleanString(req.query.eventKey);
  if (!eventKey) return res.status(400).json({ error: 'eventKey is required' });
  try {
    res.json(await getLiveEventRatings(eventKey));
  } catch (err) {
    console.error('Live ratings error:', err.message);
    res.status(err.status === 404 ? 404 : 502).json({ error: 'Could not load live ratings' });
  }
});

app.get('/world/accuracy', async (req, res) => {
  if (!TBA_AUTH_KEY) return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  const year = Number(cleanString(req.query.year) || new Date().getFullYear());
  try {
    const cached = await worldRatingsCollection.findOne({ _id: `accuracy_${year}` });
    const stale = !cached || cached.modelVersion !== RATING_MODEL_VERSION || Date.now() - new Date(cached.refreshedAt).getTime() > WORLD_RATING_CACHE_MS;
    if (stale) startWorldRatingRefresh(year);
    if (cached) {
      return res.json({
        year,
        games: cached.games,
        correct: cached.correct,
        eventsCounted: cached.eventsCounted,
        accuracyPct: cached.accuracyPct,
        avgMarginError: cached.avgMarginError,
        logLoss: cached.logLoss ?? null,
        brier: cached.brier ?? null,
        gradedOn: cached.gradedOn || 'all',
        tunedAccuracyPct: cached.tunedAccuracyPct ?? null,
        breakdown: cached.breakdown || [],
        refreshedAt: cached.refreshedAt,
        refreshing: stale,
        params: cached.params || null,
        modelVersion: cached.modelVersion || 1,
      });
    }
    res.status(202).json({ year, refreshing: true, message: 'Accuracy is being calculated. Try again in a minute or two.' });
  } catch (err) {
    console.error('World accuracy error:', err.message);
    res.status(500).json({ error: 'Could not load model accuracy' });
  }
});

app.get('/world/team/:teamNumber', async (req, res) => {
  const year = String(new Date().getFullYear());
  try {
    const cached = await worldRatingsCollection.findOne({ _id: year });
    if (!cached) return res.status(202).json({ error: 'World rating is being calculated' });
    const index = cached.teams.findIndex((team) => team.team_number === req.params.teamNumber);
    if (index < 0) return res.status(404).json({ error: 'Team is not in the current world rating' });
    res.json({ team: cached.teams[index], nearby: cached.teams.slice(Math.max(0, index - 2), index + 4) });
  } catch (err) {
    res.status(500).json({ error: 'Could not load team rating' });
  }
});

app.get('/event/teams', async (req, res) => {
  const eventKey = cleanString(req.query.eventKey);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!eventKey) {
    return res.status(400).json({ error: 'eventKey is required' });
  }

  try {
    const cached = await eventTeamsCollection.findOne({ eventKey });
    if (cached && Date.now() - new Date(cached.refreshedAt).getTime() < 6 * 60 * 60 * 1000) {
      return res.json(cached.teams);
    }
    const teams = await tbaGet(`/event/${eventKey}/teams/simple`);
    const mapped = teams
      .map((t) => ({
        team_number: String(t.team_number),
        name: t.nickname || `Team ${t.team_number}`,
      }))
      .sort((a, b) => Number(a.team_number) - Number(b.team_number));
    await eventTeamsCollection.updateOne(
      { eventKey },
      { $set: { teams: mapped, refreshedAt: new Date() } },
      { upsert: true },
    );
    res.json(mapped);
  } catch (err) {
    console.error('Event teams error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load event teams' });
  }
});

app.get('/team/profile', async (req, res) => {
  const teamNumber = cleanString(req.query.teamNumber);

  if (!TBA_AUTH_KEY) {
    return res.status(503).json({ error: 'TBA_AUTH_KEY is not configured on the server' });
  }
  if (!teamNumber) {
    return res.status(400).json({ error: 'teamNumber is required' });
  }

  const teamKey = `frc${teamNumber}`;
  try {
    const teamInfo = await tbaGet(`/team/${teamKey}`);
    const [yearsParticipated, awards] = await Promise.all([
      tbaGet(`/team/${teamKey}/years_participated`).catch(() => []),
      tbaGet(`/team/${teamKey}/awards`).catch(() => []),
    ]);


    const perYear = await Promise.all(
      yearsParticipated.map(async (year) => {
        try {
          const [events, statuses] = await Promise.all([
            tbaGet(`/team/${teamKey}/events/${year}/simple`),
            tbaGet(`/team/${teamKey}/events/${year}/statuses`).catch(() => ({})),
          ]);
          return events.map((event) => {
            const status = statuses[event.key];
            const ranking = status?.qual?.ranking;
            return {
              eventKey: event.key,
              eventName: event.name,
              year,
              rank: ranking?.rank ?? null,
              numTeams: status?.qual?.num_teams ?? null,
            };
          });
        } catch (err) {
          return [];
        }
      }),
    );

    const flatEvents = perYear.flat();
    const eventNameByKey = new Map(flatEvents.map((e) => [e.eventKey, e.eventName]));

    const rating = await worldRatingsCollection.findOne({ _id: String(new Date().getFullYear()) });
    const worldRank = rating?.teams?.find((team) => team.team_number === teamNumber)?.rank ?? null;

    res.json({
      team_name: teamInfo.nickname || teamInfo.name || `Team ${teamNumber}`,
      rookie_year: teamInfo.rookie_year || null,
      world_rank: worldRank,
      events: flatEvents.map((e) => ({
        event_key: e.eventKey,
        event_name: e.eventName,
        year: e.year,
        rank: e.rank,
        num_teams: e.numTeams,
        awards: awards.filter((a) => a.event_key === e.eventKey).map((a) => a.name),
      })),
      awards: awards.map((a) => ({
        name: a.name,
        event_name: eventNameByKey.get(a.event_key) || a.event_key,
        year: a.year,
      })).sort((a, b) => b.year - a.year),
    });
  } catch (err) {
    console.error('Team profile error:', err);
    res.status(err.status === 404 ? 404 : 500).json({ error: 'Could not load team profile' });
  }
});

connectToMongo()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`Server running on port ${PORT}`);
    });
  })
  .catch((err) => {
    console.error('Failed to connect to MongoDB:', err);
    process.exit(1);
  });