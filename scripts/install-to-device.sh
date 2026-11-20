#!/usr/bin/env bash
# 把步迷安装到已连接的 iPhone 真机。
#
# 前提（一次性）：
#   1. Xcode → Settings → Accounts 登录 Apple ID（免费个人账号即可，7 天有效）
#   2. iPhone 用「数据线」连接（不是充电线），解锁并点「信任」
#   3. 可选：export DEVELOPMENT_TEAM=XXXXXXXXXX（不设则用 Xcode 里选的默认 Team）
#
# 用法：
#   scripts/install-to-device.sh            # 自动检测唯一真机
#   scripts/install-to-device.sh <UDID>     # 指定设备
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/apple"

echo "== 0) 检查签名身份 =="
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "valid identities found" )
VALID=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "^\s+[0-9]+\)" | wc -l | tr -d ' ')
if [ "$VALID" = "0" ]; then
  cat <<'MSG'
❌ 这台 Mac 上还没有任何可用的代码签名身份，装不了真机。

一次性准备（约 3 分钟）：
  1. 打开 Xcode → Settings（⌘,）→ Accounts → 左下角 + → 用 Apple ID 登录
     （免费个人 Apple ID 就够，签名 7 天过期，过期重跑本脚本即可）
  2. 选中刚登录的账号 → Manage Certificates… → 左下角 + → Apple Development
  3. 回到工程的 Signing & Capabilities，Team 选这个账号（Personal Team）

之后再跑本脚本。
MSG
  exit 1
fi
echo "✅ 找到 $VALID 个签名身份"

echo "== 1) 检测已连接的真机（不含模拟器）=="
xcrun devicectl list devices --json-output /tmp/wa-devices.json >/dev/null 2>&1
python3 - <<'PY'
import json, sys
try:
    d = json.load(open('/tmp/wa-devices.json'))
except Exception:
    print("❌ 无法读取设备列表"); sys.exit(1)
rows = []
for dev in d.get('result', {}).get('devices', []):
    # reality 在 hardwareProperties 里，不在顶层（旧脚本判断错了，永远匹配不到真机）
    reality = str(dev.get('hardwareProperties', {}).get('reality', '')).lower()
    if reality != 'physical':
        continue
    props = dev.get('deviceProperties', {})
    conn = dev.get('connectionProperties', {})
    hw = dev.get('hardwareProperties', {})
    # 真机的 identifier 是 CoreDevice 内部 UUID，xcodebuild / devicectl 要的是 hw.udid
    udid = hw.get('udid') or dev.get('identifier')
    rows.append((
        props.get('name') or dev.get('name'),
        udid,
        conn.get('tunnelState'),
        props.get('osVersionNumber'),
        props.get('developerModeStatus'),
    ))
if not rows:
    print("❌ 没有检测到物理 iPhone。请检查：数据线（非充电线）、解锁、点『信任』。")
    sys.exit(1)
connected = False
usb_visible = False
for name, ident, tunnel, osv, devmode in rows:
    ok = tunnel == "connected"
    connected = connected or ok
    flag = "✅" if ok else "⚠️"
    print(f"{flag} {name} · iOS {osv} · 隧道={tunnel} · 开发者模式={devmode} · {ident}")
    if devmode != "enabled":
        print("   ⚠️ 开发者模式未开启：手机 设置 → 隐私与安全性 → 开发者模式 → 打开并重启")
    if not ok:
        print("   ⚠️ tunnelState 未显示 connected（CoreDevice 该字段常滞后，先看 USB 是否可见）")
print()
print("   USB 树里的 Apple 设备：")
PY
[ $? -ne 0 ] && exit 1

# USB 可见性由 shell 判断（python 读不到 ioreg）。
# 注意：CoreDevice 的 tunnelState 常年显示 disconnected，即使手机可用；
# 真正的判据是手机有没有出现在 USB 设备树里。
# iPhone 重新插拔/解锁时会短暂从 USB 树里消失，因此重试几次再判定。
# 注意：脚本开了 pipefail，ioreg 在某些情况下返回非 0 会让整条管道"失败"，
# 所以这里用 `|| true` 把 ioreg 的退出码吃掉，只看 grep 的结果。
USB_OK=0
for _try in 1 2 3 4 5; do
  if { ioreg -r -c IOUSBHostDevice -w0 2>/dev/null || true; } | grep -q '"USB Product Name" = "iPhone"'; then
    USB_OK=1
    break
  fi
  sleep 2
done
if [ "$USB_OK" = "1" ]; then
  echo "     ✅ iPhone（USB 已枚举）"
  TUNNEL_STATE=connected
