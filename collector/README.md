# Marble Collector

Marble Collector watches for new robot `.wpilog` files, calculates battery metrics, and uploads them to Marble's **Analyze battery match logs** tool. It uses Node.js 18 or newer and has no package-install step.

## One-time setup

1. Deploy the updated `backend/server.js` to Render.
2. On the pit laptop, double-click `start-collector.bat`.
3. On its first run, enter the Marble battery team number and passcode.
4. Double-click `install-autostart.bat` once. The collector will then start silently whenever this Windows account signs in.

The collector automatically searches USB drives for a `logs` folder. To also watch a Driver Station download folder, add its path to `watchFolders` in the generated `config.json`.

Windows does not allow a USB drive to launch an app by itself. The background collector is the reliable equivalent: it is already watching when you plug in the log USB, then opens a **Marble Collector** popup asking which battery was in the robot. The battery currently marked **In use** is filled in as the suggestion; replace it if needed, or cancel to skip that log.

## Match workflow

1. Before the match, use Marble's existing **In use** button on the installed battery.
2. After the match, plug the robot's FAT32 log USB into the pit laptop, or download the log with Driver Station.
3. The collector analyzes the new log and opens a popup. Confirm the suggested battery or type the actual battery label. For the newest log, it suggests the one marked **In use**.

When several new logs are found, Marble asks about them oldest first and shows each robot-enabled time range. Type `?` in the popup when you do not know the battery. The log is safely uploaded as **Needs battery assignment** and can be assigned later from Marble's **Battery Match Logs** screen.

### Correcting displayed log times

Battery measurements do not depend on the clock, but the displayed enabled-time range does. On the next collector start, a Windows dropdown asks what time zone the robot log timestamps use, then remembers the answer in `config.json`. It includes UTC plus Pacific, Mountain, Arizona, Central, Eastern, Alaska, Hawaii, UK, and Central European time. Daylight saving is calculated from the log's date.

For an immediate hidden start without signing out, double-click `start-background.vbs`. If something seems wrong, read `collector.log` in this folder.

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
