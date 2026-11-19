#!/usr/bin/env bash
# 鸿蒙模拟器：创建 / 启动 / 装应用 / 截图
#
# 用法:
#   bash scripts/emulator.sh install-image   # 下载 phone 系统镜像（HarmonyOS 26）
#   bash scripts/emulator.sh create          # 创建一个 phone 实例
#   bash scripts/emulator.sh start           # 启动（GUI）
#   bash scripts/emulator.sh stop
#   bash scripts/emulator.sh list
#   bash scripts/emulator.sh run             # 构建 + 安装 + 启动应用
#   bash scripts/emulator.sh shot <文件名>    # 截图到 docs/screenshots/
#
# 说明：镜像与实例都放在 ~/.deveco/emulator，不写进仓库。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DEVECO="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
EMU="$HOME_DEVECO/tools/emulator/Emulator"
HDC="$HOME_DEVECO/sdk/default/openharmony/toolchains/hdc"
IMAGE_ROOT="${HARMONY_IMAGE_ROOT:-$HOME/.deveco/emulator}"
INSTANCE_ROOT="${HARMONY_INSTANCE_ROOT:-$HOME/.deveco/emulator/instances}"
DEVICE_TYPE="${HARMONY_DEVICE_TYPE:-phone}"
OS_VERSION="${HARMONY_OS_VERSION:-HarmonyOS 7.0.0(26.0.0)}"
INSTANCE_NAME="${HARMONY_INSTANCE_NAME:-walkaholic}"
BUNDLE="com.walkaholic.harmony"
SCREENSHOT_DIR="$ROOT/harmony/docs/screenshots"

[ -x "$EMU" ] || { echo "缺少模拟器（先跑 scripts/setup-deveco-cli.sh）"; exit 1; }

cmd="${1:-help}"

case "$cmd" in
  install-image)
    echo "下载镜像: $DEVICE_TYPE / $OS_VERSION → $IMAGE_ROOT"
    "$EMU" -install -deviceType "$DEVICE_TYPE" -osVersion "$OS_VERSION" -imageRoot "$IMAGE_ROOT"
    ;;

  create)
    echo "创建实例: $INSTANCE_NAME ($DEVICE_TYPE)"
    "$EMU" -create "$INSTANCE_NAME" -deviceType "$DEVICE_TYPE" -osVersion "$OS_VERSION" \
      -imageRoot "$IMAGE_ROOT" -instancePath "$INSTANCE_ROOT"
    ;;

  start)
    echo "启动: $INSTANCE_NAME"
    "$EMU" -start "$INSTANCE_NAME" -instancePath "$INSTANCE_ROOT" -imageRoot "$IMAGE_ROOT"
    ;;

  stop)
    "$EMU" -stop "$INSTANCE_NAME" -instancePath "$INSTANCE_ROOT"
    ;;

  list)
    "$EMU" -list -details -instancePath "$INSTANCE_ROOT"
    "$HDC" list targets
    ;;

  run)
    bash "$ROOT/scripts/build-hap.sh"
    HAP="$ROOT/harmony/entry/build/default/outputs/default/entry-default-signed.hap"
    [ -f "$HAP" ] || { echo "未找到签名包"; exit 1; }
    echo "安装到设备…"
    "$HDC" install -r "$HAP"
    "$HDC" shell "aa start -a EntryAbility -b $BUNDLE"
    ;;

  shot)
    mkdir -p "$SCREENSHOT_DIR"
    name="${2:-screen-$(date +%H%M%S)}"
    out="$SCREENSHOT_DIR/$name.png"
    "$HDC" shell "snapshot_display -f /data/local/tmp/$name.jpeg"
    "$HDC" file recv "/data/local/tmp/$name.jpeg" "$out" >/dev/null 2>&1 || \
      "$HDC" shell "snapshot_display -f /data/local/tmp/$name.png"
    echo "截图: $out"
    ;;

  *)
    sed -n '2,20p' "$0"
    ;;
esac