else
  echo "     ❌ 没有 iPhone（可能只是充电线 / 需重插 / 需点信任）"
  TUNNEL_STATE=unavailable
fi

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET=$(python3 - <<'PY'
import json
d = json.load(open('/tmp/wa-devices.json'))
for dev in d.get('result', {}).get('devices', []):
    hw = dev.get('hardwareProperties', {})
    if str(hw.get('reality','')).lower() == 'physical':
        print(hw.get('udid') or dev.get('identifier')); break
PY
)
fi
if [ -z "$TARGET" ]; then echo "没有可用真机，退出。"; exit 1; fi

echo "== 2) 构建（自动签名 + 自动更新描述文件）=="
TEAM_ARGS=()
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  TEAM_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
else
  # 没传就从本机证书里读 Team ID（Apple Development 证书的 OU 字段就是 Team ID）
  AUTO_TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | head -1)
  if [ -n "$AUTO_TEAM" ]; then
    echo "   自动识别 Team: $AUTO_TEAM"
    TEAM_ARGS=(DEVELOPMENT_TEAM="$AUTO_TEAM")
  fi
fi
if [ ${#TEAM_ARGS[@]} -eq 0 ]; then
  cat <<'MSG'
❌ 找不到 Team ID。

两种做法：
  A) 在 Xcode 里打开 apple/Walkaholic.xcodeproj → 选 Walkaholic target
     → Signing & Capabilities → Team 选你的 Personal Team（会写进工程文件，之后不用再传）
  B) 直接传：DEVELOPMENT_TEAM=你的TeamID scripts/install-to-device.sh
     （Team ID 在 Xcode → Settings → Accounts → 选中账号右侧的 Team ID）
MSG
  exit 1
fi

# watch target 需要「已配对的实体 Apple Watch」才能签发描述文件。
# 没有实体表时它必然失败，并会把整个构建拖挂，所以先自动摘掉、构建完再装回。
WATCH_STATE_BEFORE=$(python3 scripts/watch-off.py status 2>/dev/null || true)
NEED_WATCH_RESTORE=0
if echo "$WATCH_STATE_BEFORE" | grep -q "依赖 watch target"; then
  echo "   检测到 watch 依赖：本机无实体 Apple Watch，临时摘掉（构建后自动装回）"
  python3 scripts/watch-off.py off >/dev/null
  NEED_WATCH_RESTORE=1
fi

trap 'if [ "$NEED_WATCH_RESTORE" = "1" ]; then python3 scripts/watch-off.py on >/dev/null 2>&1 || true; fi' EXIT

# 隧道不可用时无法用 id= 目标（xcodebuild 会退化成 My Mac 报错），
# 改用 generic/platform=iOS 仍能编译出 arm64 设备包（含签名），之后可手动安装
if [ "$TUNNEL_STATE" = "connected" ]; then
  DEST_ARGS=(-destination "id=$TARGET")
else
  echo "   ⚠️ tunnelState=${TUNNEL_STATE} — CoreDevice 该字段常滞后/误报，只要手机在 USB 树里就继续装"
  DEST_ARGS=(-destination "generic/platform=iOS")
fi

xcodebuild \
  -project Walkaholic.xcodeproj \
  -scheme Walkaholic \
  "${DEST_ARGS[@]}" \
  -derivedDataPath /tmp/walkaholic-dd-device \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  "${TEAM_ARGS[@]}" \
  build 2>&1 | tee /tmp/walkaholic-device-build.log | grep -E "error:|warning: .*signing|BUILD SUCCEEDED|BUILD FAILED"

APP=/tmp/walkaholic-dd-device/Build/Products/Debug-iphoneos/Walkaholic.app
if [ ! -d "$APP" ]; then
  echo "❌ 构建产物不存在：$APP"
  echo "   若是签名错误，请先在 Xcode 里打开工程 → Signing & Capabilities → 选择 Team 后重试。"
  exit 1
fi

# 打包成 .ipa（无论隧道是否通都产出，方便手动拖进 Xcode / Apple Configurator）
IPA_DIR="$ROOT/apple/build-device"
mkdir -p "$IPA_DIR/Payload"
rm -rf "$IPA_DIR/Payload/Walkaholic.app"
cp -R "$APP" "$IPA_DIR/Payload/"
rm -f "$IPA_DIR/Walkaholic.ipa"
( cd "$IPA_DIR" && zip -qry Walkaholic.ipa Payload )
echo "   📦 .ipa: $IPA_DIR/Walkaholic.ipa ($(du -h "$IPA_DIR/Walkaholic.ipa" | cut -f1))"

