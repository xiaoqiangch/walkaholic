/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 我的 Profile（design-system §5.7）
 *
 * 视觉基准：prototype/web/app.js profileHTML + screenshots/showcase.png（PROFILE 屏）
 * 结构：我的 header → 等级卡 → **疆域爵位卡** → 我的城市/我的惊喜入口 → 成就横滚 → 设置列表 → 版本号
 *
 * ## 疆域爵位卡（对齐 Web v46 / docs/territory.md §展示要求 1）
 * - 印章圆（爵位色底 + 印章字）+ 爵位名 + 释义 + 「分享」按钮
 * - 三项数据（疆域面积 / 占领地点 / 最长跨度）+ 进度条 + 「再扩 X 晋 Y」
 * - 不足 3 个真实地点：不显示数据行，改显示「再开 N 个盲盒…」+「至少 3 个真实地点…」
 * 计算全部在 `core/territory.ts`（纯 TS，有单测）；本页只做展示。
 *
 * 契约说明：Profile 只包含 xp / streakDays / cards / achievements / weeklySurprise，
 * 所以统计用「本周惊喜值 / 收集卡片 / 连续天数」（不是 web 的累计里程/开盒数——那两个字段本期没有）。
 */

import { AppSnapshot } from '../core/contract';
import { Achievement } from '../core/types';
import {
  WaProgressBar,
  WaStatsRow,
  WaToastBar,
  StatItem
} from '../components/Common';
import { achievementsOf, emptySnapshot, readSnapshot } from '../components/StoreBridge';
import {
  MIN_POINTS_FOR_TERRITORY,
  NEED_MORE_POINTS_HINT,
  TERRITORY_RANKS,
  TerritoryRankResult,
  TerritoryStats,
  formatTerritoryArea,
  formatTerritorySpan,
  needMorePointsCopy,
  progressCopy,
  territoryFromCards,
  territoryRank
} from '../core/territory';
import { getStore, getStoreInstance } from '../core/store';
import {
  WAColor,
  WAFont,
  WASize,
  LevelInfo,
  levelInfo
} from '../theme/Theme';

@Component
export struct ProfileView {
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop winWidth: number = 400;
  @Prop winHeight: number = 800;

  onOpenAchievements: () => void = () => {
  };
  /** 由 Index 注入：打开账号面板 */
  onOpenAccount: () => void = () => {
  };
  /** 由 Index 注入：打开数据源状态面板 */
  onOpenDataSource: () => void = () => {
  };
  /** 由 Index 注入：打开「我的城市」地图 */
  onOpenCityMap: () => void = () => {
  };
  /** 由 Index 注入：打开「我的惊喜」（回执 / 我埋的 / 我找到的） */
  onOpenMySurprises: () => void = () => {
  };
  /** 由 Index 注入：打开疆域身份卡分享 */
  onShareTerritory: () => void = () => {
  };
  /** 账号状态文案（由 Index 注入，避免本页直接依赖 account.ts 的存储） */
  @Prop accountLabel: string = '未登录';
  onChanged: () => void = () => {
  };

  @State private snapshot: AppSnapshot = emptySnapshot();
  @State private soundOn: boolean = true;
  @State private hapticOn: boolean = true;
  /** 地图朝向：true=跟随我转身；false=固定北朝上（全局持久化） */
  @StorageLink('mapFollowsHeading') private mapFollowsHeading: boolean = true;
  @State private modal: string = '';
  @State private toastText: string = '';
  /** 疆域缓存（load() 时算一次，见 refreshTerritory） */
  @State private territoryPointCount: number = 0;
  @State private territoryAreaText: string = '0 m²';
  @State private territorySpanText: string = '0 m';
  @State private territoryRankTitle: string = '白身';
  @State private territoryRankDesc: string = '还没有自己的疆域';
  @State private territoryRankColor: string = '#9CA3AF';
  @State private territoryRankSeal: string = '民';
  @State private territoryRankOrder: number = 0;
  @State private territoryProgress: number = 0;
  @State private territoryProgressText: string = '';
  @State private territoryEnough: boolean = false;
  @State private territoryNeedText: string = '';
  /** 是否被点数门槛卡住（docs §三：必须告诉玩家为什么升不上去） */
  @State private territoryCapped: boolean = false;
  /** 被卡住的目标爵位名（capped 时有值） */
  @State private territoryBlockedTitle: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onRevisionChanged(propName: string): void {
    this.load();
  }

