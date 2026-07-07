#!/bin/bash
# TrollVNC API 测试脚本
# 使用方法: ./test_api.sh [host] [port]

TVNC_HOST="${1:-127.0.0.1}"
TVNC_PORT="${2:-5555}"

echo "================================"
echo "TrollVNC API 测试脚本"
echo "服务器: $TVNC_HOST:$TVNC_PORT"
echo "================================"
echo ""

# 检查 nc 命令
if ! command -v nc &> /dev/null; then
    echo "错误: 需要安装 nc (netcat)"
    exit 1
fi

# 发送命令函数
send_cmd() {
    echo "$1" | nc -w 5 "$TVNC_HOST" "$TVNC_PORT" 2>/dev/null
}

# 测试基本连接
echo "[测试 1] 基本连接测试 (count 命令)"
response=$(send_cmd "count")
if [ -n "$response" ]; then
    echo "✓ 连接成功，客户端数量: $response"
else
    echo "✗ 连接失败，请检查 TrollVNC 是否运行以及控制套接字端口是否正确"
    exit 1
fi
echo ""

# 测试 list 命令
echo "[测试 2] 客户端列表 (list 命令)"
response=$(send_cmd "list")
if [ -n "$response" ]; then
    echo "✓ 响应:"
    echo "$response"
else
    echo "✗ 无响应"
fi
echo ""

# 测试截图 - base64 输出
echo "[测试 3] 截图测试 - base64 输出"
echo "发送: screenshot png"
response=$(send_cmd "screenshot png")
if [[ "$response" == OK* ]]; then
    echo "✓ 截图成功"
    # 提取第一行
    first_line=$(echo "$response" | head -1)
    echo "  响应: $first_line"
    # 计算 base64 数据长度
    base64_lines=$(echo "$response" | wc -l)
    if [ "$base64_lines" -gt 1 ]; then
        data_len=$(echo "$response" | tail -n +2 | wc -c)
        echo "  图片数据长度: $data64 字节"
    fi
else
    echo "✗ 截图失败: $response"
fi
echo ""

# 测试截图 - 保存到文件
echo "[测试 4] 截图测试 - 保存到文件"
test_path="/var/mobile/trollvnc_test_screenshot.png"
echo "发送: screenshot png $test_path"
response=$(send_cmd "screenshot png $test_path")
if [[ "$response" == OK* ]]; then
    echo "✓ $response"
    # 检查文件是否存在
    if [ -f "$test_path" ]; then
        file_size=$(stat -f%z "$test_path" 2>/dev/null || stat -c%s "$test_path" 2>/dev/null)
        echo "  文件已保存，大小: $file_size 字节"
        # 清理测试文件
        rm -f "$test_path"
        echo "  测试文件已清理"
    fi
else
    echo "✗ 截图失败: $response"
fi
echo ""

# 测试文件写入
echo "[测试 5] 文件写入测试"
test_content="Hello TrollVNC! 你好，中文测试！"
test_path="/var/mobile/trollvnc_test_file.txt"
encoded_content=$(echo -n "$test_content" | base64)
echo "发送: writefile $test_path"
printf "writefile %s\n%s\n" "$test_path" "$encoded_content" | nc -w 5 "$TVNC_HOST" "$TVNC_PORT" 2>/dev/null
response=$(printf "writefile %s\n%s\n" "$test_path" "$encoded_content" | nc -w 5 "$TVNC_HOST" "$TVNC_PORT" 2>/dev/null)
if [[ "$response" == *OK* ]]; then
    echo "✓ 文件写入成功"
    if [ -f "$test_path" ]; then
        read_content=$(cat "$test_path")
        if [ "$read_content" = "$test_content" ]; then
            echo "  内容验证成功"
        else
            echo "  内容验证失败"
            echo "  期望: $test_content"
            echo "  实际: $read_content"
        fi
        rm -f "$test_path"
        echo "  测试文件已清理"
    fi
else
    echo "✗ 文件写入失败: $response"
fi
echo ""

# 测试剪贴板
echo "[测试 6] 剪贴板测试"
test_text="TrollVNC 中文测试 $(date)"
encoded_text=$(echo -n "$test_text" | base64)
echo "发送: clipboard <base64-encoded-text>"
response=$(send_cmd "clipboard $encoded_text")
if [[ "$response" == *OK* ]]; then
    echo "✓ 剪贴板设置成功"
    echo "  设置的内容: $test_text"
else
    echo "✗ 剪贴板设置失败: $response"
fi
echo ""

# 测试文件追加
echo "[测试 7] 文件追加测试"
test_path="/var/mobile/trollvnc_test_append.txt"
echo "Line 1" > "$test_path"
append_content=" - Appended 中文追加"
encoded_append=$(echo -n "$append_content" | base64)
response=$(printf "writefile %s append\n%s\n" "$test_path" "$encoded_append" | nc -w 5 "$TVNC_HOST" "$TVNC_PORT" 2>/dev/null)
if [[ "$response" == *OK* ]]; then
    echo "✓ 文件追加成功"
    final_content=$(cat "$test_path")
    echo "  最终内容: $final_content"
else
    echo "✗ 文件追加失败: $response"
fi
rm -f "$test_path"
echo ""

echo "================================"
echo "测试完成"
echo "================================"
