'use strict';

// Minimal, dependency-free reader for WPILib .wpilog files plus the battery
// metric math. Format spec: https://github.com/wpilibsuite/allwpilib/blob/main/wpiutil/doc/datalog.adoc

const fs = require('fs');
const path = require('path');

// Signal names differ between setups (plain WPILib vs AdvantageKit). Names are
// compared lowercase, without leading slashes, as an exact match or a "/suffix"
// match. Override any of these in config.json under "signals".
const DEFAULT_SIGNALS = {
  voltage: ['battery/voltagevolts', 'battery/voltage', 'systemstats/batteryvoltage', 'batteryvoltage'],
  current: ['battery/totalcurrentamps', 'battery/totalcurrent', 'powerdistribution/totalcurrent', 'totalcurrent'],
  brownout: ['battery/brownedout', 'systemstats/brownedout', 'brownedout'],
  enabled: ['driverstation/enabled'],
};

const normalize = (name) => name.toLowerCase().replace(/^\/+/, '');

function matchSignal(name, signals) {
  const n = normalize(name);
  for (const [key, candidates] of Object.entries(signals)) {
    for (const raw of candidates) {
      const cand = normalize(raw);
      if (n === cand || n.endsWith('/' + cand)) return key;
    }
  }
  return null;
}

function readUInt(buf, pos, len) {
  let value = 0;
  for (let i = len - 1; i >= 0; i--) value = value * 256 + buf[pos + i];
  return value;
}

function readString(buf, pos) {
  const len = buf.readUInt32LE(pos);
  return { text: buf.toString('utf8', pos + 4, pos + 4 + len), next: pos + 4 + len };
}

