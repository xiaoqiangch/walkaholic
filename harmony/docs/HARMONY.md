# 步迷 Walkaholic · HarmonyOS 移植

> 状态：v0.11 点数门槛 + 拍照 EXIF GPS 到达验证（2026-11-20）；v0.9 已与 iOS 1:1 对齐（2026-11-14）
> 目标平台：**HarmonyOS NEXT**（API 26 / 26.0.1），ArkTS + ArkUI 声明式
> 本机工具链：DevEco Studio 26.0.1 + SDK 26（已部署，见 §11「本机开发环境」）

---

## 1. 为什么是 ArkTS + ArkUI

| 候选方案 | 结论 |
|---|---|
| **ArkTS + ArkUI 原生**（本项目） | ✅ 采用。鸿蒙官方唯一一等公民路线，能上架、能调定位/相机/文件、性能好 |
| 打包 PWA 成 WebView 外壳 | 备选。零成本、立即可用，但拿不到系统能力、上架受限；见 §7 |
| Flutter / React Native 三方壳 | ❌ 不采用。鸿蒙上生态支持弱、体积大 |

架构上和苹果版保持**同一套分层**，便于三端（iOS / Web / HarmonyOS）语义一致：

```
entry/src/main/ets/
├── core/            ← 纯逻辑（TypeScript，可在 Node 里跑测试，不依赖 ArkUI）
│   ├── types.ts         数据契约（对应 apple/Shared/Core/Models.swift）
│   ├── contract.ts      UI↔逻辑 调用契约（对应 @Observable WalkaholicStore 的公开面）
│   ├── geo.ts           Haversine 距离 / 方位角 / 按方位偏移 / WGS↔GCJ↔BD 坐标转换
│   ├── catalog.ts       24 个内置地点（对应 PlaceCatalog.swift）
│   ├── engine.ts        种子随机 + 抽盒权重 + 序列号 + 心情亲和
│   ├── session.ts       旅程状态机（线索阈值 400/200/60、到达 30m）
│   ├── surprise.ts      dHash 感知哈希 + 汉明距离 + 复刻判定
│   ├── achievements.ts  成就判定
│   ├── demo.ts          演示数据（口径与 Web/iOS 一致）
│   ├── social.ts        圈子动态 + 排行榜
│   ├── store.ts         编排：抽盒/推进/揭晓/收录/埋寻/持久化/真实地点入口
│   ├── persistence.ts   KeyValueStore（HarmonyOS 端注入 @ohos.data.preferences）
│   ├── parity.ts        三端对齐规格：三档放宽/硬帽/黑名单/去重/类别多样性（parity.md §2）
│   ├── http.ts          HttpClient 接口（平台实现由 UI 注入）
│   ├── providers.ts     高德/百度/OSM/维基解析与编排（parity.md §1）
│   ├── mapkeys.ts       地图 Key 下发（包内→Pages→后台→免费源，12h 缓存）
│   ├── search.ts        三档搜索编排 + 策展优先 + **明确失败**（绝不虚构）
│   ├── flow.ts          抽盒完整编排（Key→策展→搜索）+ 路线规划
│   ├── route.ts         Valhalla 步行路线（polyline6 解码）
│   ├── territory.ts     疆域凸包 + 爵位判定（docs/territory.md 唯一实现）
│   ├── sharecard.ts     疆域分享卡布局（720×960，纯计算）
│   ├── photo-gps.ts     照片 EXIF GPS 自解析 + 120m 到达验证（纯计算）
│   ├── fog.ts           迷雾路径几何（parity.md §3，纯函数可测）
│   ├── geocode.ts       地址 → 坐标（GPS 不可用时的真实地点出口）
│   ├── hints.ts         图鉴「附近惊喜」隐晦提示 + 探寻页线索解锁（保密铁律）
│   └── account.ts       账号服务（手动 Cookie 管理）
├── theme/Theme.ets      设计 token（奶油底 / 琥珀主色 / 圆角 / 字号）
├── pages/Index.ets      Tab 外壳
├── views/               7 个界面：Home / SetupSheet / Journey / Reveal / Cards / Social / Profile
├── components/          共享小组件 + 平台注入（HttpClient / Location / PreferencesKV）
│                        + 迷雾路径 Canvas（FogPath）+ 失败面板 + 账号/数据源面板
└── entryability/        EntryAbility（窗口、定位权限）
```

**关键决策：`core/` 全部是纯 TypeScript，不 import 任何 `@ohos.*`。**
好处：逻辑可以脱离鸿蒙设备在 Node 里跑单元测试（本机就是这么验证的），未来也不会被平台 API 变更拖累。

---

## 2. 已经做了什么

| 项 | 状态 |
|---|---|
| DevEco 标准工程结构（AppScope / entry / hvigorfile / build-profile / oh-package / module.json5） | ✅ |
| 应用图标、启动页背景、权限声明（INTERNET / LOCATION / APPROXIMATELY_LOCATION） | ✅ |
| 数据契约 + UI 调用契约（`core/types.ts`、`core/contract.ts`） | ✅ 类型检查 0 error |
| 逻辑层移植（地理 / 抽盒 / 会话 / dHash / 成就 / 演示数据 / store / 持久化） | ✅ **39 项单元测试全绿**，见 §4 |
| ArkUI 界面（7 个主界面 + 8 个共享组件，共 4206 行） | ✅ 代码完成，静态检查 20 个 .ets 全通过，**待 DevEco 首编验证** |
| 真实定位（`@ohos.geoLocationManager`） | ✅ 已接，权限拒绝会降级到演示模式 |
| 真实地图 | ⏳ 本轮用 ArkUI Canvas 手绘抽象街区（和 Web 版同源），不引入需 AGC 配置的 Map Kit |
| 埋惊喜 / 寻惊喜界面 | ⏳ 逻辑层已备好；界面本轮只放首页入口卡片 |
| **真实 POI 数据源**（高德/百度/OSM/维基） | ✅ v0.7 完成，ArkTS 直接 HTTP（无 CORS） |
| **三档放宽 + 硬帽 + 黑名单**（parity.md §2） | ✅ v0.7 完成，纯 TS 单测覆盖 |
| **明确失败面板**（绝不虚构兜底） | ✅ v0.7 完成，三按钮同 Web |
| **迷雾路径视图**（parity.md §3） | ✅ v0.7 几何层单测覆盖；Canvas 绘制待 DevEco 首编 |
| **步行定位与个人地图稳定性** | ✅ 定位精度 / 异常跳点过滤、按精度抑制误报、个人地图断轨与等比例投影，纯 TS 单测覆盖 |
| **账号**（登录/同步/恢复/退出/删号） | ✅ v0.7 完成（手动 Cookie） |
| **图鉴「附近惊喜」隐晦提示**（对齐 Web v46） | ✅ v0.8 完成，纯 TS 单测 + 静态守卫双重保密 |
| **探寻面板**（三阶线索按距离解锁） | ✅ v0.8 完成（拍照/对比待相机接入） |
| **字号对齐 Web v32**（无 <10pt） | ✅ v0.7 完成 |
| **疆域爵位卡**（对齐 Web v46 / docs/territory.md） | ✅ v0.10 完成：印章 + 爵位 + 三数据 + 进度 + 地图/分享入口 |
| **「我的城市」疆域地图**（新建页） | ✅ v0.10 完成：Canvas 凸包多边形（爵位色 20% + 描边 2.5 + 顶点圆）+ 统计卡；**无疆域不画假多边形** |
| **疆域分享卡**（720×960） | ✅ v0.10 完成：色带/印章/爵位/形状/三数据/页脚 + 保存到相册（失败降级为提示截屏） |
| **点数门槛**（防「四个角」刷面积） | ✅ v0.11 完成：8 档 minPoints + capped/blockedBy/pointsNeeded +「边界够了，但只有 N 个探索点」文案 |
| **拍照 + EXIF GPS 到达验证** | ✅ v0.11 完成：自解析 JPEG APP1（II+MM）/ 120m 判定 / 9 种失败文案逐字对齐 docs / 记录 photoGps + photoDistance |

