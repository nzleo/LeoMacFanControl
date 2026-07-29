#!/bin/bash
#
# uninstall.sh —— 卸载守护进程，并把风扇归还系统自动控制。
# 用法：  sudo ./Scripts/uninstall.sh
#
set -uo pipefail

LABEL="com.leo.fancontrol.helper"
INSTALL_DIR="/Library/Application Support/LeoFanControl"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/LeoFanControl"
SOCKET="/var/run/com.leo.fancontrol.sock"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请用 sudo 运行：  sudo ./Scripts/uninstall.sh"
    exit 1
fi

echo "==> 停止并移除守护进程"
# 守护进程收到 SIGTERM 会自动把风扇归还系统自动控制
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl disable "system/$LABEL" 2>/dev/null || true

rm -f "$PLIST"
rm -rf "$INSTALL_DIR"
# 守护进程被 SIGKILL 时来不及自己清理，这里兜底删掉残留的 socket
rm -f "$SOCKET"

echo "==> 日志保留在 $LOG_DIR（如需可手动删除）"
echo "✅ 已卸载。风扇已交还 macOS 自动控制。"