  private load(): void {
    this.snapshot = readSnapshot(this.snapshot);
    this.refreshTerritory();
  }

  private level(): LevelInfo {
    return levelInfo(this.snapshot.profile.xp);
  }

  private statsItems(): StatItem[] {
    const items: StatItem[] = [];
    const km: StatItem = {
      value: this.snapshot.totalKm.toFixed(1),
      label: '累计里程'
    };
    const boxes: StatItem = {
      value: String(this.snapshot.boxesOpened),
      label: '开盒'
    };
    const streak: StatItem = {
      value: String(this.snapshot.profile.streakDays),
      label: '连续天数'
    };
    items.push(km);
    items.push(boxes);
    items.push(streak);
    return items;
  }

  // ============================================================
  // 疆域（docs/territory.md）
  // ============================================================

  /** 已收录卡片的 placeID 列表 */
  private cardPlaceIDs(): string[] {
    const ids: string[] = [];
    for (let i = 0; i < this.snapshot.profile.cards.length; i++) {
      ids.push(this.snapshot.profile.cards[i].placeID);
    }
    return ids;
  }

  /**
   * 重算疆域并写进 @State。
   *
   * 为什么缓存：`territoryFromCards` 是 O(卡片 × 地点) 的嵌套查找，
   * 而疆域卡一次渲染要读 10+ 次数据（面积/点数/跨度/爵位/颜色/印章/进度…）。
   * 不缓存的话每帧要跑十几遍这个循环。缓存在 load() 里做一次即可。
   */
  private refreshTerritory(): void {
    const stats: TerritoryStats = territoryFromCards(this.cardPlaceIDs(), this.snapshot.places);
    const rank: TerritoryRankResult = territoryRank(stats.areaKm2, stats.pointCount);
    this.territoryPointCount = stats.pointCount;
    this.territoryAreaText = formatTerritoryArea(stats.areaKm2);
    this.territorySpanText = formatTerritorySpan(stats.spanM);
    this.territoryRankTitle = rank.rank.title;
    this.territoryRankDesc = rank.rank.desc;
    this.territoryRankColor = rank.rank.color;
    this.territoryRankSeal = rank.rank.seal;
    this.territoryRankOrder = rank.rank.order;
    this.territoryProgress = rank.progress;
    this.territoryProgressText = rank.next === undefined
      ? '已是最高爵位'
      : progressCopy(rank);
    this.territoryEnough = stats.pointCount >= MIN_POINTS_FOR_TERRITORY;
    this.territoryNeedText = needMorePointsCopy(stats.pointCount);
    // 点数门槛（docs §三）
    this.territoryCapped = rank.capped;
    this.territoryBlockedTitle = rank.next === undefined ? '' : rank.next.title;
  }

  private showToast(text: string): void {
    this.toastText = text;
    setTimeout(() => {
      this.toastText = '';
    }, 2400);
  }

  private clearDemoData(): void {
    try {
      getStore().reset(Date.now());
      this.load();
      this.onChanged();
      this.showToast('演示数据已清除');
    } catch (err) {
      this.showToast('清除失败，再试一次。');
    }
  }

  // ============================================================
  // 区块
  // ============================================================

  @Builder
  header() {
    Row() {
      Text('我的')
        .fontSize(WAFont.hero)
        .fontWeight(FontWeight.Bold)
        .fontColor(WAColor.ink)

      Blank()

      if (this.snapshot.unreadReceiptCount > 0) {
        Row({ space: 4 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(WAColor.ember)
          Text(String(this.snapshot.unreadReceiptCount))
            .fontSize(WAFont.micro)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.iconOnBrand)
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(WAColor.ember)
        .borderRadius(WASize.chipRadius)
        .margin({ right: 8 })
        .onClick(() => {
          this.onOpenMySurprises();
        })
      }

      Text(this.snapshot.profile.avatarEmoji)
        .fontSize(22)
        .textAlign(TextAlign.Center)
        .width(44)
        .height(44)
        .backgroundColor(WAColor.paper2)
        .borderRadius(22)
        .border({ width: 1, color: WAColor.line, radius: 22 })
    }
    .width('100%')
  }

  /** 我的城市（个人城市地图）入口 */
  @Builder
  cityMapRow() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.map'))
          .fontSize(WASize.iconSizeSm)
          .fontColor([WAColor.amber])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }
      .width(26)