---

## 3. 怎么跑起来

### 3.1 图形界面（推荐日常开发）

```bash
# 1. 装 DevEco Studio（免费）
#    https://developer.huawei.com/consumer/cn/deveco-studio/
#    26.0.1 已内置 SDK（HarmonyOS 26.0.1 / API 26）、Node、ohpm、hvigor、JBR、模拟器

# 2. 打开工程
DevEco Studio → Open → 选择仓库里的 harmony/ 目录（不是仓库根目录）

# 3. 等 Sync 完成（hvigor 自动拉 oh_modules）

# 4. 签名（首次）
File → Project Structure → Signing Configs → 勾选 Automatically generate signature
（需登录华为开发者账号，免费。**只有这条路能产可上架 / 可进真机的正式签名**）

# 5. 运行
Device Manager 下模拟器镜像（或真机开发者模式 + USB 调试）→ Run 'entry'
```

### 3.2 纯命令行（CI / 无账号也能编译签名）

**已经打通并实测通过**（2026-11-19）：

```bash
bash scripts/setup-deveco-cli.sh    # ① 把 IDE 工具链复制到 ~/DevTools/deveco
bash scripts/gen-local-sign.sh      # ② 用 SDK 自带 CA 生成本地签名材料
bash scripts/build-hap.sh           # ③ 编译 + 签名 + 校验签名
bash scripts/build-hap.sh --device  # ④ 构建后直接装到已连接的模拟器/真机
```

产物：`harmony/entry/build/default/outputs/default/entry-default-signed.hap`

#### 为什么要有 ①：macOS 26 的坑

**现象**：在 `/Applications/DevEco-Studio.app/Contents` 里直接执行任何 Mach-O
（`tools/node/bin/node`、`jbr/.../java`、`sdk/.../hdc`）都会永久卡死，
`sample` 抓栈显示停在 dyld 的 `_dyld_start`，CPU 占用 0。

**原因**：macOS 26（本机 27.0.1 / 26A434）的 App Management 保护会拦截
「在 .app bundle 内执行可执行文件」；用 `open -a` 启动 IDE 本身不受影响，
但 fork 出来的 CLI 子进程会卡在签名校验那一步。同样的二进制复制到普通目录立刻正常。

所以命令行构建走 `~/DevTools/deveco/` 下的副本（`ditto` 复制，约 7 GB），
IDE 图形界面仍用 `/Applications`。`harmony/hvigorw` 会优先找 `~/DevTools/deveco`，
找不到才回退到 `/Applications`（并可用 `DEVECO_IDE_HOME` 覆盖）。

#### 为什么要有 ②：绕过华为账号的本地签名

hvigor 的 `SignHap` 要求密码是 DevEco 加密格式（密文长度 ≥32），
命令行拼不出来；而华为账号自动签名需要登录。折中方案：

- OpenHarmony SDK 自带一套完整 CA 私钥（`toolchains/lib/OpenHarmony.p12`，口令 `123456`）
- 用它 `generate-app-cert` 签发三级证书链 → `sign-profile` 签 profile → `hap-sign-tool sign-app` 签 HAP
- 产物经 `verify-app` 验证为 `Verify success`

**限制**：本地签名的 `.hap` 只能在本机模拟器 / 自签设备调试，**不能上架应用市场**。
正式发布仍须走 §3.1 第 4 步（华为账号 + AGC 正式证书）。

### 常见首编问题
| 现象 | 原因 | 处理 |
|---|---|---|
| `hvigor-ohos-plugin not found` | 没 Sync 或网络问题 | File → Sync and Refresh Project |
| `Signature not configured` | 没配签名 | §3.1 第 4 步，或走 §3.2 的本地签名 |
| `Invalid storeFile value` / `长度小于 32` | `sign-config.json5` 指向的 `~/.ohos/config/*.p12` 不存在，或密码是明文 | 走 §3.2；明文口令 hvigor 不认 |
| CLI 卡死无输出 | macOS 26 App Management 拦截 .app 内可执行文件 | 走 §3.2 第 ① 步 |
| 定位无反应 | 权限未授予 | 首次进入点「允许」；模拟器需在 Device Manager 里设置虚拟位置 |
| `Cannot find module './core/xxx'` | 大小写或路径拼错 | 鸿蒙对路径大小写敏感 |

---

## 4. 逻辑层校验（本机可跑，真实结果）

### 定位与个人地图质量策略

- 步行定位使用导航场景的高精度订阅，并以 2 秒 / 3 米为更新间隔；精度差于 50 米的 fix 不参与导航、到达判定或轨迹记录。
- 单次不符合步行速度的 GPS 跳点会被丢弃；连续稳定的新位置可触发重新定位，避免错误位置长期卡住。
- 对位置作轻量平滑，移动方向至少累计 8 米才更新；低精度下的「偏离路线」提示会按系统给出的精度放宽，最高 45 米。
- 迷雾导航在每次定位更新时复用同一次路线累计距离结果，减少长路线重复扫描。
- 个人地图轨迹遇到超过 250 米的断点会拆成独立线段；POI 与轨迹使用同一个以米为单位的本地投影，保持经纬方向比例一致。

最近一次运行（2026-11-09 23:1x，v0.7 对齐后）：

```
1. tsc -p tsconfig.test.json --noEmit   → 0 error
2. npm test                             → 98/98 通过（原 39 项 + 新增 59 项）
3. ArkTS 静态检查（25 个 .ets）           → 0 error
    ✅ import 路径  ✅ ArkTS 严格模式  ✅ ForEach key
    ✅ @Entry 注册  ✅ 资源引用       ✅ 保密规则  ✅ 工程契约
```

新增 59 项测试覆盖（对照 docs/parity.md）：

