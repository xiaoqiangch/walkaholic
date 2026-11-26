/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 今日 Home（design-system §5.1）
 *
 * 视觉基准：prototype/web/app.js homeHTML + screenshots/showcase.png
 * 结构：顶栏 → 大头文案 → 今晚的盲盒主卡 → 统计 → 好友在走 → 上一次的惊喜 → 惊喜社区入口
 *
 * 宽屏（折叠屏展开态 / 平板，≥600vp）走双列 + 内容限宽 620vp（docs/foldable.md）。
 * 保密规则：本页不读取 currentPlace.name；「上一次的惊喜」只用已收录（已揭晓）卡片的地点名。
 */

import { promptAction } from '@kit.ArkUI';
import { AppSnapshot } from '../core/contract';
import { Place, PlaceCard, QuestSession, ExploreScope, WalkDuration } from '../core/types';
import {
  WaAvatar,
  WaMicroLabel,
  WaPrimaryButton,
  WaStatsRow,
  StatItem
} from '../components/Common';
import { WaBoxArt } from '../components/BoxArt';
import { categorySymbol } from '../components/WaSymbol';
import {
  activeSession,
  emptySnapshot,
  explorableSurpriseCount,
  latestCard,
  mySurpriseCount,
  myFoundSurpriseCount,
  placeOf,
  readSnapshot
} from '../components/StoreBridge';
import { WAColor, WAFont, WASize } from '../theme/Theme';
import { greeting, kilometers, relativeDay } from '../components/Format';
import { currentMoment, momentBoxTitle, momentEmoji, momentLine } from '../core/moment';
import { DirectionDial } from '../components/DirectionDial';
import { CompassWatcher } from '../components/Location';
import { placeByID } from '../core/catalog';

class FriendInfo {
  name: string;
  emoji: string;
  online: boolean;

  constructor(name: string, emoji: string, online: boolean) {
    this.name = name;
    this.emoji = emoji;
    this.online = online;
  }
}


@Component
export struct HomeView {
  /** Index 每次状态变化后 +1，本页收到后重读 snapshot */
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop winWidth: number = 400;
  @Prop winHeight: number = 800;

  onOpenSetup: () => void = () => {
  };
  /** 罗盘方向探索：bearing 0=北 90=东 180=南 270=西 */
  onExploreDirection: (bearing: number) => void = () => {
  };

  /** 手机朝向（度，0=北顺时针）；-1 = 罗盘不可用 */
  @State private compassHeading: number = -1;
  /** 罗盘传感器起不来时置 true（不阻塞界面，只是不转） */
  @State private compassFailed: boolean = false;
  private compass: CompassWatcher | undefined = undefined;
  /** 罗盘中心：在当前位置埋一个盲盒 */
  onBuryHere: () => void = () => {
  };
  /** 打开埋惊喜面板（首页「埋下一个」） */
  onOpenBury: () => void = () => {
  };
  /** 打开「我的惊喜」（回执 / 我埋的 / 我找到的） */
  onOpenMySurprises: () => void = () => {
  };
  /** 打开探寻面板（从图鉴的「附近的惊喜」进） */
  onOpenSeek: (surpriseID: string) => void = () => {
  };
  onOpenJourney: () => void = () => {
  };
  onOpenCards: () => void = () => {
  };

  @State private snapshot: AppSnapshot = emptySnapshot();

  aboutToAppear(): void {
    this.load();
    this.startCompass();
  }

  onRevisionChanged(propName: string): void {
    this.load();
  }

  private load(): void {
    this.snapshot = readSnapshot(this.snapshot);
  }

  /**
   * 起罗盘：让首页方向盘跟着手机转，「北」始终指向真实北方。
   * 传感器失败不阻塞首页 —— 罗盘退化成固定朝北的静态方向盘。
   */
  private startCompass(): void {
    if (this.compass !== undefined) return;
    const watcher: CompassWatcher = new CompassWatcher((heading: number) => {
      this.compassHeading = heading;
    });
    if (watcher.start()) {
      this.compass = watcher;
    } else {
      this.compassFailed = true;
    }
  }

