# 步迷 · 兴趣点管理后台

给「步迷」的地图 POI 与用户惊喜提供统一管理：**公开数据收集 → 大模型整理/分析 → 分类审核 → 地图 POI 导出给 App**。

```bash
bash scripts/start-admin.sh
# → http://127.0.0.1:8802/admin
```

| 文档 | 内容 |
|---|---|
| [docs/CONTRACT.md](docs/CONTRACT.md) | 数据模型 + HTTP API 契约（前后端唯一真相） |
| [docs/SETUP-LLM.md](docs/SETUP-LLM.md) | 配置大模型（DeepSeek / 火山 / 百炼 / 本地 Ollama） |

## 三块能力

| 能力 | 说明 |
|---|---|
| **收集整理** | 按坐标+半径从中文维基百科 / OpenStreetMap 抓真实地标，落成草稿 |
| **编辑处理** | 人工编辑全字段；也可让大模型改写文案、生成三阶线索、补任务 |
| **分析判断** | 大模型评估「适不适合做盲盒目的地」（可达性/安全/独特/保密），给出 verdict |
| **导出上架** | 审核通过的点导出成 `prototype/web/pois.json`，App 优先使用 |
| **统一审核** | 主列表与详情同时管理地图 POI 和用户惊喜，明确区分 `curated` / `user` 类型；各自状态、存储和删除路径互不混用 |
| **用户账号** | 直连账号库管理用户：搜索 / 停用 / 恢复 / 重置密码 / 删除账号（见 [docs/CONTRACT.md](docs/CONTRACT.md) §4.12） |

## 数据流

```
公开数据（维基 / OSM）
      ↓  POST /api/ingest
   admin/data/walkaholic.db（地图 POI 草稿）
      ↓  AI 整理 / 编辑 / 分析 + 人工审核
   status = approved
      ↓  POST /api/export
prototype/web/pois.json
      ↓
   App（PWA）启动时读取，优先于自动抓取

用户惊喜仍单独保存在账号服务的 SQLite 中，但在后台通过 `/api/admin/points` 与地图 POI 合并排序、过滤和分页；
惊喜的 `waiting / found / hidden` 状态仅在后台统一列表详情中管理，不参与地图 POI 的 AI 编辑或 App 导出。
```

## v2 新增

| 项 | 说明 |
|---|---|
| **登录** | 必须登录才能访问；`WA_ADMIN_PASSWORD` 或首次启动自动生成随机密码（见 [docs/SECURITY.md](docs/SECURITY.md)） |
| **SQLite** | 存储从 JSON 改为 `node:sqlite`（仍零 npm 依赖），启动自动迁移旧数据 |
| **安全分级** | 每条 POI 有 `safety.day / night / nightVerdict`，用于判断「夜里安不安全」；导出到 App 时一并带上 |
| **地址抓取** | 「抓取附近」默认定位南京市鼓楼区金银街16号；地址解析优先用已配置的高德 / 百度 Key，失败后回退 OpenStreetMap，失败时不会假用上海坐标 |
| **照片隐私** | 用户惊喜照片不进入统一列表响应；仅登录管理员在详情点击后，经受限照片接口按需读取 |
