#!/bin/sh
# Walkaholic 鸿蒙版 一键构建 + 安装 + 启动
# 用法: ./build-install.sh
#
# 现在走仓库统一的脚本（支持本地自签名，无需华为账号）：
#   bash ../scripts/build-hap.sh --device
#
# 若要使用 DevEco 图形界面配好的华为账号正式签名，直接在 IDE 里 Run 即可。
set -e
exec bash "$(cd "$(dirname "$0")/.." && pwd)/scripts/build-hap.sh" --device
