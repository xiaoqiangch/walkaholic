# 步迷 Walkaholic · HarmonyOS

HarmonyOS NEXT（API 26）移植版，ArkTS + ArkUI 声明式。

- **怎么跑起来**：[docs/HARMONY.md](docs/HARMONY.md) §3（图形界面 / 纯命令行两条路）
- **架构与移植对照**：[docs/HARMONY.md](docs/HARMONY.md) §1
- **三端对齐规格**：[../docs/parity.md](../docs/parity.md)（唯一规格，改动需三端同步）
- **本机开发环境**：[docs/HARMONY.md](docs/HARMONY.md) §11（版本、脚本、环境变量）
- **立即可测路径**：鸿蒙浏览器打开 https://xiaoqiangch.github.io/walkaholic/ → 添加到桌面

## 一键命令

```bash
bash ../scripts/check-harmony.sh      # 离线校验：tsc + 单测 + ArkTS 静态检查
bash ../scripts/setup-deveco-cli.sh   # 部署 CLI 工具链（首次）
bash ../scripts/gen-local-sign.sh     # 生成本地签名材料（首次）
bash ../scripts/build-hap.sh          # 真编译 + 签名 + 验签 → .hap
bash ../scripts/build-hap.sh --device # 再装到模拟器/真机
```

```
entry/src/main/ets/
├── core/    纯 TypeScript 逻辑层（不依赖 @ohos.*，可 Node 测试）
│   ├── parity.ts   三档放宽 / 硬帽 / 黑名单 / 去重 / 类别多样性
│   ├── providers.ts 高德 / 百度 / OSM / 维基
│   ├── mapkeys.ts  地图 Key 下发（包内→Pages→后台→免费源）
│   ├── search.ts   三档搜索 + 策展优先 + 明确失败（绝不虚构）
│   ├── fog.ts      迷雾路径几何（纯函数）
│   ├── territory.ts 疆域凸包 + 爵位判定（docs/territory.md 唯一实现）
│   ├── sharecard.ts 疆域分享卡布局（720×960，纯计算）
│   ├── photo-gps.ts 照片 EXIF GPS 自解析 + 120m 到达验证
│   ├── hints.ts    图鉴「附近惊喜」隐晦提示 + 探寻线索解锁（保密铁律）
│   ├── account.ts  账号（手动 Cookie）
│   └── …           地理 / 抽盒 / 会话 / dHash / 成就 / 持久化 / store
├── pages/   路由外壳（Index）
├── views/   7 个界面
├── components/ 共享组件 + 平台注入（HttpClient / Location / PreferencesKV）
└── theme/   设计 token（字号已按 parity.md §5 对齐 Web v32）
```

## 校验结果

最近一次离线校验（2026-11-20，v0.11 点数门槛 + EXIF GPS 验证）：

```
tsc --noEmit            0 error
npm test                195/195 通过
ArkTS 静态检查          32 个 .ets，0 error（14 个分区全过，含「附近惊喜保密」「疆域对齐」「拍照验证」守卫）
```

真机编译与模拟器验证记录见 [docs/HARMONY.md](docs/HARMONY.md) §11–§12（2026-11-19：`.hap` 构建 + 本地签名 + 模拟器端到端跑通）。
**说明**：v0.10 / v0.11 改动尚未重新跑 `.hap` 编译与模拟器验证，见 docs §7 的待确认清单。

> 真机运行仍需模拟器或设备；运行时行为清单见 [docs/HARMONY.md](docs/HARMONY.md) §7、实测记录见 §12。
> 本地自签名只用于调试，**上架必须用华为账号正式证书**（见 §3.1）。