| 分组 | 内容 |
|---|---|
| 坐标系 | WGS↔GCJ↔BD 往返误差 < 3m；境外不偏移 |
| 三档放宽 | min/max 距离公式、距离硬帽、层级单调 |
| 质量门槛 | 硬排除（公厕/加油站）、软降权（便利店 ×0.22）、类别权重 |
| 去重/多样性 | 30m 或同名合并、每类最多 5、按距离排序 |
| 择优 | 前 40%（≥3）加权随机，软黑名单不优先 |
| 数据源解析 | 高德/百度/OSM/维基 fixture（含坐标转换、过滤规则） |
| 数据源编排 | 无 Key 只跑 OSM+维基、单源失败不影响其他源 |
| 三档搜索 | 找到 / 全失败 / 档位放宽 / 最后用软黑名单点 / 策展优先 |
| Key 下发 | 包内→Pages→后台→免费源四级降级、12h 缓存、掩码 |
| 账号 | Set-Cookie 提取、本地校验、同步超限、401 清会话、恢复 |
| 迷雾几何 | 窗口公式、沿线投影、两端渐隐、箭头 55m、<60m 隐藏、指北针 |
| 抽盒编排 | prepareQuest 成功/失败路径、策展 6h 缓存 |
| 地址/路线 | 地址→坐标三级、polyline6 往返、Valhalla 解析、10min 缓存 |
| 保密 | 照片/署名/简介到达前必须抹掉（快照 JSON 不含图片域名） |

Lead 还做了一轮**不依赖队友测试的独立复核**（自己写脚本 import 编译产物）：

| 复核项 | 结果 |
|---|---|
| 北京→上海距离 ≈ 1067 km（Haversine） | ✅ 1067 km |
| 正北偏移 100m 后距离 ≈ 100m、方位角 ≈ 0° | ✅ 100.00m / 0.00° |
| 线索阈值：300m 不解锁第 2 条；199m 解锁第 2 条；50m 解锁第 3 条 | ✅ |
| 20m 触发 `arrived` | ✅ |
| 15 分钟档 300 次抽盒：hidden = 0 | ✅ |
| 60 分钟档 300 次抽盒：出现 hidden | ✅ |
| 快照必填字段齐全（含 places=24 / togetherCode） | ✅ |
| 真实坐标会话 → 走到目的地自动到达 | ✅ |
| dHash 1 位差 → 相似度 0.96875、完全相同 → 1.0 | ✅ |
| 到达前快照不含真实地点名 | ✅（修了下面这个漏洞） |

### 4.1 独立复核时发现并修掉的保密漏洞

原实现 `maskPlaceForWalking()` 只清 `name` 和 `address`，但 `why` 会描述地点特征：
```jsonc
// 到达前仍能被看到：
"why": "花店开在菜场后门，门口永远湿漉漉的。\n老板会把卖剩的花扎成一把…",
"name": ""   // 名字遮了，why 却把人带到花店
```
已改为 `why` / `task` 一并清空，`hints` 再过一遍 `scrubHints()`，并补了对应测试。
**这条规则现在有测试守着**，后续改动不会退化。

```bash
bash scripts/check-harmony.sh
```

包含三步：
1. **类型检查**：`tsc -p tsconfig.test.json --noEmit` → 0 error
2. **单元测试**：地理距离、会话推进、抽盒权重、dHash 相似度、埋/寻结算、成就解锁、保密规则
3. **ArkTS 静态检查**：import 路径存在、无 `any`、`ForEach` 有 keyGenerator、页面注册、资源引用存在

> 这套校验**不等于**编译通过。`.ets` 的 ArkUI 语法（装饰器、组件树）只有 DevEco 的 ArkTS 编译器能验。

---

## 5. 与苹果版的对齐点（改动前必须一致）

| 规则 | 值 |
|---|---|
| 到达阈值 | 30 米 |
| 线索阈值 | 第 2 条 400m / 第 3 条 200m / 到达前 60m |
| 抽盒权重 | 常见 70 / 稀有 22 / 史诗 6 / 隐藏 2 |
| 隐藏款限制 | 只在 60 分钟档位出现 |
| 时长档位 | 15 分钟 300m / 30 分钟 480m / 60 分钟 900m |
| 抽盒半径 | 900m / 1600m / 3000m |
| dHash 判定 | 64 位汉明距离 → `max(0, 1 - dist/32)`，≥ 0.45 通过 |
| 埋惊喜奖励 | 埋下 +30，寻到方 +80，作者 +40，未中 +10（每颗只发一次） |
| 演示口径 | 周惊喜值 305 / 18 张卡 / 连续 12 天 / Lv.6 黄昏猎人 / 稀有 7 / 隐藏 1 |

**保密规则（产品灵魂）**：到达前任何界面不得出现目的地名称；线索不得含地名（含前两字）。

---

## 6. HarmonyOS 与 iOS 的平台差异清单

| 能力 | iOS | HarmonyOS | 移植处理 |
|---|---|---|---|
| 定位 | CoreLocation | `@ohos.geoLocationManager` | 已接，含权限申请与降级 |
| 持久化 | UserDefaults | `@ohos.data.preferences` | `KeyValueStore` 注入 |
| 照片选择 | PhotosPicker | `@ohos.file.picker`（PhotoViewPicker） | 埋惊喜界面待做 |
| 相机 | AVFoundation | `@ohos.multimedia.camera` + `CameraPicker` | 同上 |
| 感知哈希 | CoreImage 解码后自己算 | `@ohos.multimedia.image` 解码成 PixelMap → 取灰度 | 算法已移植，取图待接 |
| 手表端 | watchOS App | 华为手表是另一套（Lite Wearable / Wearable） | **本轮不做**，见 §8 |
| 小地图 | MapKit | 需 AGC 配置 Map Kit | 本轮用 Canvas 手绘，保持「不显示目的地」 |
| 震动反馈 | CoreHaptics / UIImpactFeedback | `@ohos.vibrator` | 待接 |

---

## 7. 首编验证结果与仍需真机确认的行为

### 7.1 ArkTS 编译：8 处 API 写法全部通过（2026-11-19 实测）

原本列为「首次编译大概率报错」的 8 处 API 签名，在真实 ArkTS 编译下**全部一次通过**：

| 文件 | 待验证内容 | 结果 |
|---|---|---|
| `entryability/EntryAbility.ets` | `windowStage.loadContent` 回调签名、`setWindowBackgroundColor` | ✅ |
| `components/Location.ets` | `geoLocationManager.getCurrentLocation` / `on('locationChange')` | ✅ |
| `components/PreferencesKV.ets` | `@kit.ArkData` 的 `preferences.getSync / putSync / deleteSync` | ✅ |
| `components/AbstractMap.ets` | `CanvasRenderingContext2D` 字体与 `lineDash` | ✅ |
| `components/FogPath.ets` | Canvas `rotate` / `setLineDash` / `globalAlpha` / `arc` 四件套 | ✅ |
| `components/HttpClient.ets` | `http.createHttp()` / `request()` 签名、`expectDataType`、header 键名、`responseCode` | ✅ |
| `components/HttpClient.ets` | `resourceManager.getRawFileContent('mapkeys.json')` + catch 分支 | ✅ |
| `components/AccountPanel.ets` | `TextInput` 的 `InputType.Password`、`promptAction.showToast` | ✅ |
| `components/SeekPanel.ets` | `@Prop @Watch` 多字段联动、`WaQuietButton` 的 `tag` | ✅ |

