# Marble Collector

Marble Collector watches for new robot `.wpilog` files, calculates battery metrics, and uploads them to Marble's **Analyze battery match logs** tool. It uses Node.js 18 or newer and has no package-install step.

## One-time setup

1. Deploy the updated `backend/server.js` to Render.
2. On the pit laptop, double-click `start-collector.bat`.
3. On its first run, enter the Marble battery team number and passcode.
4. Keep the window open during the event.

The collector automatically searches USB drives for a `logs` folder. To also watch a Driver Station download folder, add its path to `watchFolders` in the generated `config.json`.

## Match workflow

1. Before the match, use Marble's existing **In use** button on the installed battery.
2. After the match, plug the robot's FAT32 log USB into the pit laptop, or download the log with Driver Station.
3. The collector analyzes the new log and asks which battery to assign. For the newest log, it suggests the one marked **In use**.

## Useful commands

```powershell
node marble-collector.js
node marble-collector.js --setup
node marble-collector.js --yes
node marble-collector.js --all
node marble-collector.js --analyze path\to\log.wpilog
node marble-collector.js --signals path\to\log.wpilog
```

If a metric is missing, use `--signals` on a real log and add the actual signal names under `signals` in `config.json`.

`config.json` stores the Marble passcode locally and is intentionally ignored by Git. The collector also keeps `collector-state.json` so it never uploads the same log twice; the backend independently rejects duplicate log hashes.