if [ "$TUNNEL_STATE" != "connected" ]; then
  cat <<'MSG'
   隧道状态显示未连接（CoreDevice 的 tunnelState 常有滞后/误报），仍会尝试安装。
MSG
fi

echo "== 3) 安装到 $TARGET =="
# 每次都重装会让 iOS 重新判定「未受信任」，用户必须再去 设置 里点一次信任。
# 只在 bundle 不一致（重装了 App）或显式 FORCE=1 时才卸载重装。
NEED_REINSTALL=0
if [ "${FORCE:-0}" = "1" ]; then
  NEED_REINSTALL=1
else
  INSTALLED=$(xcrun devicectl device info apps --device "$TARGET" --json-output /tmp/wa-apps.json >/dev/null 2>&1; \
    python3 -c "
import json
try:
    d=json.load(open('/tmp/wa-apps.json'))
except Exception:
    print(''); raise SystemExit
for a in d.get('result',{}).get('apps',[]):
    if a.get('bundleIdentifier')=='com.walkaholic.app':
        print(a.get('url','')); break
" 2>/dev/null)
  [ -z "$INSTALLED" ] && NEED_REINSTALL=1
fi

if [ "$NEED_REINSTALL" = "1" ]; then
  # 旧版本先卸掉，否则残留在 LaunchServices 里的旧签名会让新装的一直报 invalid signature
  xcrun devicectl device uninstall app --device "$TARGET" com.walkaholic.app >/dev/null 2>&1
  if ! xcrun devicectl device install app --device "$TARGET" "$APP" --timeout 180; then
    cat <<'MSG'

❌ 安装失败。已编译好签名包，可以手动装：

  A) USB：用「数据线」重插 iPhone（不是充电线），解锁并点『信任』后重跑本脚本
  B) 无线：Xcode → Window → Devices and Simulators → 左上角「+」选你的 iPhone
     → 勾选 Connect via network → 输入手机上的 6 位配对码 → 重跑
  C) 直接把 .ipa 拖进 Xcode → Devices and Simulators
MSG
    exit 3
  fi
else
  # 已装同签名版本：直接覆盖安装，不卸载 → 保留用户已点的「信任」状态
  echo "   已装过同签名版本，覆盖安装（不卸载，保留信任状态）"
  if ! xcrun devicectl device install app --device "$TARGET" "$APP" --timeout 180 >/dev/null 2>&1; then
    echo "   覆盖安装失败 → 回退到卸载重装（需要重新信任）"
    xcrun devicectl device uninstall app --device "$TARGET" com.walkaholic.app >/dev/null 2>&1
    xcrun devicectl device install app --device "$TARGET" "$APP" --timeout 180 || exit 3
  fi
fi

echo "== 4) 启动 =="
# 首次启动经常被判 invalid signature / not trusted —— 这是 iOS 装完立刻启动的时序问题，
# 重试几次（期间系统完成描述文件登记）通常就好了。所以这里重试而不是直接报错。
LAUNCH_OK=0
for attempt in 1 2 3 4; do
  xcrun devicectl device process launch --device "$TARGET" com.walkaholic.app > /tmp/walkaholic-launch.log 2>&1
  if grep -q "Launched" /tmp/walkaholic-launch.log; then
    LAUNCH_OK=1
    echo "   ✅ 已启动（第 $attempt 次尝试）"
    break
  fi
  echo "   第 $attempt 次启动失败，2 秒后重试…"
  sleep 2
done

if [ "$LAUNCH_OK" = "0" ]; then
  if grep -q "profile has not been explicitly trusted\|invalid code signature" /tmp/walkaholic-launch.log 2>/dev/null; then
    EXPIRY=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
    cat <<MSG

⚠️  已安装，但 iOS 拒绝启动它。这不是构建问题，在手机上点一下就好：

  设置 → 通用 → VPN 与设备管理 → 「开发者 App」下点你的 Apple ID
  → 信任「Chen Xiaoqiang」→ 回到桌面打开「步迷」

  如果那个页面里没有这个账号、或者点了信任还是打不开，
  说明手机连不上 Apple 的校验服务器（ppq.apple.com）：
  确认手机连着能上网的 Wi-Fi，再试一次。

  免费个人账号的描述文件本次到 ${EXPIRY:-7 天后} 过期。过期后 App 会闪退，重跑本脚本即可。
MSG
  else
    echo "   ⚠️ 启动失败，详见 /tmp/walkaholic-launch.log"
    tail -5 /tmp/walkaholic-launch.log
  fi
else
  echo "完成。手机上打开『步迷』即可。"
fi
