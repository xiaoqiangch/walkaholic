#!/usr/bin/env bash
# 在已启动的模拟器/真机上巡检界面并截图到 harmony/docs/screenshots/
#
# 用法: bash scripts/capture-screens.sh
# 前提: 模拟器已启动、已安装应用、定位开关已打开
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DEVECO="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
HDC="$HOME_DEVECO/sdk/default/openharmony/toolchains/hdc"
OUT="$ROOT/harmony/docs/screenshots"
BUNDLE="com.walkaholic.harmony"
mkdir -p "$OUT"

shot() {
  local name="$1"
  "$HDC" shell "snapshot_display -f /data/local/tmp/cap.jpeg" >/dev/null 2>&1
  "$HDC" file recv /data/local/tmp/cap.jpeg /tmp/cap.jpeg >/dev/null 2>&1
  sips -s format png /tmp/cap.jpeg --out "$OUT/$name.png" >/dev/null 2>&1
  echo "  ✅ $name.png"
}

tap_text() {
  # 用 uitest 布局按文本找控件中心点并点击；找不到时上滑一次再找（面板可滚动）
  local target="$1" tries="${2:-3}"
  local i=0
  while [ "$i" -lt "$tries" ]; do
    "$HDC" shell "uitest dumpLayout -p /data/local/tmp/c.json" >/dev/null 2>&1
    "$HDC" file recv /data/local/tmp/c.json /tmp/c.json >/dev/null 2>&1
    if python3 - "$target" "$HDC" <<'PY'
import json, sys, subprocess
target, hdc = sys.argv[1], sys.argv[2]
d = json.load(open('/tmp/c.json'))
hit = []
def walk(n):
    a = n.get('attributes', {})
    if a.get('text') == target and not hit:
        hit.append(a.get('bounds', ''))
    for c in n.get('children', []):
        walk(c)
walk(d)
if not hit:
    sys.exit(1)
x1,y1,x2,y2 = [int(v) for v in hit[0].replace('][', ',').replace('[','').replace(']','').split(',')]
subprocess.run([hdc, 'shell', 'uinput -T -c %d %d' % ((x1+x2)//2, (y1+y2)//2)],
               capture_output=True)
print('  tap:', target)
PY
    then return 0; fi
    "$HDC" shell "uinput -T -m 640 2300 640 900 400" >/dev/null 2>&1
    sleep 1
    i=$((i+1))
  done
  echo "  ⚠️ 未找到控件: $target"
  return 1
}

echo "═══ 启动应用 ═══"
"$HDC" shell "aa start -a EntryAbility -b $BUNDLE" >/dev/null 2>&1
sleep 4
shot 01-home

echo "═══ 抽盒设置面板 ═══"
tap_text "开一个盲盒"; sleep 3
shot 02-setup

echo "═══ 使命/旅程 ═══"
tap_text "摇一个盲盒"; sleep 14
shot 03-journey

echo "═══ 揭晓 ═══"
tap_text "走累了？直接揭晓"; sleep 4
shot 04-reveal
tap_text "完成" 2>/dev/null; sleep 1

echo "═══ 四个 Tab ═══"
"$HDC" shell "uinput -T -c 1000 200" >/dev/null 2>&1; sleep 2
tap_text "图鉴"; sleep 3; shot 05-cards
tap_text "圈子"; sleep 3; shot 06-social
tap_text "我的"; sleep 3; shot 07-profile
tap_text "今日"; sleep 2

echo
echo "截图目录: $OUT"
