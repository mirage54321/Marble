@echo off
setlocal

if not exist "%~dp0config.json" (
  echo Run start-collector.bat once first to set up your team and passcode.
  pause
  exit /b 1
)

set "startup=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "launcher=%~dp0start-background.vbs"
> "%startup%\Marble Collector.vbs" echo Set shell = CreateObject("WScript.Shell")
>> "%startup%\Marble Collector.vbs" echo shell.Run "wscript.exe ""%launcher%""", 0, False

echo Marble Collector will now start silently when this Windows account signs in.
echo It will show a battery picker whenever it finds a new robot log on a USB drive.
pause