  private stopCompass(): void {
    if (this.compass !== undefined) {
      this.compass.stop();
      this.compass = undefined;
    }
  }

  aboutToDisappear(): void {
    this.stopCompass();
  }

  private isWide(): boolean {
    return this.winWidth >= WASize.wideBreakpoint;
  }

  /** 罗盘直径：短屏缩小，宽屏略大，保持视觉重心 */
  private dialSize(): number {
    if (this.isShort()) return 210;
    if (this.winWidth >= WASize.wideBreakpoint) return 268;
    return 244;
  }

  private isShort(): boolean {
    return this.winHeight < WASize.shortHeightBreakpoint;
  }

  private sessionRemaining(): number {
    const session: QuestSession | undefined = activeSession(this.snapshot);
    if (session === undefined) {
      return 0;
    }
    return session.remainingMeters;
  }

  private hasActiveSession(): boolean {
    return activeSession(this.snapshot) !== undefined;
  }

  private hasLastSurprise(): boolean {
    const card: PlaceCard | undefined = latestCard(this.snapshot.profile);
    if (card === undefined) {
      return false;
    }
    return placeOf(this.snapshot, card.placeID) !== undefined;
  }

  private latestSymbol(): string {
    const card: PlaceCard | undefined = latestCard(this.snapshot.profile);
    if (card === undefined) {
      return 'pin';
    }
    const place: Place | undefined = placeOf(this.snapshot, card.placeID);
    return place === undefined ? 'pin' : categorySymbol(place.category);
  }

  private latestName(): string {
    const card: PlaceCard | undefined = latestCard(this.snapshot.profile);
    if (card === undefined) {
      return '一张回忆卡';
    }
    const place: Place | undefined = placeOf(this.snapshot, card.placeID);
    return place === undefined ? '一张回忆卡' : place.name;
  }

  private latestDayText(): string {
    const card: PlaceCard | undefined = latestCard(this.snapshot.profile);
    return card === undefined ? '' : relativeDay(card.collectedAt);
  }

  private selectedDurationMinutes(): number {
    return this.snapshot.selectedDuration === WalkDuration.M15
      ? 15
      : (this.snapshot.selectedDuration === WalkDuration.M60 ? 60 : 30);
  }

  private durationRadiusMeters(): number {
    const duration: WalkDuration = this.snapshot.selectedDuration;
    if (duration === WalkDuration.M15) {
      return 900;
    }
    if (duration === WalkDuration.M60) {
      return 3000;
    }
    return 1600;
  }

  /** 盲盒卡脚的说明：走路去 = 时长 + 半径；远程漫游 = 环带（与 iOS scopeCaption 一致） */
  private scopeCaption(): string {
    if (this.snapshot.selectedScope === ExploreScope.Roam) {
      return '10–45 公里 · 先开车再走';
    }
    return '预计 ' + this.selectedDurationMinutes() + ' 分钟 · ' +
      kilometers(this.durationRadiusMeters()) + ' 内';
  }

  private statsItems(): StatItem[] {
    const items: StatItem[] = [];
    const weekly: StatItem = {
      value: String(this.snapshot.profile.weeklySurprise),
      label: '本周惊喜值'
    };
    const cards: StatItem = {
      value: String(this.snapshot.profile.cards.length),
      label: '收集卡片'
    };
    const streak: StatItem = {
      value: String(this.snapshot.profile.streakDays),
      label: '连续天数'
    };
    items.push(weekly);
    items.push(cards);
    items.push(streak);
    return items;
  }

  /** 寻宝列表页尚未移植：只有这里还是提示 */
  private showSeekSoon(): void {
    promptAction.showToast({ message: '寻宝列表还在做，先从图鉴的「附近的惊喜」进', duration: 2400 });
  }

  /** 去寻宝：有附近的惊喜就打开第一个，否则提示去图鉴 */
  private goSeek(): void {
    const list = this.snapshot.explorableSurprises;
    if (list.length === 0) {
      promptAction.showToast({ message: '附近暂时没有别人埋的惊喜，先埋一个吧', duration: 2400 });
      return;
    }
    this.onOpenSeek(list[0].id);
  }

