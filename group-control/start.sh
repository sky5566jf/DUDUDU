#!/bin/bash
# 群控管理台 - 一键启动脚本
# 启动顺序：中继服务器 → 电脑端网页

echo "========================================"
echo "  TrollVNC 群控管理台 - 启动脚本"
echo "========================================"

# 1. 启动中继服务器
echo ""
echo "[1/2] 启动中继服务器 (relay-server) ..."
cd "$(dirname "$0")/relay-server" || exit 1

if [ ! -d "node_modules" ]; then
  echo "  → 首次运行，正在安装依赖 (npm install) ..."
  npm install
fi

echo "  → 启动 relay-server (WS :8183 + HTTP :8080) ..."
node relay-server.js &
RELAY_PID=$!
echo "  → relay-server 已启动 (PID: $RELAY_PID)"

cd "$(dirname "$0")" || exit 1

# 2. 启动网页服务
echo ""
echo "[2/2] 启动群控网页服务 ..."
echo "  → 访问地址: http://localhost:7000/group_control.html"
echo "  → 按 Ctrl+C 停止所有服务"
echo "========================================"
echo ""

# 使用 Python 启动静态文件服务（自动处理 CORS）
python3 -m http.server 7000 2>/dev/null || python -m http.server 7000

# 清理
kill $RELAY_PID 2>/dev/null
echo ""
echo "所有服务已停止"
