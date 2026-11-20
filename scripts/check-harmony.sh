#!/usr/bin/env bash
# 鸿蒙移植版校验：逻辑层类型检查 + Node 测试 + ArkTS 静态检查 + 真实编译（可选）
# 前 4 步不依赖 IDE；第 5 步需要先跑 scripts/setup-deveco-cli.sh（见 harmony/docs/HARMONY.md §11）。
set -uo pipefail
cd "$(dirname "$0")/.."
HARMONY="harmony"
FAIL=0

echo "═══ 1. 逻辑层类型检查（tsc --noEmit）═══"
if [ ! -d "$HARMONY/node_modules/typescript" ]; then
  echo "  → 安装 TypeScript…"
  (cd "$HARMONY" && npm install --silent >/dev/null 2>&1)
fi
if (cd "$HARMONY" && ./node_modules/.bin/tsc -p tsconfig.test.json --noEmit 2>&1); then
  echo "  ✅ 0 error"
else
  echo "  ❌ 类型检查失败"; FAIL=1
fi

echo
echo "═══ 2. 逻辑层单元测试 ═══"
if (cd "$HARMONY" && npm test 2>&1 | tail -30); then
  echo "  ✅ 测试通过"
else
  echo "  ❌ 测试失败"; FAIL=1
fi

echo
echo "═══ 3. ArkTS 静态检查 ═══"
if [ -f "$HARMONY/scripts/check-arkts.mjs" ]; then
  if node "$HARMONY/scripts/check-arkts.mjs"; then
    echo "  ✅ 静态检查通过"
  else
    echo "  ❌ 静态检查失败"; FAIL=1
  fi
else
  echo "  ⚠️  未找到 harmony/scripts/check-arkts.mjs，跳过"
fi

echo
echo "═══ 4. 工程完整性 ═══"
for f in AppScope/app.json5 build-profile.json5 hvigorfile.ts oh-package.json5 \
         entry/src/main/module.json5 entry/src/main/resources/base/profile/main_pages.json; do
  if [ -f "$HARMONY/$f" ]; then echo "  ✅ $f"; else echo "  ❌ 缺少 $f"; FAIL=1; fi
done

echo
echo "═══ 5. 真实 ArkTS 编译（可选）═══"
DEVECO_CLI="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
if [ -x "$DEVECO_CLI/tools/node/bin/node" ]; then
  # SignHap 失败是预期（hvigor 要加密格式口令），只看 ArkTS 编译是否干净、unsigned 包是否产出
  HAPLOG=$(cd "$HARMONY" && ./hvigorw assembleHap -p product=default --no-daemon 2>&1 || true)
  ARKERR=$(echo "$HAPLOG" | grep -c "ArkTS:ERROR" || true)
  if [ "$ARKERR" -eq 0 ] && ls "$HARMONY"/entry/build/*/outputs/*/*.hap >/dev/null 2>&1; then
    echo "  ✅ CompileArkTS 0 error，已产出 $(basename "$(ls -t "$HARMONY"/entry/build/*/outputs/*/*.hap | head -1)")"
  else
    echo "  ❌ ArkTS 编译失败（$ARKERR 处错误）"; FAIL=1
  fi
else
  echo "  ⚠️  未部署 CLI 工具链（bash scripts/setup-deveco-cli.sh），跳过"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "全部通过"; exit 0
else echo "存在失败项"; exit 1; fi