  // ============================================================
  // 区块
  // ============================================================

  @Builder
  topBar() {
    Row({ space: 8 }) {
      Text(greeting(this.snapshot.profile.name))
        .fontSize(WAFont.titleSm)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.ink)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 产品红线：app 内不提供也不显示任何「演示 / 虚构地点」标记。
      // （demoMode 恒为 false，这里不再保留任何演示徽标。）

      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.flame'))
          .fontSize(WAFont.captionSm)
          .fontColor([WAColor.ink2])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontSize(WAFont.captionSm)
        Text(this.snapshot.profile.streakDays + ' 天')
          .fontSize(WAFont.captionSm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .backgroundColor(WAColor.paper)
      .borderRadius(WASize.chipRadius)
      .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
    }
    .width('100%')
  }

  @Builder
  heroText() {
    Column({ space: 6 }) {
      // 环境性盲盒：时段决定文案（与 iOS HomeView.hero 一致）
      Row({ space: 5 }) {
        Text(momentEmoji(currentMoment()))
          .fontSize(WAFont.caption)
        Text(momentBoxTitle(currentMoment()))
          .fontSize(WAFont.captionSm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.amber)
      }
      .alignItems(VerticalAlign.Center)

      Text(momentLine(currentMoment()))
        .fontSize(WAFont.bodySm)
        .fontColor(WAColor.ink2)
        .lineHeight(20)
        .width('100%')

      Text('目的地抽到才知道。走过去的路上，它不显示。')
        .fontSize(WAFont.microSm)
        .fontColor(WAColor.ink3)
        .lineHeight(17)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 14, bottom: 16 })
  }

  @Builder
  resumeChip() {
    Row({ space: 3 }) {
      Text('继续 · ' + this.sessionRemaining() + ' m')
        .fontSize(WAFont.captionSm)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.ink2)
      Text('›')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink2)
    }
    .height(24)
    .padding({ left: 10, right: 10 })
    .backgroundColor(WAColor.paperHalf)
    .borderRadius(WASize.chipRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
    .onClick(() => {
      this.onOpenJourney();
    })
  }

  @Builder
  blindBoxCard() {
    Column({ space: 0 }) {
      Row({ space: 6 }) {
        WaMicroLabel({ text: '今日盲盒' })
        Blank()
        if (this.hasActiveSession()) {
          this.resumeChip()
        } else if (this.compassHeading >= 0) {
          // 罗盘已跟随：告诉用户「转手机，方向盘会转」，否则用户不知道这个特性
          Row({ space: 3 }) {
            Text('🧭')
              .fontSize(WAFont.microSm)
            Text('罗盘已跟随手机')
              .fontSize(WAFont.microSm)
              .fontColor(WAColor.amber)
          }
        } else if (this.compassFailed) {
          Text('罗盘不可用 · 已固定朝北')
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ink3)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 22 })

      // 方向罗盘：四个方向 + 中心「在此埋下」
      Row() {
        DirectionDial({
          dialSize: this.dialSize(),
          heading: this.compassHeading,
          headingUnavailable: this.compassFailed,
          hasActiveSession: this.hasActiveSession(),
          sessionCaption: this.hasActiveSession() ? this.sessionRemaining() + ' m' : '',
          onExploreDirection: (bearing: number) => {
            this.onExploreDirection(bearing);
          },
          onBuryHere: () => {
            this.onBuryHere();
          },
          onResume: () => {
            this.onOpenJourney();
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 14, bottom: 8 })

      Row({ space: 4 }) {
        Blank()
        Text(this.scopeCaption())
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 15, bottom: 14 })
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.inkSoft, radius: WASize.cardRadius })
    .shadow({ radius: 12, color: WAColor.shadowSoft, offsetX: 0, offsetY: 2 })
  }


  // ============================================================
  // 最近探索（首页下方，替代原来那块空白）
  // ============================================================

  /** 最近探索过的地点（按收录时间倒序，最多 8 个） */
  private recentPlaces(): Place[] {
    const cards: PlaceCard[] = this.snapshot.profile.cards;
    const sorted: PlaceCard[] = cards.slice().sort((a: PlaceCard, b: PlaceCard) => b.collectedAt - a.collectedAt);
    const out: Place[] = [];
    for (let i = 0; i < sorted.length && out.length < 8; i += 1) {
      const place: Place | undefined = placeByID(sorted[i].placeID);
      if (place === undefined) continue;
      out.push(place);
    }
    return out;
  }

  /** 本周新增卡片数（最近 7 天收录的） */
  private weeklyNewCards(): number {
    const weekAgo: number = Date.now() - 7 * 24 * 60 * 60 * 1000;
    let count: number = 0;
    const cards: PlaceCard[] = this.snapshot.profile.cards;
    for (let i = 0; i < cards.length; i += 1) {
      if (cards[i].collectedAt >= weekAgo) count += 1;
    }
    return count;
  }

  @Builder
  recentSection() {
    if (this.recentPlaces().length > 0) {
      Column({ space: 10 }) {
        Row() {
          Text('最近探索')
            .fontSize(WAFont.titleSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
          Blank()
          Text('近 7 天 +' + String(this.weeklyNewCards()))
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ink3)
        }
        .width('100%')

        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.recentPlaces(), (place: Place) => {
              Column({ space: 4 }) {
                Stack({ alignContent: Alignment.Center }) {
                  Text(place.emoji)
                    .fontSize(22)
                }
                .width(52)
                .height(52)
                .backgroundColor(WAColor.paper)
                .borderRadius(WASize.cardRadiusSm)
                .border({ width: 1, color: WAColor.lineSoft })

                Text(place.name)
                  .fontSize(WAFont.microSm)
                  .fontColor(WAColor.ink2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(60)
                  .textAlign(TextAlign.Center)
              }
              .width(60)
            }, (place: Place) => place.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(WAColor.paper)
      .borderRadius(WASize.cardRadius)
      .border({ width: 1, color: WAColor.lineSoft })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  statsRow() {
    WaStatsRow({ items: this.statsItems(), roomy: !this.isShort() })
  }

  @Builder
  lastSurpriseSection() {
    if (this.hasLastSurprise()) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.' + this.latestSymbol()))
            .fontSize(WASize.iconSize)
            .fontColor([WAColor.ink2])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(46)
        .height(56)
        .backgroundColor(WAColor.paper2)
        .borderRadius(WASize.cardRadiusXs)

        Column({ space: 2 }) {
          WaMicroLabel({ text: '上一次的惊喜' })
          Text(this.latestName())
            .fontSize(WAFont.bodySm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.latestDayText())
            .fontSize(WAFont.captionSm)
            .fontColor(WAColor.ink3)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('›')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink3)
      }
      .width('100%')
      .padding({ left: 10, right: 14, top: 10, bottom: 10 })
      .backgroundColor(WAColor.paper)
      .borderRadius(WASize.cardRadius)
      .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
      .shadow({ radius: WASize.cardRadius, color: WAColor.shadowSoft, offsetX: 0, offsetY: 8 })
      .onClick(() => {
        this.onOpenCards();
      })
    } else {
      Column({ space: 4 }) {
        Text('第一盒还没开。')
          .fontSize(WAFont.bodySm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
        Text('城市已经准备好了。')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink3)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 18, right: 18, top: 15, bottom: 15 })
      .backgroundColor(WAColor.paperHalf)
      .borderRadius(WASize.cardRadius)
      .border({ width: 1, color: WAColor.line, style: BorderStyle.Dashed, radius: WASize.cardRadius })
    }
  }

  @Builder
  surpriseHub() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        WaMicroLabel({ text: '惊喜社区' })
        Blank()
        Text('我埋了 ' + mySurpriseCount(this.snapshot) + ' · 被找到 ' +
          myFoundSurpriseCount(this.snapshot) + ' · 找到 ' + this.foundByMeCount())
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .maxLines(1)
      }
      .width('100%')

      Text('留一张照片给陌生人，或者去找到别人的。')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink2)
        .lineHeight(20)
        .width('100%')
        .margin({ top: 7 })

      Row({ space: 8 }) {
        Button() {
          Text('埋下一个')
            .fontSize(WAFont.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
        }
        .type(ButtonType.Capsule)
        .height(36)
        .layoutWeight(1)
        .backgroundColor(WAColor.amberSoftStrong)
        .border({ width: 1, color: WAColor.amberBorder, radius: WASize.chipRadius })
        .onClick(() => {
          this.onOpenBury();
        })

        Button() {
          Text(explorableSurpriseCount(this.snapshot) > 0
            ? '去寻宝 · ' + explorableSurpriseCount(this.snapshot) + ' 个在等你'
            : '去寻宝')
            .fontSize(WAFont.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .type(ButtonType.Capsule)
        .height(36)
        .layoutWeight(1)
        .backgroundColor(WAColor.paper2)
        .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
        .onClick(() => {
          this.goSeek();
        })
      }
      .width('100%')
      .margin({ top: 13 })

      Row({ space: 3 }) {
        Text('我的惊喜')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
        Text('›')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
        if (this.snapshot.unreadReceiptCount > 0) {
          Circle()
            .width(7)
            .height(7)
            .fill(WAColor.ember)
            .margin({ left: 3 })
        }
      }
      .margin({ top: 10 })
      .onClick(() => {
        this.onOpenMySurprises();
      })

      // 被找到的回执：入口上的一句话（不显示照片与正文）
      if (this.latestReceiptLine().length > 0) {
        Text(this.latestReceiptLine())
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ember)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 18, right: 18, top: 16, bottom: 15 })
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .shadow({ radius: 14, color: WAColor.shadowSoft, offsetX: 0, offsetY: 9 })
  }

  /** 我找到的别人的惊喜数量 */
  private foundByMeCount(): number {
    return this.snapshot.foundSurprises.length;
  }

  /** 最近一条未读回执的一句话（「小满 找到了你埋在那儿的照片」） */
  private latestReceiptLine(): string {
    for (let i = 0; i < this.snapshot.receipts.length; i += 1) {
      const receipt = this.snapshot.receipts[i];
      if (receipt.readAt !== undefined) continue;
      const area: string = receipt.areaLabel.length === 0 ? '那儿的' : '「' + receipt.areaLabel + '」的';
      return receipt.finderName + ' 找到了你埋在' + area + '照片';
    }
    return '';
  }

  // ============================================================
  // 布局
  // ============================================================

  @Builder
  wideContent() {
    Column({ space: 0 }) {
      this.topBar()
      this.heroText()

      Row({ space: 22 }) {
        Column({ space: 0 }) {
          this.blindBoxCard()

          Column() {
            this.lastSurpriseSection()
          }
          .margin({ top: 18 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 0 }) {
          this.statsRow()

          Column() {
            this.recentSection()
          }
          .margin({ top: 18 })

          Column() {
            this.surpriseHub()
          }
          .margin({ top: 18 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
  }

  @Builder
  narrowContent() {
    Column({ space: 0 }) {
      this.topBar()
      this.heroText()
      this.blindBoxCard()

      Column() {
        this.statsRow()
      }
      .margin({ top: 20 })

      Column() {
        this.recentSection()
      }
      .margin({ top: 22 })

      Column() {
        this.lastSurpriseSection()
      }
      .margin({ top: 20 })

      Column() {
        this.surpriseHub()
      }
      .margin({ top: 20 })
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WAColor.cream)

      Scroll() {
        Column({ space: 0 }) {
          if (this.isWide()) {
            this.wideContent()
          } else {
            this.narrowContent()
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: WASize.contentMaxWidth })
        .padding({ left: WASize.pagePadding, right: WASize.pagePadding, top: 6, bottom: 26 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }
}