> 说明：编译通过 ≠ 运行正确。装饰器/状态管理的**运行时行为**、Canvas 的实际渲染、
> 权限弹窗、网络请求的真实响应，仍需在模拟器/真机上确认 —— 见 §7.2。

### v0.7 新增、需要真机确认的行为

| 行为 | 本机无法验证的原因 | 真机上怎么确认 |
|---|---|---|
| 高德/百度 Key 真实可用 | 没有真 Key（Key 由后台下发，主仓不存） | 「我的 → 数据源」显示「已由后台配置 ✓」；抽盒成功 |
| 高德返回 GCJ-02 已正确转回 WGS | 需要真实响应 | 抽到的地点距离与地图 App 大体一致（偏差应在几十米内，不是几百米） |
| 迷雾路径 Canvas 绘制 | 需要渲染 | 旅程页看到琥珀色前方路径 + 灰褐已走段 + 两端渐隐 + 指北针 |
| 剩余 < 60m 隐藏整段 | 需要走完一段 | 接近终点时路径消失，只剩「就在附近 · 抬头看看周围」 |
| 账号 Cookie 持久化 | 需要 `@ohos.net.http` 真实响应头 | 登录后杀进程重开，仍是登录态 |
| 图鉴「附近的惊喜」三张卡 | 需要渲染 | 统计条下面出现 3 张卡（🐱/🎧/🌙），点任意一张进探寻页 |
| 探寻页线索按距离解锁 | 需要真实走动 | 起点 1/3 → 走近到 180m 内 2/3 → 60m 内 3/3 |
| 账号 CORS/地址 | 鸿蒙无 CORS，但要注意「真机不能访问 127.0.0.1」 | 把服务地址改成电脑局域网 IP（如 `http://192.168.1.5:8803`） |

### v0.10 新增、需要 DevEco 验证的 API（疆域分享卡）

| API | 位置 | 说明 |
|---|---|---|
| `componentSnapshot.get(nodeId)` | `components/TerritoryShareCard.ets` | 组件截图；若该版本要求 options 参数，改成 `getWithOptions(id, { scale: 2 })` |
| `image.createImagePacker().packing(pixelMap, opts)` | 同上 | PNG 编码；`release()` 必须调（否则泄漏） |
| `photoAccessHelper.showAssetsCreationDialog([沙盒uri], configs)` | 同上 | **收的是源文件 uri 数组**，不是 buffer；返回相册目标 uri 数组 |
| `fs.OpenMode.TRUNC` | 同上 | 覆盖写沙箱临时文件 |
| `fs.statSync(fd)` / `fs.readSync(fd, buffer)` | 同上 | 读回 PNG 字节写进相册 uri |

> 这一整条链路**任何一步失败都会提示「可以直接截屏保存」**，不会崩、不会假装保存成功。
> 真机上要确认的是：截图清晰度、相册里图片的尺寸与内容、取消授权时的表现。

### v0.11 新增、需要真机/DevEco 验证的行为

| 行为 | 本机无法验证的原因 | 真机上怎么确认 |
|---|---|---|
| 相机拍照后照片**保留 EXIF** | 需要真实相机 | 拍完照看是否提示「位置验证通过」；关闭相机位置信息后应提示去设置开启 |
| 「先拍后收」门禁 | 需要真实地点旅程 | 真实地点未拍照时点「收进图鉴」应被拦住并提示先拍照 |
| `photoGps` 持久化 | 需要真实落盘 | 拍完收进图鉴 → 杀进程重开 → 图鉴卡片仍有照片、`cardPhotoGps` 有值 |
| 演示地点跳过验证 | 需要渲染 | 演示态（内置地点无坐标）拍照后应显示「演示地点 · 照片只作纪念」，不报错 |
| `componentSnapshot` / `photoAccessHelper` 保存卡 | 需要相册权限 | 分享卡「保存到相册」能落盘；取消授权时降级为提示截屏 |

> **注意**：`core/photo-gps.ts` 是纯 TS（不 import `@ohos.*`），EXIF 解析部分已用构造的
> 真实 JPEG 字节在 Node 里跑过单测与 Web 交叉验证；未验证的只是「真机相机拍出来的照片
> 字节长什么样」这一环 —— 如果某机型写的是 HEIC，会走 `notImage` 分支（UI 会提示重拍）。

### v0.9（本轮）与 iOS 1:1 对齐的清单（2026-11-14）

产品侧把 iOS 上一轮（`10f0246`）的深水区优化全部搬到鸿蒙，逻辑层可单测、UI 层有入口：

| 能力 | 逻辑层 | UI 入口 | 三端同值 |
|---|---|---|---|
| 环境性盲盒（时段） | `core/moment.ts` | 抽盒页时段卡 + 首页 hero | 6 档文案 / 偏好 +1.45 / 避开 0.45 |
| 远程漫游（10–20 公里） | `core/parity.ts` roamRange/roamSearchRadius、`providers.roamNearby` 环带撒点 | 抽盒页「怎么去」、旅程页开车段（导航到附近 / 已停车） | 下限 10km、上限 20km（再远单程开车近一小时，抽到也不会去）；停车圈 1km；容忍 2.2km；驶离 3.5km 退回开车段 |
| 个人城市地图 | `core/track.ts`（25m 去抖 / 200m 格子 / 12000 点压缩） | 「我的」→「个人城市地图」（Canvas 手绘） | 天数 / 公里 / 街区 / 平方公里 |
| 埋惊喜回执 | `core/receipts.ts` + `core/surpriseRemote.ts` `/api/surprises/mine` | 首页惊喜社区红点 + 我的惊喜回执条 | 只同步状态与寻者名，不同步照片与正文 |
| 到达实拍 | `PlaceCard.photoName / photoRemotePath` + `/api/photos` | 揭晓页「拍一张 / 从相册选」、图鉴详情「你拍的」 | 本机优先，登录后上传，按地点覆盖 |
| 图鉴收集进度 | —（快照计算） | 图鉴「只差一张 / 还差 N 张 · 现在就走」 | 未解锁只给类别，不给地名 |
| 探寻先拍后看 | `demoSimilarity` + `completeSurpriseFind` | 探寻页「这样拍一张」→ 比对 → 结算（远端达标后认领） | 阈值 0.45；远端无原图时标注「演示匹配」 |
| 账号登录方式 | `/api/auth/providers` + 短信发码/验码 | 账号面板「手机号登录」 | 服务端未配置时如实说明缺哪些变量 |

**仍未对齐（平台差异，非遗漏）**

| 能力 | 原因 |
|---|---|
| Sign in with Apple | HarmonyOS 没有 Apple 登录能力；服务端接口保留，客户端不展示假按钮 |
| 微信登录 | 需要微信开放平台 HarmonyOS SDK（`@tencent/wechat_open_sdk`，需 AGC 登记），本机无法验证，暂不接 |
| 华为手表端 | Wearable 是独立技术栈（与 watchOS 同等工作量），见 §9 路线图 |


