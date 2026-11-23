#!/usr/bin/env bash
# 生成本地自签名材料（OpenHarmony SDK 自带 CA），用于模拟器/自签设备调试。
#
# 为什么要自己签：
#   华为账号自动签名（DevEco → Project Structure → Signing Configs）需要登录，
#   CI / 纯命令行环境拿不到。OpenHarmony SDK 自带一套完整 CA 私钥
#   （toolchains/lib/OpenHarmony.p12，口令 123456），可以本地签发合法的证书链，
#   用 hap-sign-tool 签出来的 .hap 能通过 verify-app。
#
# 注意：产物只在本机/模拟器调试有效，不能上架华为应用市场。
# 正式发布必须用华为账号 + AGC 申请的正式证书。
#
# 用法： bash scripts/gen-local-sign.sh
set -euo pipefail

HOME_DEVECO="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
LIB="$HOME_DEVECO/sdk/default/openharmony/toolchains/lib"
JAVA="$HOME_DEVECO/jbr/Contents/Home/bin/java"
SIGN="$LIB/hap-sign-tool.jar"
KEYTOOL="$HOME_DEVECO/jbr/Contents/Home/bin/keytool"
OUT="${LOCAL_SIGN_DIR:-$HOME/.deveco/localsign}"

for f in "$JAVA" "$SIGN" "$KEYTOOL" "$LIB/OpenHarmony.p12"; do
  [ -f "$f" ] || { echo "缺少 ${f}（先跑 scripts/setup-deveco-cli.sh）"; exit 1; }
done

BUNDLE="${BUNDLE_NAME:-com.walkaholic.harmony}"
mkdir -p "$OUT"
cd "$OUT"

echo "═══ 1. 导出 SDK 自带 CA 证书 ═══"
for alias in "openharmony application root ca:root-ca.cer" \
             "openharmony application ca:sub-ca.cer"; do
  a="${alias%%:*}"; f="${alias##*:}"
  "$KEYTOOL" -exportcert -alias "$a" -keystore "$LIB/OpenHarmony.p12" \
    -storetype PKCS12 -storepass 123456 -rfc -file "$OUT/$f" >/dev/null 2>&1
  echo "  ✅ $f"
done

echo "═══ 2. 签发应用证书链（3 级）═══"
"$JAVA" -jar "$SIGN" generate-app-cert \
  -keyAlias "openharmony application release" -keyPwd "123456" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" -issuerKeyPwd "123456" \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=Walkaholic Debug" \
  -validity 3650 -signAlg "SHA256withECDSA" \
  -keystoreFile "$LIB/OpenHarmony.p12" -keystorePwd "123456" \
  -outForm certChain -rootCaCertFile "$OUT/root-ca.cer" -subCaCertFile "$OUT/sub-ca.cer" \
  -outFile "$OUT/app-cert-chain.cer" 2>&1 | grep -E "success|ERROR" | sed 's/^/  /'

echo "═══ 3. 生成 debug profile ═══"
# debug profile 会校验设备 UDID。拿到设备后可以这样刷新：
#   UDID=$(hdc shell bm get --udid | tr -d '\r')
#   DEVICE_UDID="$UDID" bash scripts/gen-local-sign.sh
DEVICE_IDS_PY=""
if [ -n "${DEVICE_UDID:-}" ]; then DEVICE_IDS_PY="$DEVICE_UDID"; fi
python3 - "$LIB/UnsgnedDebugProfileTemplate.json" "$OUT" "$BUNDLE" "$DEVICE_IDS_PY" <<'PY'
import json, sys, time, uuid
tpl_path, out, bundle, udid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
tpl = json.load(open(tpl_path))
chain = open(out + "/app-cert-chain.cer").read()
leaf = [c for c in chain.split("-----END CERTIFICATE-----") if "BEGIN CERTIFICATE" in c][0]
leaf += "-----END CERTIFICATE-----\n"
tpl["bundle-info"]["bundle-name"] = bundle
tpl["bundle-info"]["developer-id"] = "Walkaholic"
tpl["bundle-info"]["development-certificate"] = leaf
now = int(time.time())
tpl["validity"] = {"not-before": now - 86400, "not-after": now + 3650 * 86400}
tpl["uuid"] = str(uuid.uuid4())
tpl["debug-info"]["device-ids"] = [v.strip() for v in udid.split(",") if v.strip()] or ["ANY"]
json.dump(tpl, open(out + "/profile.json", "w"), indent=2)
print("  ✅ profile.json（bundle=%s, devices=%s）" % (bundle, tpl["debug-info"]["device-ids"]))
PY

echo "═══ 4. 签发 profile.p7b ═══"
"$JAVA" -jar "$SIGN" sign-profile \
  -keyAlias "openharmony application profile release" -signAlg "SHA256withECDSA" -mode "localSign" \
  -profileCertFile "$LIB/OpenHarmonyProfileRelease.pem" \
  -inFile "$OUT/profile.json" -keystoreFile "$LIB/OpenHarmony.p12" \
  -outFile "$OUT/profile.p7b" -keyPwd "123456" -keystorePwd "123456" \
  2>&1 | grep -E "success|ERROR" | sed 's/^/  /'

cp "$LIB/OpenHarmony.p12" "$OUT/OpenHarmony.p12"

cat > "$OUT/sign-config.json5" <<JSON
{
  // 本地自签名（OpenHarmony SDK CA），仅供模拟器/自签设备调试
  "signingConfigs": [
    {
      "name": "default",
      "type": "OpenHarmony",
      "material": {
        "certpath": "$OUT/app-cert-chain.cer",
        "keyAlias": "openharmony application release",
        "keyPassword": "123456",
        "profile": "$OUT/profile.p7b",
        "signAlg": "SHA256withECDSA",
        "storeFile": "$OUT/OpenHarmony.p12",
        "storePassword": "123456"
      }
    }
  ]
}
JSON

echo
echo "产物目录: $OUT"
ls -1 "$OUT"
