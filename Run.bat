@echo off
rem Starts WinQuick as administrator. The script path is passed through an
rem environment variable so folders with apostrophes or spaces work.
set "WQ_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',('\"'+$env:WQ_DIR+'WinQuick.ps1\"'))"