## 8. 立即可测的替代路径（今晚就能用）

鸿蒙浏览器（华为浏览器）内核是 Chromium，**现有 PWA 可以直接在鸿蒙手机上跑**：

1. 鸿蒙手机用「浏览器」打开 https://xiaoqiangch.github.io/walkaholic/
2. 菜单 → 添加到桌面
3. 从桌面启动，允许定位，即可体验真实街道 + 真实距离

这条路径已经把「真实地理 + 埋惊喜」全流程跑通，可以用来**先验证产品体验**，再决定原生版要不要继续深做。

---

## 9. 路线图

| 版本 | 内容 |
|---|---|
| v0.6 | 工程骨架 + 逻辑层（含测试）+ 7 个主界面 + 真实定位 |
| v0.7 | 功能对齐 Web v32：多数据源真实 POI、三档放宽、明确失败面板、迷雾路径、账号、字号 |
| v0.8 | 图鉴「附近惊喜」隐晦提示 + 探寻面板（对齐 Web v46） |
| v0.9 | 与 iOS `10f0246` 1:1 对齐：时段 / 远程漫游 / 城市地图 / 惊喜回执 / 到达实拍 / 图鉴进度 / 先拍后看 / 短信登录 |
| v0.10 | 疆域 + 爵位 + 我的城市疆域地图 + 分享卡（对齐 Web v46 / docs/territory.md） |
| **v0.11（本轮）** | **点数门槛 + 拍照 EXIF GPS 到达验证**（docs/territory.md §三 §四） |
| v0.12 | 华为账号登录（替代自建账号）、微信登录（OpenSDK）、桌面服务卡片 |
| v0.13+ | 折叠屏/平板适配（GridRow 断点）、深色模式、无障碍 |

### v0.8 图鉴「附近惊喜」（对齐 Web v46 / iOS）

图鉴页在统计条之后、筛选 chips 之前新增「附近的惊喜」区块。

**分层**：
- `core/hints.ts`（纯 TS，可单测）：`distanceBucket` / `hintForSurprise` / `nearbyHints`
  + `seekClueState` / `seekLeadText`（探寻页解锁判定）
- `views/CardsView.ets`：提示区块（最多 3 张卡 / 空状态 CTA）
- `components/SeekPanel.ets`：探寻面板（三阶线索 + 距离 + 「当作到了（演示）」）
- `pages/Index.ets`：`onOpenSeek` 注入 → 打开 SeekPanel

**保密铁律**（`NearHint` 只能由三类东西组成）：
1. 固定文案（7 档距离 + 7 条氛围池）
2. 作者 emoji（三端唯一允许的社交信息）
3. 一个**取整后的距离**（只用于选分档，不直接出现在文案里）

**绝不能**出现：`areaWord`（区域名会缩小范围）、`hints`（作者提示，要走近才解锁）、
`photoUri` / `photoHash`（照片 = 答案）、`location` 坐标、`authorName`（谁埋的）。

三道防线守护这条铁律：

| 防线 | 位置 | 作用 |
|---|---|---|
| 类型 | `NearHint` 接口只有 5 个字段 | 结构上就没有地方放剧透字段 |
| 单测 | `npm test` 的「保密（铁律）」5 项 | 断言序列化后的 JSON 不含任何剧透串 |
| 静态检查 | `check-arkts.mjs` 的「附近惊喜保密」 | UI 一旦直接读 `.areaWord` / `.photoUri` / `.authorName` 就报错 |

三处都做了**变异测试**验证真的会红（往 NearHint 里加 areaWord、往 CardsView 里读 areaWord）。

**线索解锁规则**（与 Web `seekDetailHTML` 一致）：
- 起点即第 1 条（`makeClues()` 保证第 1 条是通用句，不含作者提示）
- `≤ 3×半径`（默认 180m）解锁第 2 条
- `≤ 半径`（默认 60m）解锁第 3 条 → 进入「这样拍一张」
- 点「当作到了（演示）」全解锁，但 UI 必须标注「演示」（`demoArrived` 字段）
- 没定位 → 只有第 1 条 + 明确提示「拿不到定位，线索暂时解锁不了」（**不假装解锁**）

### v0.7 联调实测发现并修掉的问题（真实网络，不是纸面推演）

用真实的高德 Key + 公网维基跑了 `nearby` / `findRealPlace`，抓出 4 个真 bug：

| # | 问题 | 现象 | 修法 |
|---|---|---|---|
| 1 | **维基 / Overpass 缺 User-Agent** | 直连返回 403 / 406（浏览器会自动带 UA，原生 HTTP 客户端不会）→ 免费源全挂 | `core/providers.ts` 导出 `USER_AGENT`，所有 GET/POST 显式带上；`geocode.ts` / `route.ts` / `search.ts` / `mapkeys.ts` 同改 |
| 2 | **地标关键字整串传给高德** | `keywords=公园\|风景名胜\|…` 返回 `status=1` 但 `count=0`（**静默空结果**，最阴的一个） | `parity.landmarkKeywordList()` 拆成单词逐个查，只查前 `LANDMARK_KEYWORD_LIMIT=3` 个（兼顾高德 QPS） |
| 3 | **类别判定顺序错** | 「国际饭店」因简介提到「人民公园」被判成 `park`；维基条目尤其严重 | `mapCategory()` 改为**名称优先、原始类别兜底**；维基改用 `categoryFromWikiTitle()`（只信标题） |
| 4 | **去重时跨 POI 借类别** | 30m 内的餐厅把隔壁寺庙的 `temple` 借走（「鲜得来 → 寺庙」） | `mergeMissing()` 只在**同名**时互补类别；照片/地址这类客观属性仍可互补 |
| 5 | **rawfile 逐字节解码** | `String.fromCharCode` 把 UTF-8 中文解成乱码 → `JSON.parse` 失败 | `util.TextDecoder.create('utf-8')`（`components/HttpClient.ets`） |

> 修完后实测：高德 95 条 + 维基 7 条 → 去重后 40 条候选，抽到的是「上海博物馆 / 延福绿地 / 人民广场」这类**真的值得走过去**的地方，不再是楼下的餐厅。

#### 本机网络环境的已知限制

- **Overpass 三个镜像从本机全部超时**（`overpass-api.de` / `kumi` / `private.coffee`）。
  Web 版用同样的三个端点，同样失败 → 确认是**本机网络环境**（代理/出口）问题，不是代码。
  代码侧已按 parity 实现「3 镜像 × 4.5s 超时、整体 8s」，失败只影响 OSM 一个源，不影响整体（维基 + 高德照常）。
- 维基、高德、Valhalla 从本机可正常访问（已实测 200）。

---

## 10. 目录速查

