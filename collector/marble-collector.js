#!/usr/bin/env node
'use strict';

// Marble Collector: watches for new .wpilog files (log USB stick or a download
// folder), computes battery metrics, and uploads them to Marble's Match Logs.
// No dependencies. Needs Node 18+.
//
//   node marble-collector.js              run (first run does setup)
//   node marble-collector.js --setup      redo setup
//   node marble-collector.js --yes        auto-assign to the "In use" battery, no prompts
//   node marble-collector.js --all        also import logs older than maxAgeHours
//   node marble-collector.js --reimport   import logs even if already handled before
//   node marble-collector.js --once       scan once and exit
//   node marble-collector.js --analyze f.wpilog   print metrics only, no upload
//   node marble-collector.js --signals f.wpilog   list every signal in a log

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const readline = require('readline');
const { DEFAULT_SIGNALS, analyzeFile, matchNameFromFile } = require('./wpilog');

const DIR = process.env.MARBLE_COLLECTOR_DIR || __dirname;
const CONFIG_PATH = path.join(DIR, 'config.json');
const STATE_PATH = path.join(DIR, 'collector-state.json');

const DEFAULTS = {
  apiBase: 'https://ridgeboticsapp.onrender.com',
  teamNumber: '',
  passcode: '',
  watchFolders: [],        // extra folders, e.g. the Driver Station download folder
  scanDrives: true,        // look for <drive>:\logs on every drive letter (USB sticks)
  driveSubfolder: 'logs',
  pollSeconds: 3,
  maxAgeHours: 6,          // ignore logs older than this unless --all
  minEnabledSeconds: 15,   // skip pit tests shorter than this
  signals: {},             // override signal names, see README
};

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const flagValue = (name) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : null; };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const stamp = () => new Date().toLocaleTimeString();
const log = (msg) => console.log(`[${stamp()}] ${msg}`);
const fmt = (v, d = 2) => (v === null || v === undefined ? '-' : Number(v).toFixed(d));

function loadJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function saveJson(file, data) {
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, file);
}

let rl;
let inputClosed = false;
function ask(question) {
  if (!rl) {
    rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.on('close', () => { inputClosed = true; });
  }
  if (inputClosed) {
    const err = new Error('No keyboard input available. Run in a normal terminal, or use --yes.');
    err.code = 'INPUT_CLOSED';
    return Promise.reject(err);
  }
  return new Promise((resolve, reject) => {
    rl.once('close', () => { const e = new Error('Input closed'); e.code = 'INPUT_CLOSED'; reject(e); });
    rl.question(question, (a) => resolve(a.trim()));
  });
}

// ---------- Marble API ----------

async function api(config, method, route, body) {
  const url = `${config.apiBase}${route}`;
  const res = await fetch(url, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  });
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  return { status: res.status, data };
}

async function fetchBatteries(config) {
  const q = `teamNumber=${encodeURIComponent(config.teamNumber)}&passcode=${encodeURIComponent(config.passcode)}`;
  const { status, data } = await api(config, 'GET', `/battery/list?${q}`);
  if (status !== 200) throw new Error(`battery list failed (${status})`);
  return data.batteries || [];
}

// ---------- setup ----------

async function setup(existing) {
  console.log('\nMarble Collector setup\n');
  const config = { ...DEFAULTS, ...existing };
  config.teamNumber = (await ask(`Team number${config.teamNumber ? ` [${config.teamNumber}]` : ''}: `)) || config.teamNumber;
  config.passcode = (await ask('Battery tracker passcode: ')) || config.passcode;
  const folder = await ask('Extra folder to watch (e.g. Driver Station log downloads), or Enter to skip: ');
  if (folder) config.watchFolders = [folder];
  process.stdout.write('Checking login... ');
  try {
    const { status } = await api(config, 'POST', '/battery/login', { teamNumber: config.teamNumber, passcode: config.passcode });
    console.log(status === 200 ? 'ok' : `failed (${status}); check team number and passcode`);
    if (status !== 200) return setup(config);
  } catch (err) {
    console.log(`could not reach Marble (${err.message}); saving anyway, it will retry`);
  }
  saveJson(CONFIG_PATH, config);
  console.log(`Saved ${CONFIG_PATH}\n`);
  return config;
}

// ---------- finding files ----------

