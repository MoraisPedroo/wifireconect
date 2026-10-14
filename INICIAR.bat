@echo off
title Mapanto - Tunel + Wifi
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0Mapanto.ps1"