      Column({ space: 2 }) {
        Text('个人城市地图')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink)
        Text(this.cityMapCaption())
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink3)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.onOpenCityMap();
    })
  }

  /** 城市地图副文案（与 iOS ProfileView.cityMapCaption 一致） */
  private cityMapCaption(): string {
    try {
      const stats = getStoreInstance().track().stats();
      if (stats.isEmpty) return '走完第一个盲盒，这里会长出你的路';
      return String(stats.walkedDayCount) + ' 天 · ' +
        (stats.totalMeters / 1000).toFixed(1) + ' 公里 · ' +
        String(stats.exploredCellCount) + ' 个街区';
    } catch (err) {
      return '走完第一个盲盒，这里会长出你的路';
    }
  }

  /** 我的惊喜（回执 / 我埋的 / 我找到的）入口 */
  @Builder
  mySurprisesRow() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.gift_fill'))
          .fontSize(WASize.iconSizeSm)
          .fontColor([WAColor.amber])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }
      .width(26)

      Column({ space: 2 }) {
        Text('我的惊喜')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink)
        Text('我埋了 ' + String(this.snapshot.mySurprises.length) +
          ' · 被找到 ' + String(this.foundByOthersCount()) +
          ' · 我找到的 ' + String(this.snapshot.foundSurprises.length))
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.snapshot.unreadReceiptCount > 0) {
        Text('新')
          .fontSize(WAFont.micro)
          .fontWeight(FontWeight.Bold)
          .fontColor(WAColor.iconOnBrand)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor(WAColor.ember)
          .borderRadius(WASize.chipRadius)
      }

      Text('›')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink3)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.onOpenMySurprises();
    })
  }

  private foundByOthersCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.snapshot.mySurprises.length; i += 1) {
      if (this.snapshot.mySurprises[i].found) count += 1;
    }
    return count;
  }

  @Builder
  levelCard() {
    Column({ space: 12 }) {
      Row() {
        Text('散步 Lv.' + this.level().level + ' · ' + this.level().name)
          .fontSize(this.winWidth >= WASize.wideBreakpoint ? WAFont.title : 20)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
          .maxLines(1)
        Blank()
      }
      .width('100%')

      Column({ space: 6 }) {
        WaProgressBar({
          progress: this.level().progress,
          barColor: WAColor.amber,
          trackColor: WAColor.line,
          barHeight: 8
        })

        Row() {
          Text(this.level().into + ' / 800')
            .fontSize(WAFont.micro)
            .fontColor(WAColor.ink3)
          Blank()
          Text('距离下一级 ' + (800 - this.level().into))
            .fontSize(WAFont.micro)
            .fontColor(WAColor.ink3)
        }
        .width('100%')
      }
      .width('100%')

      WaStatsRow({ items: this.statsItems(), roomy: true })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .shadow({ radius: 16, color: WAColor.shadowSoft, offsetX: 0, offsetY: 10 })
  }

  /**
   * 疆域爵位卡（docs/territory.md §展示要求 1）
   *
   * 两种形态：
   * - 够 3 个真实地点 → 三项数据 + 进度条 + 「再扩 X 晋 Y」
   * - 不足 3 个 → 只给引导文案，**不显示 0 面积的数据行**（避免「我有 0 m² 疆域」的怪观感）
   */
  @Builder
  territoryCard() {
    Column({ space: 12 }) {
      // 头：印章 + 爵位名/释义 + 地图·分享
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(this.winWidth >= WASize.wideBreakpoint ? 56 : 52)
            .height(this.winWidth >= WASize.wideBreakpoint ? 56 : 52)
            .fill(this.territoryRankColor)

          Text(this.territoryRankSeal)
            .fontSize(this.winWidth >= WASize.wideBreakpoint ? 26 : 24)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.iconOnBrand)
        }

        Column({ space: 3 }) {
          Text(this.territoryRankTitle)
            .fontSize(WAFont.titleSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
            .maxLines(1)

          Text(this.territoryRankDesc)
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ink2)
            .maxLines(2)
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 地图 + 分享（对齐 Web territory__actions 的两个按钮）
        Row({ space: 6 }) {
          Button() {
            Text('地图')
              .fontSize(WAFont.microSm)
              .fontWeight(FontWeight.Medium)
              .fontColor(WAColor.ink2)
          }
          .type(ButtonType.Capsule)
          .height(30)
          .padding({ left: 12, right: 12 })
          .backgroundColor(WAColor.paper2)
          .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
          .onClick(() => {
            this.onOpenCityMap();
          })

          if (this.territoryEnough) {
            Button() {
              Text('分享')
                .fontSize(WAFont.microSm)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.territoryRankColor)
            }
            .type(ButtonType.Capsule)
            .height(30)
            .padding({ left: 12, right: 12 })
            .backgroundColor(WAColor.paper2)
            .border({ width: 1, color: this.territoryRankColor, radius: WASize.chipRadius })
            .onClick(() => {
              this.onShareTerritory();
            })
          }
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.territoryEnough) {
        // 三项数据
        Row() {
          this.territoryMetric(this.territoryAreaText, '疆域面积')
          Divider().vertical(true).height(26).strokeWidth(1).color(WAColor.line)
          this.territoryMetric(String(this.territoryPointCount), '占领地点')
          Divider().vertical(true).height(26).strokeWidth(1).color(WAColor.line)
          this.territoryMetric(this.territorySpanText, '最长跨度')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 进度条（用爵位色）
        Column({ space: 6 }) {
          WaProgressBar({
            progress: this.territoryProgress,
            barColor: this.territoryRankColor,
            trackColor: WAColor.line,
            barHeight: 6
          })

          Row() {
            // 被点数卡住时文案较长（「边界够了，但只有 N 个探索点 · 再探索 M 个点才能晋 X」），
            // 允许折 2 行并用警示色 —— 必须让玩家看懂为什么升不上去（docs §三 UI 要求）
            Text(this.territoryProgressText)
              .fontSize(WAFont.microSm)
              .fontColor(this.territoryCapped ? WAColor.ember : WAColor.ink2)
              .lineHeight(15)
              .maxLines(this.territoryCapped ? 2 : 1)
              .layoutWeight(1)
            Text('Lv.' + String(this.territoryRankOrder + 1) + ' · ' +
              String(TERRITORY_RANKS.length))
              .fontSize(WAFont.microSm)
              .fontColor(WAColor.ink3)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
      } else {
        // 不足 3 个真实地点：只给引导，**不显示 0 面积的数据行**
        Column({ space: 4 }) {
          Text(this.territoryNeedText)
            .fontSize(WAFont.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
            .width('100%')

          Text(NEED_MORE_POINTS_HINT)
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ink3)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .shadow({ radius: 12, color: WAColor.shadowSoft, offsetX: 0, offsetY: 6 })
  }

  /** 疆域数据行里的一个指标（内联，不复用 WaStatsRow：那个自带白底卡片会双重描边） */
  @Builder
  territoryMetric(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(WAFont.titleSm)
        .fontWeight(FontWeight.Bold)
        .fontColor(WAColor.ink)
        .maxLines(1)
      Text(label)
        .fontSize(WAFont.micro)
        .fontColor(WAColor.ink3)
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  achievementBadge(achievement: Achievement) {
    Column({ space: 6 }) {
      Text(achievement.icon)
        .fontSize(22)
        .textAlign(TextAlign.Center)
        .width(48)
        .height(48)
        .backgroundColor(achievement.unlockedAt !== undefined ? WAColor.amberSoftStrong : WAColor.paper2)
        .borderRadius(WASize.cardRadius)
        .border({
          width: 1,
          color: achievement.unlockedAt !== undefined ? WAColor.amberBorder : WAColor.line,
          radius: 24
        })
        .opacity(achievement.unlockedAt !== undefined ? 1 : 0.55)

      Text(achievement.name)
        .fontSize(WAFont.microSm)
        .fontColor(achievement.unlockedAt !== undefined ? WAColor.ink2 : WAColor.ink3)
        .maxLines(1)
        .width(64)
        .textAlign(TextAlign.Center)
    }
    .width(64)
    .onClick(() => {
      this.onOpenAchievements();
    })
  }

  @Builder
  achievementStrip() {
    Column({ space: 12 }) {
      Row() {
        Text('成就')
          .fontSize(WAFont.titleMd)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
        Blank()
        Row({ space: 2 }) {
          Text('全部成就')
            .fontSize(WAFont.captionSm)
            .fontColor(WAColor.amberDeep)
          Text('›')
            .fontSize(WAFont.caption)
            .fontColor(WAColor.amberDeep)
        }
        .onClick(() => {
          this.onOpenAchievements();
        })
      }
      .width('100%')

      Scroll() {
        Row({ space: 12 }) {
          ForEach(achievementsOf(this.snapshot), (achievement: Achievement) => {
            this.achievementBadge(achievement)
          }, (achievement: Achievement) => achievement.id)
        }
        .padding({ top: 2, bottom: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  settingRow(title: string, danger: boolean) {
    Row({ space: 12 }) {
      Text(title)
        .fontSize(WAFont.bodySm)
        .fontColor(danger ? WAColor.ember : WAColor.ink)
      Blank()
      Text('›')
        .fontSize(WAFont.caption)
        .fontColor(danger ? '#99D25C3A' : WAColor.ink3)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      if (title === '隐私与安全') {
        this.modal = 'privacy';
      } else if (title === '关于') {
        this.modal = 'about';
      } else if (title === '清除演示数据') {
        this.clearDemoData();
      }
    })
  }

  /** 账号卡片：放在等级卡下方，显眼位置（与 Web v43 一致） */
  @Builder
  accountCard() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.' + (this.accountLabel === '未登录' ? 'info_circle' : 'person')))
          .fontSize(WASize.iconSizeSm)
          .fontColor([WAColor.amber])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }
      .width(38)
      .height(38)
      .backgroundColor(WAColor.amberSoft)
      .borderRadius(12)

      Column({ space: 2 }) {
        Text(this.accountLabel === '未登录' ? '登录 / 注册账号' : '已登录 · ' + this.accountLabel)
          .fontSize(WAFont.bodySm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
        Text(this.accountLabel === '未登录' ? '把卡片和进度存到云端，换手机也不丢（可选）' : '进度已可跨设备同步 · 点这里管理')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink3)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor('#F2EEF1FF')
    .borderRadius(16)
    .border({ width: 1, color: WAColor.line })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onOpenAccount();
    })
  }

  @Builder
  settingsCard() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Text('音效')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.soundOn })
          .selectedColor(WAColor.amberDeep)
          .onChange((isOn: boolean) => {
            this.soundOn = isOn;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 9, bottom: 9 })

      Divider().strokeWidth(1).color(WAColor.line)

      Row({ space: 12 }) {
        Text('触感')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.hapticOn })
          .selectedColor(WAColor.amberDeep)
          .onChange((isOn: boolean) => {
            this.hapticOn = isOn;
          })
      }

      Divider().strokeWidth(1).color(WAColor.line)

      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('地图跟随我转身')
            .fontSize(WAFont.bodySm)
            .fontColor(WAColor.ink)
          Text(this.mapFollowsHeading ? '开 · 转身地图会转' : '关 · 地图固定北朝上')
            .fontSize(WAFont.micro)
            .fontColor(WAColor.ink3)
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Toggle({ type: ToggleType.Switch, isOn: this.mapFollowsHeading })
          .selectedColor(WAColor.amberDeep)
          .onChange((isOn: boolean) => {
            this.mapFollowsHeading = isOn;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 9, bottom: 9 })

      Divider().strokeWidth(1).color(WAColor.line)

      // 数据源（parity.md §1：Key 后台统一下发，这里只展示状态）
      Row({ space: 12 }) {
        Text('数据源')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink)
        Blank()
        Text('高德 / 百度 / OSM / 维基')
          .fontSize(WAFont.captionSm)
          .fontColor(WAColor.ink3)
        Text('›')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink3)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.onOpenDataSource();
      })

      Divider().strokeWidth(1).color(WAColor.line)

      this.cityMapRow()

      Divider().strokeWidth(1).color(WAColor.line)

      this.mySurprisesRow()

      Divider().strokeWidth(1).color(WAColor.line)

      this.settingRow('隐私与安全', false)

      Divider().strokeWidth(1).color(WAColor.line)

      this.settingRow('清除演示数据', true)

      Divider().strokeWidth(1).color(WAColor.line)

      this.settingRow('关于', false)
    }
    .width('100%')
    .backgroundColor(WAColor.paperTranslucent)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
  }

  @Builder
  modalOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WAColor.scrim)
        .onClick(() => {
          this.modal = '';
        })

      Column({ space: 12 }) {
        Text(this.modal === 'privacy' ? '隐私与安全' : '关于步迷')
          .fontSize(WAFont.titleMd)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
          .width('100%')

        Text(this.modal === 'privacy'
          ? '位置只在本地判断距离，不上传；照片与卡片都留在你的手机里。目的地在你到达前不会显示。'
          : '步迷 Walkaholic 0.3 · 原型\n不看见终点，才看得见路。')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
          .lineHeight(22)
          .width('100%')

        Button() {
          Text('知道了')
            .fontSize(WAFont.caption)
            .fontColor(WAColor.ink)
        }
        .type(ButtonType.Capsule)
        .height(40)
        .width('100%')
        .backgroundColor(WAColor.amber)
        .onClick(() => {
          this.modal = '';
        })
      }
      .width('100%')
      .padding(20)
      .backgroundColor(WAColor.paper)
      .borderRadius(WASize.cardRadius)
      .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
      .shadow({ radius: 24, color: WAColor.shadowLift, offsetX: 0, offsetY: 16 })
    }
    .width('100%')
    .height('100%')
  }

  private isWide(): boolean {
    return this.winWidth >= WASize.wideBreakpoint;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WAColor.cream)

      Scroll() {
        Column({ space: 0 }) {
          this.header()

          if (this.isWide()) {
            // 折叠屏展开态：左（等级 + 账号）/ 右（成就 + 设置）
            Row({ space: 20 }) {
              Column({ space: 0 }) {
                this.levelCard()

                Column() {
                  this.territoryCard()
                }
                .margin({ top: 12 })

                Column() {
                  this.accountCard()
                }
                .margin({ top: 14 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: 0 }) {
                this.achievementStrip()

                Column() {
                  this.settingsCard()
                }
                .margin({ top: 18 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ top: 16 })
          } else {
            Column({ space: 0 }) {
              Column() {
                this.levelCard()
              }
              .margin({ top: 16 })

              Column() {
                this.territoryCard()
              }
              .margin({ top: 12 })

              Column() {
                this.accountCard()
              }
              .margin({ top: 14 })

              Column() {
                this.achievementStrip()
              }
              .margin({ top: 18 })

              Column() {
                this.settingsCard()
              }
              .margin({ top: 18 })
            }
            .width('100%')
          }

          Text('步迷 Walkaholic · 原型')
            .fontSize(WAFont.captionSm)
            .fontColor(WAColor.ink3)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 22, bottom: 12 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.isWide() ? '100%' : WASize.contentMaxWidth })
        .padding({
          left: WASize.pagePadding,
          right: WASize.pagePadding,
          top: 8,
          bottom: 20
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      if (this.toastText.length > 0) {
        Column() {
          WaToastBar({ text: this.toastText, iconName: 'heart_fill' })
        }
        .width('100%')
        .height('100%')
        .padding({ bottom: 44 })
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.modal.length > 0) {
        this.modalOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
