@echo off
chcp 65001 >nul 2>&1
title TrollVNC 群控管理台 [端口 9194]

cd /d "%~dp0"

echo.
echo   TrollVNC 群控管理台
echo   http://localhost:9194/group_control.html
echo.
echo   按 Ctrl+C 停止服务
echo.

python http_server.py