async function candidateFolders(config) {
  const folders = new Set(config.watchFolders.filter(Boolean));
  if (config.scanDrives && process.platform === 'win32') {
    const letters = 'DEFGHIJKLMNOPQRSTUVWXYZ'.split('');
    const subs = [config.driveSubfolder, ''].filter((v, i, a) => a.indexOf(v) === i);
    const found = await Promise.all(letters.flatMap((l) => subs.map(async (sub) => {
      const dir = sub ? `${l}:\\${sub}` : `${l}:\\`;
      try { await fs.promises.access(dir); return dir; } catch { return null; }
    })));
    found.filter(Boolean).forEach((d) => folders.add(d));
  }
  return [...folders];
}

async function listLogs(folders) {
  const files = [];
  const info = new Map(); // folder -> { wpilog, dslog }
  for (const dir of folders) {
    let names;
    try { names = await fs.promises.readdir(dir); } catch { continue; }
    const counts = { wpilog: 0, dslog: 0 };
    for (const name of names) {
      const lower = name.toLowerCase();
      if (lower.endsWith('.dslog')) counts.dslog++;
      if (!lower.endsWith('.wpilog')) continue;
      counts.wpilog++;
      const full = path.join(dir, name);
      try {
        const st = await fs.promises.stat(full);
        files.push({ path: full, size: st.size, mtimeMs: st.mtimeMs });
      } catch { /* file vanished */ }
    }
    info.set(dir, counts);
  }
  return { files, info };
}

// Tell the user what was found in each folder, once per change, so a silent
// "nothing happens" never looks like a bug.
const lastNotice = new Map();
function reportFolders(info) {
  for (const [dir, c] of info) {
    const key = `${c.wpilog}|${c.dslog}`;
    if (lastNotice.get(dir) === key) continue;
    lastNotice.set(dir, key);
    if (c.wpilog > 0) log(`Found ${c.wpilog} .wpilog file(s) in ${dir}`);
    else if (c.dslog > 0) log(`${dir} has ${c.dslog} Driver Station log(s) (.dslog) but no .wpilog. Driver Station logs don't include battery current; Marble needs the robot's .wpilog files from the roboRIO's USB stick.`);
    else log(`Looking in ${dir}: no .wpilog files yet.`);
  }
}

// A file counts as finished copying once its size and mtime are unchanged between
// two polls. The file's age is NOT used: a roboRIO with the wrong clock writes
// files dated in the past or future.
const seen = new Map();
function isStable(file) {
  const prev = seen.get(file.path);
  seen.set(file.path, { size: file.size, mtimeMs: file.mtimeMs });
  return !!prev && prev.size === file.size && prev.mtimeMs === file.mtimeMs;
}

function logId(buf) {
  return crypto.createHash('sha1').update(String(buf.length)).update(buf.subarray(0, 1 << 20)).digest('hex');
}

// ---------- processing ----------

function printSummary(name, m) {
  console.log(`\n  ${name}  (${fmt(m.enabledSeconds, 0)} s enabled${m.hasEnabledSignal ? '' : ', no enabled signal: whole log used'})`);
  console.log(`  min voltage ${fmt(m.minimumVoltage)} V | below 8V ${fmt(m.secondsBelow8Volts, 1)} s | brownouts ${m.brownoutCount ?? '-'} | ${fmt(m.ampHoursUsed)} Ah | ${fmt(m.internalResistanceMilliohms, 1)} mΩ`);
  if (m.missing.length) console.log(`  missing signals: ${m.missing.join(', ')} (run --signals on this file to see real names)`);
}

const RETRY = Symbol('retry');
const warned = new Set();

async function chooseBattery(config, batteries, isNewest, matchName) {
  const labels = batteries.map((b) => b.label);
  const inUse = batteries.filter((b) => b.isInUse).map((b) => b.label);
  const suggestion = isNewest && inUse.length === 1 ? inUse[0] : null;

  if (flag('yes')) {
    if (suggestion) return suggestion;
    if (isNewest) {
      // Likely fixable by tapping "In use" in Marble, so keep checking instead of discarding.
      if (!warned.has(matchName)) {
        warned.add(matchName);
        log(`${matchName}: waiting for exactly one battery marked In use in Marble (found ${inUse.length}).`);
      }
      return RETRY;
    }
    log(`${matchName}: older log, can't guess its battery; skipping. Run without --yes to choose.`);
    return null;
  }
  const hint = batteries.length ? `Batteries: ${labels.join(', ')}` : "Couldn't load battery list";
  const prompt = suggestion
    ? `  Assign ${matchName} to ${suggestion}? [Enter = yes, type another label, s = skip]: `
    : `  Which battery for ${matchName}? ${hint}  [type label, s = skip]: `;
  for (;;) {
    const answer = await ask(prompt);
    if (answer === '' && suggestion) return suggestion;
    if (/^s(kip)?$/i.test(answer) || (answer === '' && !suggestion)) return null;
    const match = batteries.find((b) => b.label.toLowerCase() === answer.toLowerCase());
    if (match) return match.label;
    if (!batteries.length && answer) return answer; // offline: trust the typed label
    console.log('  No battery with that label.');
  }
}

