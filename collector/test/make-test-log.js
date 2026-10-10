'use strict';

// Writes a synthetic AdvantageKit-style .wpilog with a known battery:
// open-circuit 12.6 V, 15 mOhm internal resistance, one brownout.
const fs = require('fs');

function uintBytes(value, len) {
  const out = Buffer.alloc(len);
  let v = value;
  for (let i = 0; i < len; i++) { out[i] = v % 256; v = Math.floor(v / 256); }
  return out;
}

function record(id, timeUs, payload) {
  const header = Buffer.concat([Buffer.from([(3 << 4) | (1 << 2) | 0]), uintBytes(id, 1), uintBytes(payload.length, 2), uintBytes(timeUs, 4)]);
  return Buffer.concat([header, payload]);
}

function str(s) {
  const b = Buffer.from(s, 'utf8');
  return Buffer.concat([uintBytes(b.length, 4), b]);
}

function startRecord(id, name, type) {
  const payload = Buffer.concat([Buffer.from([0]), uintBytes(id, 4), str(name), str(type), str('')]);
  return record(0, 0, payload);
}

function dbl(x) { const b = Buffer.alloc(8); b.writeDoubleLE(x); return b; }

function makeLog(file, opts = {}) {
  const R = opts.resistance ?? 0.015;
  const names = opts.names ?? { v: '/RealOutputs/Battery/VoltageVolts', i: '/RealOutputs/Battery/TotalCurrentAmps', b: '/RealOutputs/Battery/BrownedOut' };
  const parts = [Buffer.concat([Buffer.from('WPILOG', 'latin1'), uintBytes(0x0100, 2), uintBytes(0, 4)])];
  parts.push(startRecord(1, names.v, 'double'));
  parts.push(startRecord(2, names.i, 'double'));
  parts.push(startRecord(3, names.b, 'boolean'));
  parts.push(startRecord(4, '/DriverStation/Enabled', 'boolean'));
  parts.push(startRecord(5, '/RealOutputs/Unrelated/Thing', 'double'));

  const dt = 0.02;
  const total = 160;            // 160 s of log: 20 s disabled, 150 s... enabled from 10 s to 160 s
  const enabledFrom = 10;
  let expectedAmpSec = 0;
  let brownedPrev = false;
  for (let k = 0; k * dt <= total; k++) {
    const t = k * dt;
    const us = Math.round(t * 1e6);
    const enabled = t >= enabledFrom;
    if (k === Math.round(enabledFrom / dt)) parts.push(record(4, us, Buffer.from([1])));
    if (k === 0) parts.push(record(4, us, Buffer.from([0])));
    // current: base 20 A, bursts to 120 A every few seconds (steps), pit idle ~2 A before enable
    const burst = Math.floor(t * 2) % 7 === 0 ? 100 : 0;
    const wobble = 5 * Math.sin(t * 3);
    const current = enabled ? 20 + burst + wobble : 2;
    let volts = 12.6 - R * current;
    const browned = enabled && t > 100 && t < 100.5;
    if (browned) volts = 6.2;
    if (enabled) expectedAmpSec += current * dt;
    parts.push(record(1, us, dbl(volts)));
    parts.push(record(2, us, dbl(current)));
    parts.push(record(5, us, dbl(1.5)));
    if (browned !== brownedPrev) { parts.push(record(3, us, Buffer.from([browned ? 1 : 0]))); brownedPrev = browned; }
  }
  fs.writeFileSync(file, Buffer.concat(parts));
  return { expectedAmpHours: expectedAmpSec / 3600, resistanceMilliohms: R * 1000 };
}

module.exports = { makeLog };
if (require.main === module) {
  const info = makeLog(process.argv[2] || 'test_q23.wpilog');
  console.log(info);
}