```
harmony/
├── AppScope/app.json5                应用级配置（bundleName / 版本 / 图标 / 名称）
├── build-profile.json5               构建配置（compileSdkVersion 26.0.1 / target 26.0.0）
├── hvigorfile.ts                     app 级构建脚本
├── oh-package.json5                  依赖
├── hvigorw                           命令行构建入口（优先用 ~/DevTools/deveco 工具链）
├── .sign/sign-config.json5           签名配置（华为账号自动签名会写这里）
├── entry/                            主模块
│   ├── build-profile.json5
│   ├── hvigorfile.ts
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5              模块/Ability/权限声明
│       ├── ets/                      ArkTS 源码（见 §1 结构图）
│       └── resources/                字符串/颜色/图标/页面清单
├── tests/                            Node 单元测试（逻辑层）
├── scripts/check-arkts.mjs           ArkTS 静态检查
├── docs/HARMONY.md                   本文
├── package.json                      TypeScript + 测试脚本（仅开发用）
└── tsconfig.test.json                逻辑层类型检查配置

scripts/                              仓库级脚本（与 harmony/ 同级）
├── check-harmony.sh                  离线校验（tsc + 单测 + 静态检查）
├── setup-deveco-cli.sh               部署 CLI 工具链副本
├── gen-local-sign.sh                 生成本地签名材料
├── build-hap.sh                      编译 + 签名 + 校验
└── emulator.sh                       模拟器镜像 / 实例 / 装机 / 截图
```

---

## 11. 本机开发环境（2026-11-19 部署记录）

### 版本

| 项 | 值 |
|---|---|
| IDE | DevEco Studio **26.0.1**（build DS-261.23567.138.36.2601290） |
| 安装位置 | `/Applications/DevEco-Studio.app`（11 GB，含内置 SDK） |
| SDK | HarmonyOS **26.0.1 / API 26**（Beta1，version 26.0.1.120） |
| CLI 工具链副本 | `~/DevTools/deveco`（7.1 GB，node 24.14.1 / ohpm 26.0.1.220 / hdc 3.2.0f / JBR 25.0.2） |
| 模拟器镜像 | `~/.deveco/emulator`（HarmonyOS 7.0.0 / API 26，phone） |
| 本地签名材料 | `~/.deveco/localsign`（自签 CA 链 + debug profile） |

### 一键脚本

| 脚本 | 作用 |
|---|---|
| `scripts/setup-deveco-cli.sh` | 部署可执行的 CLI 工具链副本（绕开 macOS 26 的 App Management 拦截） |
| `scripts/gen-local-sign.sh` | 生成 OpenHarmony 自签证书链 + debug profile（免华为账号） |
| `scripts/build-hap.sh` | 编译 → 签名 → 校验，`--device` 直接装机 |
| `scripts/emulator.sh` | 镜像下载 / 建实例 / 启停 / 装机 / 截图 |
| `scripts/check-harmony.sh` | 逻辑层类型检查 + 单元测试 + ArkTS 静态检查（不依赖 IDE） |

### 环境变量

```bash
export DEVECO_CLI_HOME="$HOME/DevTools/deveco"   # CLI 工具链位置（默认值）
export DEVECO_IDE_HOME="$HOME/DevTools/deveco"   # harmony/hvigorw 用，可指向 /Applications
export LOCAL_SIGN_DIR="$HOME/.deveco/localsign"  # 签名材料位置
export HARMONY_IMAGE_ROOT="$HOME/.deveco/emulator"
```

### 首次真编译结果（2026-11-19）

这是仓库里第一次跑真正的 ArkTS 编译（此前只有 tsc + 静态检查）：

```
hvigor 6.26.20 / SDK 26.0.1
:entry:default@CompileArkTS       ✅ 通过（0 error）
:entry:default@PackageHap         ✅ 通过
:entry:default@SignHap            ⚠️ 密码必须是 DevEco 加密格式 → 改用 hap-sign-tool 直签
sign-app / verify-app             ✅ Verify success
产物                              entry-default-signed.hap (2.7 MB)
```

**§7「待 DevEco 首编验证」的 8 处 API 写法全部一次编译通过**，
没有任何一处需要按文档调整签名 —— 之前刻意取「官方文档最保守写法」的策略生效了。

编译期只有 deprecated 警告，两类：

| 警告 | 位置 | 处理建议 |
|---|---|---|
| `animateTo` has been deprecated | `views/RevealView.ets:349/358/423/427` | 可换 `UIContext.animateTo`；不影响运行 |
| `getContext` has been deprecated | `pages/Index.ets:133/434` | 可换 `this.getUIContext()`；不影响运行 |

> 这两类警告**不阻塞出包**，按优先级低于功能验证，本轮未改（避免为了消警告引入回归）。

---

## 11.1 v0.10 疆域与爵位（2026-11-20）

三端统一规格：`docs/territory.md`；Web 参考实现：`prototype/web/territory.js`。

### 分层

| 层 | 文件 | 职责 |
|---|---|---|
| 逻辑 | `core/territory.ts` | 等距圆柱投影 / Andrew 单调链凸包（**叉积容差 0.5 m²**）/ 鞋带公式 / 爵位判定 / 格式化 / 真实来源提取 / 凸包↔经纬度反算 |
| 逻辑 | `core/sharecard.ts` | 分享卡 720×960 的**全部坐标与文案**（弹框只负责画） |
| UI | `views/ProfileView.ets` | 等级卡下方疆域爵位卡（印章/爵位/释义 + 地图·分享 + 三数据 + 进度 or「再开 N 个」） |
| UI | `views/CityMapView.ets` | 统计卡下方疆域卡 + **Canvas 疆域多边形**（叠在轨迹与地点之上） |
| UI | `components/TerritoryShareCard.ets` | 720×960 分享卡 Canvas + 保存到相册 |
| 路由 | `pages/Index.ets` | `OVERLAY_TERRITORY_CARD`（分享卡）；`OVERLAY_CITYMAP`（我的城市，原已有） |

### 关键算法细节（踩过的坑）

1. **共线容差 `COLLINEAR_EPS_M2 = 0.5`（单位 m²，作用在叉积上）**
   不加这个，浮点误差会让共线三点偶尔被判成左转，凸包里留下面积约 1e-12 m² 的退化细三角 ——
   面积看着对，但顶点数、跨度、画出来的形状全错。
   注意容差作用在**叉积**（= 2 × 三角形面积）上，所以能保留的最小三角形面积约 0.25 m²。
   单测用「底边 0.857m × 高 0.088m → 叉积 0.076 ≤ 0.5 → 判共线」和「高 0.586m → 叉积 0.514 > 0.5 → 保留」两侧卡住。

2. **只统计真实来源 + 有坐标的地点**
   内置演示地点（`source = 'catalog'`）没有坐标，自然被排除 → 演示态疆域恒为 0，
   爵位显示「白身」+「再开 3 个盲盒就能围出你的第一块疆域」。
   **这是「不造假」原则的直接体现，不是 bug。**