async function upload(config, payload) {
  const { status, data } = await api(config, 'POST', '/battery/telemetry', {
    teamNumber: config.teamNumber, passcode: config.passcode, ...payload,
  });
  if (status === 200 || status === 409) return { ok: true, duplicate: status === 409 };
  if (status === 400 || status === 401 || status === 404) {
    return { ok: false, fatal: true, error: data?.error || `HTTP ${status}` };
  }
  return { ok: false, error: data?.error || `HTTP ${status}` };
}

async function flushPending(config, state) {
  for (const item of [...state.pending]) {
    try {
      const res = await upload(config, item.payload);
      if (res.ok || res.fatal) {
        state.pending = state.pending.filter((p) => p !== item);
        state.done[item.payload.logId] = { file: item.payload.logFile, at: new Date().toISOString(), status: res.ok ? 'uploaded' : 'rejected' };
        saveJson(STATE_PATH, state);
        log(res.ok ? `Uploaded queued ${item.payload.matchName} -> ${item.payload.label}` : `Dropped queued ${item.payload.matchName}: ${res.error}`);
      }
    } catch { return; } // still offline; try again next poll
  }
}

const reportedDone = new Set();

// Reads and analyzes a log. Returns null when it should be ignored (and records why).
function prepareFile(config, state, file) {
  const base = path.basename(file.path);
  const markDone = (id, status) => {
    state.done[id] = { file: base, at: new Date().toISOString(), status };
    saveJson(STATE_PATH, state);
  };
  let analysis;
  try {
    analysis = analyzeFile(file.path, { ...DEFAULT_SIGNALS, ...config.signals });
  } catch (err) {
    const key = `bad:${file.path}:${file.size}`;
    if (!state.done[key]) { log(`Could not read ${base}: ${err.message}`); markDone(key, 'unreadable'); }
    return null;
  }
  const id = logId(analysis.buf);
  const previous = state.done[id];
  if (previous && !flag('reimport')) {
    if (!reportedDone.has(id)) {
      reportedDone.add(id);
      log(`Already handled ${base} (${previous.status}${previous.label ? ` -> ${previous.label}` : ''}). To import it again, restart with: node marble-collector.js --reimport`);
    }
    return null;
  }
  if (state.pending.some((p) => p.payload.logId === id)) return null;

  const m = analysis.metrics;
  if (m.enabledSeconds < config.minEnabledSeconds) {
    log(`Skipping ${base}: only ${fmt(m.enabledSeconds, 0)} s enabled`);
    markDone(id, 'too short');
    return null;
  }
  if (m.minimumVoltage === null && m.ampHoursUsed === null) {
    log(`Skipping ${base}: no battery signals found. Run: node marble-collector.js --signals "${file.path}"`);
    markDone(id, 'no signals');
    return null;
  }
  return { file, base, id, m, matchName: matchNameFromFile(file.path, new Date(file.mtimeMs)) };
}

async function deliver(config, state, item, isNewest) {
  const { base, id, m, matchName } = item;
  log(`New log: ${base}`);
  printSummary(matchName, m);

  let batteries = [];
  try {
    batteries = await fetchBatteries(config);
  } catch (err) {
    log(`Could not load batteries (${err.message})`);
    if (flag('yes')) return RETRY;
  }
  const label = await chooseBattery(config, batteries, isNewest, matchName);
  if (label === RETRY) return RETRY;
  if (!label) {
    state.done[id] = { file: base, at: new Date().toISOString(), status: 'skipped' };
    saveJson(STATE_PATH, state);
    return null;
  }

  const round = (v, d) => (v === null ? null : Number(v.toFixed(d)));
  const payload = {
    label, matchName, source: 'wpilog', logId: id, logFile: base,
    minimumVoltage: round(m.minimumVoltage, 2),
    secondsBelow8Volts: round(m.secondsBelow8Volts, 2),
    brownoutCount: m.brownoutCount,
    ampHoursUsed: round(m.ampHoursUsed, 3),
    internalResistanceMilliohms: round(m.internalResistanceMilliohms, 2),
  };
  try {
    const res = await upload(config, payload);
    if (res.ok) {
      log(res.duplicate ? `${matchName} was already in Marble.` : `Uploaded ${matchName} -> ${label}`);
      state.done[id] = { file: base, at: new Date().toISOString(), status: 'uploaded', label };
    } else if (res.fatal) {
      log(`Marble rejected ${matchName}: ${res.error}`);
      state.done[id] = { file: base, at: new Date().toISOString(), status: 'rejected' };
    } else {
      log(`Marble had a problem (${res.error}); queued ${matchName} and will retry.`);
      state.pending.push({ payload });
    }
  } catch (err) {
    log(`No connection (${err.message}); queued ${matchName} and will retry.`);
    state.pending.push({ payload });
  }
  saveJson(STATE_PATH, state);
  return null;
}

