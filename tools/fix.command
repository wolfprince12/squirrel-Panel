#!/bin/bash
# 鼠须管控制面板 一键解除 Gatekeeper 隔离
# 用法：把「Squirrel Panel.app」拖进「应用程序」后，双击本脚本，输入开机密码即可。
clear
printf '\e[0;40;97m'
echo "========================================="
echo "       鼠须管控制面板 解除隔离工具"
echo "========================================="
echo ""
echo "本软件为 ad-hoc 签名、未经 Apple 公证，"
echo "首次打开会被系统拦截。本工具解除该拦截。"
echo "（不会关闭系统 Gatekeeper，不影响其他软件安全）"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DMG="$SCRIPT_DIR/Squirrel Panel.app"
APP_APPS="/Applications/Squirrel Panel.app"

clean() {
  local p="$1"
  echo "→ 正在解除隔离：$p"
  sudo xattr -rd com.apple.quarantine "$p" 2>/dev/null
  sudo xattr -cr "$p" 2>/dev/null
  sudo chmod -R +x "$p" 2>/dev/null
  echo "  ✓ 完成"
}

# 1) 镜像内（与本脚本同目录）的 Squirrel Panel.app —— 无论你先拖还是后拖都能解
if [ -d "$APP_DMG" ]; then
  clean "$APP_DMG"
fi

# 2) 你真正运行的：/Applications/Squirrel Panel.app（sudo 才能改系统目录下的隔离属性）
if [ -d "$APP_APPS" ]; then
  clean "$APP_APPS"
  echo ""
  echo "✅ 处理完毕。现在可以从「启动台 / 应用程序」直接打开 鼠须管控制面板 了。"
else
  echo ""
  echo "⚠️  没在「应用程序」里找到 Squirrel Panel.app。"
  echo "    请先把 Squirrel Panel.app 拖进「应用程序」文件夹，再运行本脚本。"
fi

echo ""
read -p "按回车键关闭窗口..." _