3. **凸包要能回到经纬度**
   `hullToGeoPoints()` 是 `projectMeters()` 的逆运算（相对第一个点 + 平均纬度）。
   个人地图必须走这条：先还原 WGS 经纬度，再套用和地点圆点**完全相同**的「WGS→GCJ→画布像素」投影，
   多边形才能和底图路网、地点圆点严丝合缝对齐（否则整体偏几百米）。
   单测断言往返误差 < 1 米。

4. **无疆域绝不画假多边形**
   地图页 `hullPixels.length >= 3` 才进绘制分支；分享卡 `layout.polygon.length >= 3` 才画。
   两处都有**静态检查守卫**（做变异测试确认会红）：把 `>= 3` 改成 `>= 0` 立刻报错。

5. **真实来源白名单有两份，且不该「统一」**
   `core/store.ts` 的 `isRealPlaceSource`（放行 curated/amap/baidu/osm/wiki）用于「能否开始真实旅程」；
   `core/territory.ts` 的额外放行 `wikipedia`（历史语料里的维基别名）。
   疆域统计宁可多算一个真实点，也不能少算用户的地盘。单测显式断言了这个差异。

### 新增 22 项单测（144 → 166 区间）

| 分组 | 覆盖 |
|---|---|
| 爵位表 | 8 档 key/印章/名称/门槛/色值/释义**逐字逐值**对齐 docs；门槛严格递增；未知 key 回退白身 |
| 凸包 | 正方形 1 km²（内部点/边上点被剔除）、共线面积 0、容差两侧边界、点数 <3 无凸包、逆时针且首尾不重复 |
| 非法坐标 | NaN / Infinity / 纬度 91 / 经度 181 全丢弃；全非法 → 无疆域 |
| 爵位判定 | 0/0.05/0.3/1.2/4/12/30/80 八个门槛边界值；负数/NaN → 白身；最高档 next 为空 |
| 进度 | `progress = (area-cur)/(next-cur)`；`toNextKm2`；「再扩 0.45 km² 晋 子爵」/「已是最高爵位」 |
| 格式化 | 四档（m² / 2 位 / 1 位 / 取整）+ 跨度（m / km） |
| 来源过滤 | 6 个真实来源放行、catalog/manual 排除、无坐标排除；Store 演示态 18 张卡 → 疆域 0 |
| 投影 | 以平均纬度为基准、单位为米、origin 归零 |
| 反算 | `hullToGeoPoints` 往返误差 < 1 米；空输入 |
| 分享卡 | 720×960 元素纵向有序、三等分居中、多边形不越界、无疆域 polygon 为空、`fitHullToBox` 等比+翻转+退化兜底、页脚品牌与日期补零 |

---

## 11.2 v0.11 点数门槛 + 拍照 EXIF GPS（2026-11-20）

规格：`docs/territory.md` §三「点数门槛」、§四「探索验证：拍照 + EXIF GPS」。

### A. 点数门槛（防「四个角」刷面积）

问题：凸包只看面积 → 在远处 4 个角各开一个盲盒就能围出上千 km² 直接封王。

| 爵位 | 面积门槛 | 最少点数 |
|---|---|---|
| 白身 | 0 | 0 |
| 士 | 0.05 km² | 3 |
| 男爵 | 0.3 km² | 5 |
| 子爵 | 1.2 km² | 7 |
| 伯爵 | 4 km² | 9 |
| 侯爵 | 12 km² | 12 |
| 公爵 | 30 km² | 15 |
| 王 | 80 km² | 21 |

判定（`territoryRank(areaKm2, pointCount?)`，三端一致）：

```
areaRank  = 面积够格的最高一档
current   = 从 areaRank 往下找第一个「点数也够」的档
blockedBy = areaRank（若 areaRank.order > current.order）
capped    = blockedBy !== undefined
next      = capped ? blockedBy : current 的下一档
progress  = capped ? 按点数算 : 按面积算
```

**返回结构新增** `blockedBy / capped / pointsNeeded / pointCount`。
**不传 `pointCount` 时完全保持旧行为**（capped 恒 false）—— 老调用方不会被悄悄打回。

**招牌例子**：4 点围 1163 km² → 「士」，文案
「边界够了，但只有 4 个探索点 · 再探索 17 个点才能晋 王」。

UI：`ProfileView` / `CityMapView` 的疆域卡在 `capped` 时进度文案用警示色 + 允许折 2 行 ——
**必须让玩家看懂为什么升不上去**（docs §三 UI 要求）。

### B. 拍照 + EXIF GPS 到达验证

**为什么**：手机 GPS 可伪造（开发者工具 / 模拟定位），坐着不动也能"到达"。
改成「在目的地 120 米内拍一张**照片自带 GPS** 的照片」。

**为什么自己解析 EXIF**：鸿蒙 `image.ImageSource.getImageProperty('GPSLatitude')`
在部分机型只返回字符串、格式不统一、有时直接空/抛异常。所以直接拿字节自己解析
JPEG APP1 段 —— 与 Web `prototype/web/exif.js` 同一套逻辑，行为可预测、可单测。

| 能力 | 实现 |
|---|---|
| 字节序 | `II`（小端）+ `MM`（大端）双支持 |
| 南纬/西经 | `S` / `W` 参考位 → 取负号 |
| 度分秒 | 3 个 rational 合成十进制度 |
| 判定半径 | `PHOTO_RADIUS_METERS = 120` |
| PNG | 明确 `pngNoExif`（PNG 本身不存 EXIF） |
| 截图/转发图 | `noExif` + 指引「请用手机自带相机拍新照片」 |
| 相机没开定位 | `noGpsTag` + 指引「设置 → 应用 → 相机 → 打开「记录位置信息」」 |
| 太远 | `tooFar` + 「照片拍摄点离目的地 N 米，需要在 120 米内拍摄。走近一点再拍一张。」 |
| 演示地点 | `demoSkip = true`，**跳过验证**（不因为「没有坐标」判用户失败） |

**接入点**（两处，都不是 no-op 了）：

1. `views/RevealView.ets`（收进图鉴的主入口）
   - 拍完照 → `readPhotoAsBase64()` 读**原图**字节（不能压缩后再读，canvas 重编码会丢 EXIF）
     → `checkPhotoArrival(target, base64)` → 通过才置 `verifiedArrival = true`
   - **收录门禁**：真实地点且未验证 → 拦截并提示「先拍一张照片才能收进来」
   - 通过后 `attachCardPhotoGps()` 把 `photoGps` / `photoDistance` 记到卡片
2. `components/SeekPanel.ets`（寻惊喜「这样拍一张」）
   - 取图后先做 GPS 位置验证，位置不对直接给指引，**不进入 dHash 比对**
     （照片都没拍对地方，比相似度没意义）

**数据存储**（docs §四）：`PlaceCard.photoGps: { latitude, longitude }` + `photoDistance: number`，
随卡片持久化（`core/persistence.ts` 的 `decodeCard`）。用途：事后审计 + 疆域计算
（**疆域点应优先用 photoGps 而不是手机 GPS**）。

### 新增 25 项单测（170 → 195）

