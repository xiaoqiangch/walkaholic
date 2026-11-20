#!/usr/bin/env bash
# 把 DevEco Studio 的命令行工具链复制到 ~/DevTools/deveco，让 CLI 构建可用。
#
# 为什么必须复制：
#   macOS 26 的 App Management 保护会拦截「在 .app 包内直接执行 Mach-O」。
#   实测在 /Applications/DevEco-Studio.app/Contents 下执行 node / java / hdc，
#   进程会卡在 dyld 的 _dyld_start 永不返回（sample 可见）。
#   同样的二进制复制到普通目录后立刻正常。
#   IDE 图形界面本身不受影响，仍从 /Applications 启动。
#
# 用法： bash scripts/setup-deveco-cli.sh [IDE 路径]
set -euo pipefail

IDE="${1:-/Applications/DevEco-Studio.app}"
IDE="${IDE%/}"
[ -d "$IDE/Contents" ] || { echo "找不到 DevEco Studio: $IDE"; exit 1; }

DEST="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
echo "源:   $IDE/Contents"
echo "目标: $DEST"

mkdir -p "$DEST"
for part in tools sdk jbr; do
  [ -d "$IDE/Contents/$part" ] || { echo "缺少 $part"; exit 1; }
  echo "  复制 $part …"
  rm -rf "$DEST/$part"
  ditto "$IDE/Contents/$part" "$DEST/$part"
done

# 去掉隔离属性，避免首次执行被 Gatekeeper 拦
for f in "$DEST"/tools/node/bin/node "$DEST"/jbr/Contents/Home/bin/java \
         "$DEST"/sdk/default/openharmony/toolchains/hdc; do
  xattr -c "$f" 2>/dev/null || true
done

echo
echo "验证："
"$DEST/tools/node/bin/node" -v        | sed 's/^/  node   /'
"$DEST/tools/ohpm/bin/ohpm" -v 2>&1 | head -1 | sed 's/^/  ohpm   /'
"$DEST/sdk/default/openharmony/toolchains/hdc" -v 2>&1 | head -1 | sed 's/^/  hdc    /'
"$DEST/jbr/Contents/Home/bin/java" -version 2>&1 | head -1 | sed 's/^/  java   /'

echo
echo "完成。工程内 ./hvigorw 会自动使用 $DEST"
