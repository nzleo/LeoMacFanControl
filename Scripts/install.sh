#!/bin/bash
#
# install.sh —— 安装 root 守护进程 fanhelperd 并注册为 LaunchDaemon。
#
# 用法（两步）：
#   1) 先在项目根目录以普通用户身份编译：   swift build -c release --product fanhelperd
#   2) 再以 root 安装：                      sudo ./Scripts/install.sh
#
# 本脚本不联网，只做：拷贝二进制 + 写 LaunchDaemon + 启动。
#
set -euo pipefail

LABEL="com.leo.fancontrol.helper"
INSTALL_DIR="/Library/Application Support/LeoFanControl"
BIN_DST="$INSTALL_DIR/fanhelperd"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/LeoFanControl"

# 定位项目根目录（脚本所在目录的上一级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="$ROOT_DIR/.build/release/fanhelperd"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请用 sudo 运行：  sudo ./Scripts/install.sh"
    exit 1
fi

if [[ ! -f "$SRC_BIN" ]]; then
    echo "错误：找不到已编译的守护进程：$SRC_BIN"
    echo "请先在项目根目录运行：  swift build -c release --product fanhelperd"
    exit 1
fi

echo "==> 安装二进制到 $BIN_DST"
mkdir -p "$INSTALL_DIR"
cp "$SRC_BIN" "$BIN_DST"
chown root:wheel "$BIN_DST"
chmod 755 "$BIN_DST"

mkdir -p "$LOG_DIR"
chown root:wheel "$LOG_DIR"

echo "==> 写入 LaunchDaemon 配置 $PLIST"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/fanhelperd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/fanhelperd.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "==> 重新加载守护进程"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"

echo ""
echo "✅ 安装完成。守护进程已随系统启动，并会开机自启。"
echo "   查看日志：  sudo tail -f $LOG_DIR/fanhelperd.log"
echo "   卸载：      sudo ./Scripts/uninstall.sh"
