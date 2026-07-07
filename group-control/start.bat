@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title TrollVNC Group Control

echo ============================================
echo   TrollVNC Group Control - Launcher
echo ============================================
echo.

REM --- Find node.exe (try 3 locations) ---
set "NODE_EXE="
if exist "%PROGRAMFILES%\nodejs\node.exe" set "NODE_EXE=%PROGRAMFILES%\nodejs\node.exe"
if not defined NODE_EXE if exist "%LOCALAPPDATA%\Programs\node\node.exe" set "NODE_EXE=%LOCALAPPDATA%\Programs\node\node.exe"
if not defined NODE_EXE where node >nul 2>&1 && set "NODE_EXE=node"

if not defined NODE_EXE (
    echo [ERROR] Node.js not found!
    echo.
    echo Please install Node.js: https://nodejs.org ^(LTS version^)
    goto :end
)

echo Node: %NODE_EXE%
echo.

"%NODE_EXE%" launcher.js

:end
pause
