'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('collector', {
  getConfig: () => ipcRenderer.invoke('config:get'), saveConfig: (config) => ipcRenderer.invoke('config:save', config), start: () => ipcRenderer.invoke('collector:start'), stop: () => ipcRenderer.invoke('collector:stop'), openFolder: () => ipcRenderer.invoke('collector:open-folder'), chooseFolder: () => ipcRenderer.invoke('folder:choose'),
  onLog: (callback) => ipcRenderer.on('collector-log', (_event, value) => callback(value)), onStatus: (callback) => ipcRenderer.on('collector-status', (_event, value) => callback(value)),
});
