# Marble Collector

Watches for new `.wpilog` files, calculates battery metrics, and uploads them to
the **Battery Match Logs** tool in Marble. No dependencies, just Node 18+.

## Setup (once)
1. Deploy the patched `server.js` to Render (it adds duplicate protection and the `wpilog` source).
2. Double-click `start-collector.bat`. First run asks for team number and passcode.
3. Leave the window open at the pit.

## At an event
1. Before the match, tap **In use** on the battery in Marble (same as today).
2. After the match, plug the robot's log USB into the laptop.
3. The collector finds `<drive>:\logs\*.wpilog`, shows the numbers, and asks:
   `Assign Q23 to B4? [Enter = yes, type another label, s = skip]`
   Press Enter. Done.

It also watches any folder in `watchFolders` (for example where Driver Station's
"Upload WPILogs" saves files).

## What it handles
- Waits until a file has finished copying.
- Ignores pit idle time: only seconds where the robot was **enabled** count.
- Never imports the same log twice (hash on the laptop, and again on the server).
- Offline? Results queue in `collector-state.json` and upload when Marble is reachable.
- Logs older than `maxAgeHours` are ignored (`--all` to import anyway). Tiny pit tests are skipped.
- Only the newest log gets the "In use" suggestion. Older logs in the same batch ask you.

## Commands
```
node marble-collector.js                     run
node marble-collector.js --setup             redo setup
node marble-collector.js --yes               no prompts; assign newest log to the In-use battery
node marble-collector.js --all               include old logs
node marble-collector.js --analyze file.wpilog   print metrics only
node marble-collector.js --signals file.wpilog   list every signal name in a log
```

## If metrics show "-" or "missing signals"
Signal names differ between setups. Run `--signals` on a real log, find the names for
battery voltage, total current and brownout, and put them under `signals` in `config.json`
(see `config.example.json`). Matching ignores case and leading slashes, and also matches
a trailing part of the name (`Battery/VoltageVolts` matches `/RealOutputs/Battery/VoltageVolts`).

## How the numbers are calculated
- **Min voltage / time below 8 V**: enabled periods only; 0 V samples are treated as "no reading".
- **Amp-hours**: current integrated over time while enabled.
- **Brownouts**: count of `BrownedOut` going false to true.
- **Internal resistance**: median of -dV/dI over back-to-back samples where current jumps 15+ A
  (needs 10+ such jumps). This includes wiring and breaker resistance, so compare batteries
  on the same robot with the same setup, not against a bench tester.

## Notes
- `config.json` stores your passcode in plain text on the laptop.
- `node test/mock-server.js` plus `test/make-test-log.js` let you try everything without a robot.