// Walks every record. onStart(name, type) returns a key to collect that entry
// (or null to ignore it). Returns { names, series, lastTime }.
function parseWpilog(buf, signals = DEFAULT_SIGNALS) {
  if (buf.length < 12 || buf.toString('latin1', 0, 6) !== 'WPILOG') {
    throw new Error('Not a .wpilog file');
  }
  let pos = 12 + buf.readUInt32LE(8);
  const entries = new Map(); // entry id -> { name, type, key }
  const names = [];
  const series = {};
  let lastTime = 0;

  while (pos < buf.length) {
    const bits = buf[pos];
    const idLen = (bits & 3) + 1;
    const sizeLen = ((bits >> 2) & 3) + 1;
    const tsLen = ((bits >> 4) & 7) + 1;
    const headerLen = 1 + idLen + sizeLen + tsLen;
    if (pos + headerLen > buf.length) break; // truncated tail (robot lost power mid-write)
    let p = pos + 1;
    const id = readUInt(buf, p, idLen); p += idLen;
    const size = readUInt(buf, p, sizeLen); p += sizeLen;
    const time = readUInt(buf, p, tsLen) / 1e6; p += tsLen;
    if (p + size > buf.length) break;

    if (id === 0) {
      if (size >= 5 && buf[p] === 0) {
        const entry = buf.readUInt32LE(p + 1);
        const nameRead = readString(buf, p + 5);
        const typeRead = readString(buf, nameRead.next);
        names.push({ name: nameRead.text, type: typeRead.text });
        entries.set(entry, { name: nameRead.text, type: typeRead.text, key: matchSignal(nameRead.text, signals) });
      }
    } else {
      if (time > lastTime) lastTime = time;
      const entry = entries.get(id);
      if (entry && entry.key) {
        let value = null;
        if (entry.type === 'double' && size >= 8) value = buf.readDoubleLE(p);
        else if (entry.type === 'float' && size >= 4) value = buf.readFloatLE(p);
        else if (entry.type === 'int64' && size >= 8) value = Number(buf.readBigInt64LE(p));
        else if (entry.type === 'boolean' && size >= 1) value = buf[p] !== 0 ? 1 : 0;
        if (value !== null && Number.isFinite(value)) {
          const s = (series[entry.key] ||= { t: [], v: [] });
          s.t.push(time);
          s.v.push(value);
        }
      }
    }
    pos = p + size;
  }
  return { names, series, lastTime };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// Time windows where the robot was enabled. Without an enabled signal the
// whole voltage series counts.
function enabledWindows(series, lastTime) {
  const en = series.enabled;
  if (!en || en.t.length === 0) {
    const start = series.voltage ? series.voltage.t[0] : 0;
    return { windows: [[start, lastTime]], hasSignal: false };
  }
  const windows = [];
  let start = null;
  for (let i = 0; i < en.t.length; i++) {
    if (en.v[i] && start === null) start = en.t[i];
    if (!en.v[i] && start !== null) { windows.push([start, en.t[i]]); start = null; }
  }
  if (start !== null) windows.push([start, lastTime]);
  return { windows, hasSignal: true };
}

function inWindows(windows) {
  let w = 0;
  return (t) => {
    while (w < windows.length && t > windows[w][1]) w++;
    return w < windows.length && t >= windows[w][0];
  };
}

const MAX_DT = 0.1; // seconds; stops a logging gap from counting as real draw

function computeMetrics(series, lastTime, opts = {}) {
  const minDeltaAmps = opts.minDeltaAmps ?? 15;
  const { windows, hasSignal } = enabledWindows(series, lastTime);
  const enabledSeconds = windows.reduce((sum, [a, b]) => sum + (b - a), 0);
  const result = {
    minimumVoltage: null, secondsBelow8Volts: null, brownoutCount: null,
    ampHoursUsed: null, internalResistanceMilliohms: null,
    enabledSeconds, hasEnabledSignal: hasSignal,
    enabledWindows: windows,
    missing: ['voltage', 'current', 'brownout'].filter((k) => !series[k]),
    currentSignalDead: false,
  };
  if (enabledSeconds <= 0) return result;
  const enabled = inWindows(windows);

  const volt = series.voltage;
  if (volt) {
    let min = Infinity;
    let below = 0;
    for (let i = 0; i < volt.t.length; i++) {
      if (!enabled(volt.t[i])) continue;
      const v = volt.v[i];
      if (v < 0.5) continue; // 0 V means "no reading", not a dead battery
      if (v < min) min = v;
      if (v < 8) below += Math.min((volt.t[i + 1] ?? volt.t[i] + 0.02) - volt.t[i], MAX_DT);
    }
    if (Number.isFinite(min)) {
      result.minimumVoltage = min;
      result.secondsBelow8Volts = below;
    }
  }

  // A power distribution board that never answered logs one flat 0 A sample.
  // Treat that as "no reading", not as a battery that drew nothing.
  let cur = series.current;
  if (cur && (cur.v.length < 10 || Math.max(...cur.v) <= 0)) {
    result.currentSignalDead = true;
    cur = null;
  }
  if (cur) {
    const check = inWindows(windows);
    let coulombs = 0;
    for (let i = 0; i < cur.t.length; i++) {
      if (!check(cur.t[i])) continue;
      coulombs += Math.max(cur.v[i], 0) * Math.min((cur.t[i + 1] ?? cur.t[i] + 0.02) - cur.t[i], MAX_DT);
    }
    result.ampHoursUsed = coulombs / 3600;
  }

  const brown = series.brownout;
  if (brown) {
    const check = inWindows(windows);
    let count = 0;
    let prev = 0;
    for (let i = 0; i < brown.t.length; i++) {
      if (check(brown.t[i]) && brown.v[i] && !prev) count++;
      prev = brown.v[i];
    }
    result.brownoutCount = count;
  }

  // Internal resistance: for every pair of back-to-back samples where current
  // jumps by 15+ A, R = -dV/dI. The median of those is the estimate. It also
  // includes wiring and breaker resistance, so compare batteries on the same
  // robot, not against a bench tester.
  if (volt && cur) {
    const check = inWindows(windows);
    const estimates = [];
    let vi = 0;
    const voltageAt = (t) => {
      while (vi + 1 < volt.t.length && volt.t[vi + 1] <= t) vi++;
      return Math.abs(volt.t[vi] - t) <= 0.03 ? volt.v[vi] : null;
    };
    let prev = null; // last usable { t, i, v }
    for (let i = 0; i < cur.t.length; i++) {
      const t = cur.t[i];
      const v = check(t) ? voltageAt(t) : null;
      if (v === null || v < 0.5) { prev = null; continue; }
      if (prev && t - prev.t <= 0.05) {
        const dI = cur.v[i] - prev.i;
        if (Math.abs(dI) >= minDeltaAmps) {
          const r = -(v - prev.v) / dI;
          if (r > 0 && r < 0.1) estimates.push(r);
        }
      }
      prev = { t, i: cur.v[i], v };
    }
    if (estimates.length >= 10) result.internalResistanceMilliohms = median(estimates) * 1000;
    result.resistanceSamples = estimates.length;
  }
  return result;
}

// "..._q23.wpilog" -> "Q23", "..._p3" -> "P3". Works for AdvantageKit and
// WPILib DataLogManager names. Falls back to the file's date.
function matchNameFromFile(file, mtime) {
  const base = path.basename(file).replace(/\.wpilog$/i, '');
  const m = base.match(/_(qm|sf|q|p|e|f)(\d+)$/i);
  if (m) {
    const kind = m[1].toLowerCase();
    return `${kind === 'qm' ? 'Q' : kind.toUpperCase()}${m[2]}`;
  }
  const d = mtime instanceof Date ? mtime : new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `Log ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function analyzeFile(file, signals = DEFAULT_SIGNALS, opts = {}) {
  const buf = fs.readFileSync(file);
  const { series, lastTime, names } = parseWpilog(buf, signals);
  return { metrics: computeMetrics(series, lastTime, opts), names, buf, series };
}

module.exports = { DEFAULT_SIGNALS, parseWpilog, computeMetrics, matchNameFromFile, analyzeFile, matchSignal };