| 分组 | 覆盖 |
|---|---|
| minPoints | 8 档逐值 + 严格单调 + 面积门槛同步单调 |
| 招牌例子 | 4 点围 1163 km² → 士 / capped / blockedBy=王 / pointsNeeded=17 / 文案逐字 |
| 不传点数 | 9 组面积全部保持旧行为（rank 与 capped 都不变） |
| 各档边界 | 每档「点数刚好」达标；王 20→公爵（差1）、公爵 14→侯爵、伯爵 8→子爵 |
| 进度 | capped 按点数算 / uncapped 按面积算 / 文案带「还需 N 个探索点」 |
| 异常输入 | NaN 视为未传、负数夹 0、小数不崩 |
| EXIF | 小端 + 大端解析、南纬西经负号、无 GPS 标签、无 EXIF 段、PNG、极小文件、坏字节序 |
| base64 | 与原始字节路径结果一致、`data:` 前缀、解码长度 |
| 失败文案 | 10 种 reason 都有标题+指引、标题互不相同、逐字核对 docs 表格 |
| 距离 | 120m 内/外、111m vs 133m 边界、自定义半径、haversine 南京→北京 |
| 完整链路 | 真照片坐标→通过 / 太远→失败 / 无 GPS→指引 / 演示地点→跳过 |
| 凭证持久化 | 记录后重启仍在；不存在的卡片安全返回 false |

### 与 Web 实现的交叉验证（实测跑过）

```
rankFor 交叉验证（13 面积 × 13 点数 = 169 组合）: ✅ 全部一致
不传点数（旧行为）:                              ✅ 与 web 一致
EXIF 解析（8 例：小端/大端/南纬/西经/无极值/无GPS标签）: ✅ 全部一致
距离验证（120m 内外 + 边界）:                     ✅ 全部一致
```

### 静态守卫（第 14 分区「拍照验证」，做了变异测试）

守：minPoints 8 档常量、EXIF 自解析关键代码（`sig === 'Exif'` / `II` / `MM` / `magic !== 42`）、
120m 半径、南纬西经负号、9 条失败文案逐字、**禁止依赖 `@ohos.*`**（必须纯 TS 可单测）、
**禁止使用 `getImageProperty`**、UI 三个接入点（`checkPhotoArrival` / `attachCardPhotoGps` /
`verifiedArrival` / `readPhotoAsBase64`）必须真实存在、收录门禁条件必须存在、
SeekPanel 必须真的取图 + 验证。

变异测试：把 `this.verifyArrivalPhoto()` 调用删掉 → 立刻报「拍完照后没有调用（验证没接上）」；
把 `minPoints: 21` 改成 20 → 静态检查 + 4 项单测同时红。

---

## 12. 模拟器实测记录（2026-11-19，第一次真机运行）

环境：DevEco Studio 26.0.1 + HarmonyOS 7.0.0(26.0.0) phone 模拟器（127.0.0.1:5555，UDID `454D5504…70270C06B278AA400000000000`）。

### 12.1 端到端跑通的链路

| 步骤 | 结果 | 证据 |
|---|---|---|
| hdc install 签名 HAP | ✅ `install bundle successfully` | — |
| 冷启动 | ✅ 进程存活，无崩溃 | `01-home.png` |
| 定位权限申请 | ✅ 系统弹窗正常（拒绝后走「明确失败」面板，不虚构地点） | 首屏弹窗 |
| 定位开关打开 → 单次定位 | ✅ 拿到真实坐标 | 旅程页「实时定位 · 真实坐标」 |
| 抽盒（真实网络：维基 + OSM） | ✅ 抽到 **南京鼓楼**（史诗） | `04-reveal.png` |
| 路线规划 | ✅ 1.6 公里 / 21 分钟，前方 1563 米 | `03-journey.png` |
| 迷雾路径 Canvas | ✅ 已走段/前方段/两端渐隐/指北针全部渲染 | `03-journey.png` |
| 线索保密 | ✅ 1/3 只给氛围句「会有一点旧木头和雨的味道」，无地名 | `03-journey.png` |
| 揭晓 | ✅ 真名 + Wikimedia 实图 + 简介 + 「为什么是这里」+ 小任务 | `04-reveal.png` |
| 图鉴 | ✅ 已收集 1/16，附近 15 个点只显示**类别 + 距离**（保密规则生效） | `05-cards.png` |
| 圈子 | ✅ 同频码 AAAAAA、本周榜、揭晓动态（含真实地名） | `06-social.png` |
| 我的 | ✅ 等级/里程/成就/音效/触感/地图跟随/数据源/城市地图 | `07-profile.png` |
| 持久化 | ✅ 杀进程重开，进度（0.8 km / 1 盒 / 连续 1 天）保留 | `07-profile.png` |
| 时段盲盒 | ✅ 20:00 后自动切成「夜里的盲盒 🌙」（15:00 前是「黄昏的盲盒 🌇」） | `02-setup.png` |
| 运行时异常 | ✅ 全流程 **0 致命错误**（仅模拟器自身的 QoS / Ace 主题噪声） | hilog |

### 12.2 实机测试才发现的两个问题（都已写进脚本）

**① 模拟器默认关闭定位开关**

第一次点「摇一个盲盒」拿到的是「定位超时」，`locationhub` 日志显示
`QuerySwitchStateForUser: query state failed` / `userId switch 100 is not exist`。
`param set` 没有权限，最后是通过下拉控制中心 → 「位置」打开开关解决的。
`scripts/emulator.sh` 与 `docs` 都记了这一步；新机器上第一次跑务必先打开。

**② 权限授予后必须重启 Ability 才生效**

用 `atm perm -g` 授权（或系统弹窗授权）后，已运行的 Ability 仍持有旧的拒绝状态，
必须 `aa force-stop` 再 `aa start`。`scripts/smoke-test.sh` 里已经这么做了。

### 12.3 编译告警（不阻塞，未改）

| 告警 | 位置 | 建议 |
|---|---|---|
| `animateTo` deprecated | `views/RevealView.ets:349/358/423/427` | 换 `UIContext.animateTo` |
| `getContext` deprecated | `pages/Index.ets:133/434` | 换 `this.getUIContext()` |

### 12.4 截图

`docs/screenshots/`（由 `scripts/capture-screens.sh` 生成）：

| 文件 | 内容 |
|---|---|
| `01-home.png` | 首页：夜里的盲盒、今日盲盒卡、统计、惊喜社区 |
| `02-setup.png` | 抽盒设置：盒型 / 怎么去 / 时长 / 心情 / 区域 |
| `03-journey.png` | 旅程：转向卡、迷雾路径 Canvas、距离、线索 1/3 |
| `04-reveal.png` | 揭晓：南京鼓楼、Wikimedia 实图、小任务 |
| `05-cards.png` | 图鉴：1/16、附近点（类别 + 距离，不含地名） |
| `06-social.png` | 圈子：同频码、本周榜、揭晓动态 |
| `07-profile.png` | 我的：等级、里程、成就、开关、数据源 |
