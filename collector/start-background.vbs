Option Explicit

Dim shell, files, folder, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = folder
command = "cmd.exe /c node marble-collector.js --dialog >> collector.log 2>&1"
shell.Run command, 0, False
