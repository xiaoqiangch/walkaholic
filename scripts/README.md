# 鸿蒙本地开发环境脚本

macOS + DevEco Studio 26.0.1（HarmonyOS 26 / API 26）实测可用。
完整背景与踩坑原因见 [../harmony/docs/HARMONY.md](../harmony/docs/HARMONY.md) §3、§11、§12。

## 一次性部署

```bash
bash scripts/setup-deveco-cli.sh    # IDE 工具链复制到 ~/DevTools/deveco（CLI 可执行）
bash scripts/gen-local-sign.sh      # 生成 OpenHarmony 自签证书链 + debug profile（免华为账号）
bash scripts/emulator.sh install-image   # 下载 phone 系统镜像（约 2.3 GB）
bash scripts/emulator.sh create          # 创建模拟器实例
bash scripts/emulator.sh start           # 启动模拟器
```

> 首次启动后，**下拉控制中心把「位置」开关打开**，否则应用拿不到定位（模拟器默认关闭）。

## 日常

```bash
bash scripts/build-hap.sh           # 编译 + 签名 + 验签
bash scripts/build-hap.sh --device  # 再装到已连接的模拟器/真机
bash scripts/smoke-test.sh          # 装包 + 启动 + 查日志 + 截图
bash scripts/check-harmony.sh       # tsc + 单测 + ArkTS 静态检查 + 真编译
bash scripts/capture-screens.sh     # 巡检界面并截图到 harmony/docs/screenshots
bash scripts/emulator.sh run        # 构建 + 安装 + 启动一条龙
```

## 环境变量（都有默认值，一般不用设）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEVECO_CLI_HOME` | `~/DevTools/deveco` | CLI 工具链（node / hvigor / ohpm / hdc / jbr） |
| `DEVECO_IDE_HOME` | 同上 | `harmony/hvigorw` 用；可指向 `/Applications/DevEco-Studio.app/Contents` |
| `LOCAL_SIGN_DIR` | `~/.deveco/localsign` | 本地签名材料 |
| `DEVICE_UDID` | 空 | 生成 profile 时绑定的设备 UDID（debug profile 校验用） |
| `HARMONY_IMAGE_ROOT` | `~/.deveco/emulator` | 模拟器镜像 |
| `HARMONY_INSTANCE_ROOT` | `~/.deveco/emulator/instances` | 模拟器实例 |

## 关键约束

- **CLI 不能直接从 `.app` 包里跑**：macOS 26 的 App Management 会拦截，进程卡在 dyld。所以有 `setup-deveco-cli.sh`。
- **本地签名不能上架**：只能模拟器/自签设备调试。正式发布要在 DevEco 里登录华为账号自动签名。
- **模拟器定位要先开开关**：控制中心 → 位置。
