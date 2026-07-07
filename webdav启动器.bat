@echo off
chcp 65001 >nul
title MatisuXCS WebDAV 管理器
cd /d "%~dp0"

REM 检查 Python 是否可用
py -V >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Python，请先安装 Python
    echo 下载地址: https://www.python.org/downloads/
    pause
    exit /b 1
)

:menu
cls
echo ========================================
echo   MatisuXCS WebDAV 管理器
echo ========================================
echo.
echo   1. 启动 WebDAV 本地服务
echo   2. 停止 WebDAV 本地服务
echo   3. 打开浏览器（已启动时）
echo   0. 退出
echo.
echo ========================================
echo.

choice /c 1230 /n /m "请输入选项: "

if errorlevel 4 goto end
if errorlevel 3 goto open
if errorlevel 2 goto stop
if errorlevel 1 goto start

:start
cls
echo 正在检查端口 8899 ...
REM 先杀掉占用 8899 端口的旧进程
for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":8899 " ^| findstr "LISTENING"') do (
    echo 发现占用端口的进程 PID=%%a，正在关闭...
    taskkill /PID %%a /F >nul 2>&1
)
timeout /t 1 >nul

echo 正在启动 WebDAV 服务（端口 8899）...
start "WebDAV" cmd /k "py -m http.server 8899"
echo 服务已启动，等待 2 秒后打开浏览器...
timeout /t 2 >nul
start "" "http://localhost:8899/webdav_local.html"
echo.
echo 服务已在后台运行，按任意键返回菜单...
pause >nul
goto menu

:stop
cls
echo 正在停止 WebDAV 服务...
for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":8899 " ^| findstr "LISTENING"') do (
    echo 关闭进程 PID=%%a
    taskkill /PID %%a /F >nul 2>&1
)
echo WebDAV 服务已停止
timeout /t 1 >nul
goto menu

:open
start "" "http://localhost:8899/webdav_local.html"
goto menu

:end
cls
echo 正在停止 WebDAV 服务...
for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":8899 " ^| findstr "LISTENING"') do (
    echo 关闭进程 PID=%%a
    taskkill /PID %%a /F >nul 2>&1
)
echo 已退出
timeout /t 1 >nul
exit
