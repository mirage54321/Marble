'use strict';
const { app, BrowserWindow, Tray, Menu, ipcMain, dialog, nativeImage, shell } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
let window; let tray; let collector;
const collectorAssets = () => app.isPackaged ? path.join(process.resourcesPath, 'collector') : path.join(__dirname, '..', 'collector');
const dataDir = () => path.join(app.getPath('userData'), 'collector');
const configPath = () => path.join(dataDir(), 'config.json');
const defaults = { apiBase: 'https://ridgeboticsapp.onrender.com', teamNumber: '', passcode: '', watchFolders: [], scanDrives: true, driveSubfolder: 'logs', pollSeconds: 3, maxAgeHours: 6, minEnabledSeconds: 15, useWindowsDialog: true, logTimestampTimeZone: 'ask', signals: {} };
function readConfig() { try { return { ...defaults, ...JSON.parse(fs.readFileSync(configPath(), 'utf8')) }; } catch { return { ...defaults }; } }
function writeConfig(value) { fs.mkdirSync(dataDir(), { recursive: true }); fs.writeFileSync(configPath(), JSON.stringify({ ...defaults, ...value }, null, 2)); }
function configured() { const config = readConfig(); return Boolean(config.teamNumber && config.passcode); }
function emit(channel, value) { if (window && !window.isDestroyed()) window.webContents.send(channel, value); }
function emitLog(text, stream = 'out') { String(text).split(/\r?\n/).filter(Boolean).forEach((line) => emit('collector-log', { line, stream })); }
function updateTray(status = 'Watching for robot logs') { if (tray) tray.setToolTip(`Marble Collector — ${status}`); emit('collector-status', { running: Boolean(collector), status }); }
function startCollector() {
  if (collector) return;
  if (!configured()) { updateTray('Setup needed'); emitLog('Setup needed: enter your team number and passcode, then click Save & start.'); return; }
  const env = { ...process.env, MARBLE_COLLECTOR_DIR: dataDir() }; if (app.isPackaged) env.ELECTRON_RUN_AS_NODE = '1';
  collector = spawn(process.execPath, [path.join(collectorAssets(), 'marble-collector.js'), '--dialog'], { cwd: collectorAssets(), env, windowsHide: true });
  collector.stdout.on('data', (data) => emitLog(data)); collector.stderr.on('data', (data) => emitLog(data, 'error'));
  collector.on('error', (error) => emitLog(`Could not start collector: ${error.message}`, 'error'));
  collector.on('close', (code) => { collector = null; emitLog(`Collector stopped${code === 0 ? '.' : ` (code ${code}).`}`, code === 0 ? 'out' : 'error'); updateTray('Stopped'); });
  updateTray(); emitLog('Desktop companion started. Plug in the robot log USB when ready.');
}
function stopCollector() { if (collector) collector.kill(); }
function showWindow() { if (!window) createWindow(); window.show(); window.focus(); }
function icon() { const svg = encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" rx="13" fill="#546e7a"/><path d="M24 12h16v8h5v14h-5v8H24v-8h-5V20h5z" fill="white"/></svg>'); return nativeImage.createFromDataURL(`data:image/svg+xml,${svg}`).resize({ width: 16, height: 16 }); }
function createTray() { tray = new Tray(icon()); tray.on('double-click', showWindow); tray.setContextMenu(Menu.buildFromTemplate([{ label: 'Open Marble Collector', click: showWindow }, { type: 'separator' }, { label: 'Start watching', click: startCollector }, { label: 'Stop watching', click: stopCollector }, { label: 'Open data folder', click: () => shell.openPath(dataDir()) }, { type: 'separator' }, { label: 'Quit', click: () => { app.isQuitting = true; app.quit(); } }])); updateTray(); }
function createWindow() { window = new BrowserWindow({ width: 720, height: 650, minWidth: 620, minHeight: 550, title: 'Marble Collector', show: false, webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false } }); window.loadFile(path.join(__dirname, 'renderer', 'index.html')); window.on('close', (event) => { if (!app.isQuitting) { event.preventDefault(); window.hide(); } }); }
ipcMain.handle('config:get', () => ({ config: readConfig(), autoStart: app.getLoginItemSettings().openAtLogin }));
ipcMain.handle('config:save', (_event, value) => { const current = readConfig(); writeConfig({ ...current, apiBase: String(value.apiBase || defaults.apiBase).trim(), teamNumber: String(value.teamNumber || '').trim(), passcode: String(value.passcode || '').trim(), watchFolders: value.watchFolder ? [String(value.watchFolder).trim()] : [], logTimestampTimeZone: String(value.logTimestampTimeZone || 'ask') }); app.setLoginItemSettings({ openAtLogin: Boolean(value.autoStart) }); stopCollector(); setTimeout(startCollector, 350); return { ok: true }; });
ipcMain.handle('collector:start', startCollector); ipcMain.handle('collector:stop', stopCollector); ipcMain.handle('collector:open-folder', () => shell.openPath(dataDir()));
ipcMain.handle('folder:choose', async () => { const result = await dialog.showOpenDialog(window, { properties: ['openDirectory'] }); return result.canceled ? '' : result.filePaths[0]; });
app.whenReady().then(() => { createWindow(); createTray(); startCollector(); }); app.on('window-all-closed', (event) => event.preventDefault()); app.on('before-quit', () => { app.isQuitting = true; stopCollector(); });