const handled = new Set(); // path|size|mtime already processed this session
const announced = new Set();
const fileKey = (f) => `${f.path}|${f.size}|${f.mtimeMs}`;

async function scanOnce(config, state) {
  await flushPending(config, state);
  const folders = await candidateFolders(config);
  const listing = await listLogs(folders);
  reportFolders(listing.info);
  const files = listing.files.filter(isStable).filter((f) => !handled.has(fileKey(f))).sort((a, b) => a.mtimeMs - b.mtimeMs);
  const fresh = [];
  for (const f of files) {
    if (state.skipLogged?.[f.path] === f.size) continue;
    const tooOld = !flag('all') && Date.now() - f.mtimeMs > config.maxAgeHours * 3600 * 1000;
    if (tooOld) { (state.skipLogged ||= {})[f.path] = f.size; log(`Ignoring ${path.basename(f.path)}: its date is ${new Date(f.mtimeMs).toLocaleString()}, older than ${config.maxAgeHours} h. If the roboRIO's clock is wrong, restart with: node marble-collector.js --all`); continue; }
    fresh.push(f);
  }
  const ready = [];
  for (const f of fresh) {
    if (!announced.has(fileKey(f))) {
      announced.add(fileKey(f));
      log(`Reading ${path.basename(f.path)} (${(f.size / 1024).toFixed(0)} KB, dated ${new Date(f.mtimeMs).toLocaleString()})`);
    }
    const item = prepareFile(config, state, f);
    if (item) ready.push(item); else handled.add(fileKey(f));
  }
  for (let i = 0; i < ready.length; i++) {
    const outcome = await deliver(config, state, ready[i], i === ready.length - 1);
    if (outcome !== RETRY) handled.add(fileKey(ready[i].file));
  }
}

// ---------- entry ----------

async function main() {
  const analyzePath = flagValue('analyze');
  const signalsPath = flagValue('signals');
  if (analyzePath || signalsPath) {
    const config = { ...DEFAULTS, ...loadJson(CONFIG_PATH, {}) };
    const target = analyzePath || signalsPath;
    const { metrics, names } = analyzeFile(target, { ...DEFAULT_SIGNALS, ...config.signals });
    if (signalsPath) {
      names.sort((a, b) => a.name.localeCompare(b.name)).forEach((n) => console.log(`${n.type.padEnd(14)} ${n.name}`));
    } else {
      printSummary(matchNameFromFile(target, new Date(fs.statSync(target).mtimeMs)), metrics);
      console.log(`  resistance samples: ${metrics.resistanceSamples ?? 0}`);
    }
    return;
  }

  let config = loadJson(CONFIG_PATH, null);
  if (!config || flag('setup') || !config.teamNumber || !config.passcode) config = await setup(config || {});
  config = { ...DEFAULTS, ...config };
  const state = loadJson(STATE_PATH, { done: {}, pending: [] });
  state.pending ||= [];
  state.done ||= {};

  const folders = await candidateFolders(config);
  console.log(`Marble Collector running for team ${config.teamNumber}.`);
  console.log(folders.length ? `Watching: ${folders.join(', ')}` : 'No USB drive or log folder found yet. Plug in the log USB (checks every drive letter, in the root and in \\' + config.driveSubfolder + ') or add watchFolders in config.json. Waiting...');
  console.log('Leave this window open. Ctrl+C to stop.\n');

  do {
    try { await scanOnce(config, state); } catch (err) {
      if (err.code === 'INPUT_CLOSED') { console.error(`\n${err.message}`); process.exit(1); }
      log(`Scan error: ${err.message}`);
    }
    if (flag('once')) { await sleep(config.pollSeconds * 1000 + 500); await scanOnce(config, state); break; }
    await sleep(config.pollSeconds * 1000);
  } while (true);
  if (rl) rl.close();
}

main().catch((err) => { console.error(err); process.exit(1); });