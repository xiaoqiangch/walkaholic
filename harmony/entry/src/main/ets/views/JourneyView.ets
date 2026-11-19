/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 旅程 Journey（design-system §5.3 + parity.md §3）
 *
 * 结构：顶栏（盲盒进行中 + 计时 + 暂停）→ **迷雾路径视图**（真实模式）
 *       → 距离 + 方位 → 三阶线索 → 底部操作
 *
 * 迷雾路径（docs/parity.md §3 / core/fog.ts）：
 * - heading-up；前方 min(260, 剩余-25)m；后方 min(140, 已走-5)m；两端 46m 渐隐
 * - 已走 #AEB8D6 / 前方 #5B6CFF；每 55m 箭头；「你」白底琥珀圈；右下指北针
 * - 剩余 < 60m 整段隐藏，只显示「就在附近 · 抬头看看周围」
 *
 * 保密规则（产品灵魂）：本页**绝不渲染 currentPlace.name**。
 * 只显示「目的地保密中 · 还有 N 米」、方位箭头、以及不含地名的三阶线索。
 *
 * 真实定位：geoLocationManager.on('locationChange') → store.updateGeoLocation(origin)；
 * 权限被拒 / 超时 / 定位关闭 → 明确提示定位不可用；**绝不降级成虚构地点**。
 */

import { common, Want } from '@kit.AbilityKit';
import { getStore, getStoreInstance } from '../core/store';
import { AppSnapshot, RouteManeuver, RoutePolyline } from '../core/contract';
import { RouteProgress, routeProgressOf } from '../core/fog';
import {
  DRIVE_RESUME_METERS,
  ExploreScope,
  GeoPoint,
  HINT_THRESHOLDS,
  PARKING_RADIUS_METERS,
  PARKING_TOLERANCE_METERS,
  Place,
  QuestEvent,
  QuestEventType,
  QuestPhase,
  QuestSession,
  isRoamJourney
} from '../core/types';
import { SeededGenerator } from '../core/engine';
import { offset as offsetPoint } from '../core/geo';
import {
  WaIconButton,
  WaMicroLabel,
  WaPrimaryButton,
  WaQuietButton
} from '../components/Common';
import { WaAbstractMap } from '../components/AbstractMap';
import { WaFogPath } from '../components/FogPath';
import { CompassWatcher, GeoWatcher } from '../components/Location';
import { waSleep } from '../components/Async';
import { activeSession, emptySnapshot, readSnapshot } from '../components/StoreBridge';
import {
  WAColor,
  WAFont,
  WASize,
  walkCopy
} from '../theme/Theme';
import {
  bearingArrow,
  chineseIndex,
  clockHHMMSS,
  compassCopy,
  demoBearingArrow
} from '../components/Format';

const CLUE_INDEXES: number[] = [0, 1, 2];

interface UpcomingManeuver {
  maneuver: RouteManeuver;
  distance: number;
}

@Component
export struct JourneyView {
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop winWidth: number = 400;
  @Prop winHeight: number = 800;

  /** 返回首页（保留旅程，首页可「继续」） */
  onBack: () => void = () => {
  };
  /** 到达：由 Index 打开揭晓全屏 */
  onArrived: () => void = () => {
  };
  /** 任何 store 状态变化后通知 Index 重读 */
  onChanged: () => void = () => {
  };
  /** 手动「已停车」后请求规划步行路线（开车段不规划；停车后才画迷雾路径） */
  onParkRequestRoute: () => void = () => {
  };

  @State private snapshot: AppSnapshot = emptySnapshot();
  @State private nowMs: number = 0;
  @State private paused: boolean = false;
  @State private pausedAccumMs: number = 0;
  @State private pauseStartedAt: number = 0;
  @State private flashOpacity: number = 0;
  @State private arrivalHandled: boolean = false;
  @State private watchFailed: boolean = false;
  @State private fogCaption: string = '正在规划路径…';
  @State private fixLat: number = 0;
  @State private fixLon: number = 0;
  /** 用户手动确认「已停车」：GPS 在停车场里经常漂几百米，不能只靠距离自动切换 */
  @State private parkedOverride: boolean = false;
  /** 还离很远就点「已停车」→ 先确认一次 */
  @State private confirmParkedFar: boolean = false;

  private timerId: number = -1;
  private watcher: GeoWatcher | undefined = undefined;
  private compass: CompassWatcher | undefined = undefined;
  /** 上次看到的会话 id（换了一趟旅程要清掉「已停车」标记） */
  private lastSessionID: string = '';
  @State private heading: number = -1;
  @StorageLink('mapFollowsHeading') private mapFollowsHeading: boolean = true;
  @State private compassHeading: number = -1;

  aboutToAppear(): void {
    this.load();
    this.nowMs = Date.now();
    this.timerId = setInterval(() => {
      this.nowMs = Date.now();
    }, 1000);

    const origin: GeoPoint | undefined = this.snapshot.lastKnownOrigin;
    if (origin !== undefined) {
      this.fixLat = origin.latitude;
      this.fixLon = origin.longitude;
    }

    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return;
    }
    if (session.phase === QuestPhase.Walking && !this.snapshot.demoMode) {
      this.startTracking();
    }
    if (session.phase === QuestPhase.Arrived) {
      this.beginArrival();
    }
  }

  aboutToDisappear(): void {
    this.stopCompass();
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.watcher !== undefined) {
      this.watcher.stop();
      this.watcher = undefined;
    }
  }

  onRevisionChanged(propName: string): void {
    this.load();
  }

  private load(): void {
    this.snapshot = readSnapshot(this.snapshot);
    // 换了另一趟旅程：手动停车标记不应该带过去（与 iOS onChange(of: session?.id) 一致）
    const session: QuestSession | undefined = this.session();
    const currentID: string = session === undefined ? '' : session.id;
    if (this.lastSessionID.length > 0 && currentID !== this.lastSessionID) {
      this.parkedOverride = false;
      this.confirmParkedFar = false;
    }
    this.lastSessionID = currentID;
  }

  private session(): QuestSession | undefined {
    return activeSession(this.snapshot);
  }

  private place(): Place | undefined {
    return this.snapshot.currentPlace;
  }

  private isRealMode(): boolean {
    return !this.snapshot.demoMode;
  }

  private isShort(): boolean {
    return this.winHeight < WASize.shortHeightBreakpoint;
  }

  private mapHeight(): number {
    // 转向横幅（约 76vp）只在有导航进度时出现，预算要一起扣掉，
    // 否则一屏放不下「地图 + 距离 + 第一条线索」，用户会以为线索被按钮盖住了。
    const banner: number = this.hasNavigationProgress() ? 76 : 0;
    if (this.isShort()) {
      return 190;
    }
    if (this.winWidth >= WASize.wideBreakpoint) {
      return 340;
    }
    const budget: number = this.winHeight - 60 - 34 - 190 - banner - 104 - 118 - 60;
    return Math.min(300, Math.max(190, budget));
  }

  private elapsedSeconds(): number {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return 0;
    }
    const now: number = this.nowMs > 0 ? this.nowMs : Date.now();
    const pausedNow: number = this.paused ? Math.max(0, now - this.pauseStartedAt) : 0;
    const elapsedMs: number = now - session.startedAt - this.pausedAccumMs - pausedNow;
    return Math.max(0, elapsedMs / 1000);
  }

  private progressValue(): number {
    const session: QuestSession | undefined = this.session();
    if (session === undefined || session.totalMeters <= 0) {
      return 0;
    }
    const walked: number = session.totalMeters - session.remainingMeters;
    return Math.max(0, Math.min(1, walked / session.totalMeters));
  }

  // ============================================================
  // 真实定位
  // ============================================================

  private startTracking(): void {
    if (this.watcher !== undefined) {
      return;
    }
    const watcher: GeoWatcher = new GeoWatcher((point: GeoPoint) => {
      this.onGeoPoint(point);
    });
    const started: boolean = watcher.start();
    if (!started) {
      // 定位不可用：**不再降级成虚构地点**，只标注失败，让用户去处理权限/GPS
      this.watchFailed = true;
      this.onChanged();
      this.load();
      return;
    }
    this.watcher = watcher;
    this.watchFailed = false;
    this.startCompass();
  }

  /** 罗盘：让迷雾路径跟随「你面朝的方向」转，而不是只按路线方向 */
  private startCompass(): void {
    if (this.compass !== undefined) {
      return;
    }
    const compass: CompassWatcher = new CompassWatcher((heading: number) => {
      this.compassHeading = heading;
      this.heading = heading;
    });
    if (compass.start()) {
      this.compass = compass;
    }
  }

  private stopCompass(): void {
    if (this.compass !== undefined) {
      this.compass.stop();
      this.compass = undefined;
    }
  }

  private onGeoPoint(point: GeoPoint): void {
    this.fixLat = point.latitude;
    this.fixLon = point.longitude;
    // 没罗盘（或罗盘还没就绪）时，用移动方向让地图跟着转
    if (this.compassHeading < 0 && this.watcher !== undefined) {
      const move = this.watcher.heading();
      if (move >= 0) {
        this.heading = move;
      }
    }
    const store = getStore();
    store.setLastKnownOrigin(point);
    // 个人城市地图的轨迹：只在步行段记（开车段记进去，城市地图就成了行车记录）
    if (!this.isDriveSegment()) {
      try {
        getStoreInstance().track().append(point, Date.now());
      } catch (err) {
        // 轨迹失败不影响导航
      }
    }
    const events: QuestEvent[] = store.updateGeoLocation(point);
    this.load();
    this.onChanged();
    this.handleEvents(events);
  }

  // ============================================================
  // 事件 / 到达
  // ============================================================

  private handleEvents(events: QuestEvent[]): void {
    for (let i = 0; i < events.length; i++) {
      const event: QuestEvent = events[i];
      if (event.type === QuestEventType.Arrived) {
        this.beginArrival();
      }
    }
    const session: QuestSession | undefined = this.session();
    if (session !== undefined && session.phase === QuestPhase.Arrived && !this.arrivalHandled) {
      this.beginArrival();
    }
  }

  private async beginArrival(): Promise<void> {
    if (this.arrivalHandled) {
      return;
    }
    this.arrivalHandled = true;

    if (this.watcher !== undefined) {
      this.watcher.stop();
      this.watcher = undefined;
    }

    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.flashOpacity = 1;
    });
    await waSleep(900);
    animateTo({ duration: 220, curve: Curve.EaseIn }, () => {
      this.flashOpacity = 0;
    });
    await waSleep(240);
    this.onArrived();
  }

  // ============================================================
  // 交互
  // ============================================================

  private simulateWalk(): void {
    if (this.paused) {
      return;
    }
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return;
    }
    // 契约注意：updateLocation(distanceMeters) 传的是**新的剩余距离**（不是增量）
    const nextRemaining: number = Math.max(0, session.remainingMeters - 50);
    const events: QuestEvent[] = getStore().updateLocation(nextRemaining);
    this.load();
    this.onChanged();
    this.handleEvents(events);
  }

  private arriveNow(): void {
    const events: QuestEvent[] = getStore().arriveNow();
    this.load();
    this.onChanged();
    this.handleEvents(events);
  }

  private togglePause(): void {
    if (this.paused) {
      this.pausedAccumMs = this.pausedAccumMs + Math.max(0, Date.now() - this.pauseStartedAt);
      this.pauseStartedAt = 0;
      this.paused = false;
    } else {
      this.pauseStartedAt = Date.now();
      this.paused = true;
    }
  }

  // ============================================================
  // 文案
  // ============================================================

  private bearingGlyph(): string {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return '→';
    }
    if (this.isRealMode() && session.currentBearing !== undefined) {
      return bearingArrow(this.relativeBearing(session.currentBearing));
    }
    return demoBearingArrow(session.remainingMeters);
  }

  /** 地图「上方」对应的绝对方位：跟随模式 = 设备朝向；北朝上 = 0 */
  private mapUpBearing(): number {
    if (!this.mapFollowsHeading) return 0;
    return this.heading >= 0 ? this.heading : 0;
  }

  /**
   * 把绝对方位差换算成「屏幕上的角度」。
   *
   * 为什么必须换算：地图是 heading-up 的，屏幕上方 = 我面朝的方向。
   * 如果箭头直接用绝对方位（东 = →），就会出现「地图指向北、箭头指向东」的自相矛盾 ——
   * 用户看到的是两个互相打脸的指示。
   */
  private relativeBearing(absolute: number): number {
    return ((absolute - this.mapUpBearing()) % 360 + 360) % 360;
  }

  private directionCopy(): string {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return '顺着灯走，别急';
    }
    if (this.isRealMode() && session.currentBearing !== undefined) {
      return compassCopy(session.currentBearing);
    }
    const place: Place | undefined = this.place();
    if (place === undefined) {
      return '顺着灯走，别急';
    }
    return walkCopy(place.area);
  }

  private clueText(index: number): string {
    const place: Place | undefined = this.place();
    if (place !== undefined && index < place.hints.length) {
      return place.hints[index];
    }
    return '';
  }

  private isClueUnlocked(index: number): boolean {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return false;
    }
    return index < session.unlockedHintCount;
  }

  private lockedClueCopy(index: number): string {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return '到了你就知道';
    }
    if (index === session.unlockedHintCount && index < HINT_THRESHOLDS.length) {
      if (this.routeProgress() !== undefined) {
        return '靠近后解锁第' + chineseIndex(index + 1) + '条线索';
      }
      const gap: number = Math.max(0, session.remainingMeters - HINT_THRESHOLDS[index]);
      return '再走 ' + gap + ' 米，解锁第' + chineseIndex(index + 1) + '条线索';
    }
    return '到了你就知道';
  }

  private isArrived(): boolean {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return false;
    }
    return session.phase === QuestPhase.Arrived;
  }

  // ============================================================
  // 远程漫游（开车段 / 步行段）
  // ============================================================

  /** 这一趟是不是「远程漫游」：优先看会话自己记的范围，旧会话按里程兜底 */
  private isRoamQuest(): boolean {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) return false;
    if (session.scope === ExploreScope.Roam) return true;
    return isRoamJourney(session.totalMeters);
  }

  /** 已进入停车圈（目的地 1 公里内）—— 从这里开始才算真正的步行探索 */
  private inParkingZone(): boolean {
    return this.remainingMeters() <= PARKING_RADIUS_METERS;
  }

  /**
   * 漫游旅程当前处于「开车段」——开车段不给线索、不画迷雾路径。
   * 判定顺序：进了停车圈 → 步行段；手动点过「已停车」→ 步行段，
   * 但之后又把车开出去（超过 3.5 公里）→ 自动退回开车段。
   */
  private isDriveSegment(): boolean {
    if (!this.isRoamQuest()) return false;
    if (this.inParkingZone()) return false;
    if (this.parkedOverride) return this.remainingMeters() > DRIVE_RESUME_METERS;
    return true;
  }

  /** 允许手动标记「已停车」的距离上限：停车圈 1 公里 + 停车场误差 */
  private canMarkParked(): boolean {
    if (!this.isRoamQuest() || this.parkedOverride) return false;
    return this.remainingMeters() <= PARKING_TOLERANCE_METERS;
  }

  /** 距离文案：漫游里 1 公里以上一律读「X.X 公里」 */
  private distanceCopy(meters: number): string {
    if (meters >= 1000) {
      return (meters / 1000).toFixed(1) + ' 公里';
    }
    return String(Math.round(meters)) + ' 米';
  }

  /** 用户说「已停车」：只切换「段」，不动距离（不篡改 GPS，线索仍按真实距离解锁） */
  private markParked(): void {
    if (!this.canMarkParked()) {
      this.confirmParkedFar = true;
      return;
    }
    this.parkedOverride = true;
    this.load();
    this.onChanged();
    // 切到步行段后才有必要规划步行路线
    this.onParkRequestRoute();
  }

  private confirmParkedAnyway(): void {
    this.parkedOverride = true;
    this.confirmParkedFar = false;
    this.load();
    this.onChanged();
    this.onParkRequestRoute();
  }

  /** 开车段的导航点：目的地 1 公里、方向随机的落点（不泄露终点） */
  private parkingPoint(): GeoPoint | undefined {
    const session: QuestSession | undefined = this.session();
    if (session === undefined || session.target === undefined) return undefined;
    let seedText: number = 0;
    for (let i = 0; i < session.id.length; i += 1) {
      seedText = (seedText * 31 + session.id.charCodeAt(i)) % 2147483647;
    }
    const generator: SeededGenerator = new SeededGenerator(seedText);
    const bearing: number = generator.nextInt(360);
    return offsetPoint(session.target, PARKING_RADIUS_METERS * 0.9, bearing);
  }

  /** 开车段面板：只有「还有多远 / 怎么过去 / 到哪停车」，不给线索也不画路 */
  @Builder
  driveSection() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.map'))
          .fontSize(WASize.iconSizeSm)
          .fontColor([WAColor.ink])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text('远程漫游 · 先开车过去')
          .fontSize(WAFont.bodySm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
        Blank()
        Text('目的地保密')
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink3)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(this.distanceCopy(this.remainingMeters()))
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor(WAColor.ink)
        Text('到停车圈')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink2)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text('开到目的地 1 公里内找个地方停车，剩下的路再走过去。不会告诉你终点具体在哪。')
        .fontSize(WAFont.captionSm)
        .fontColor(WAColor.ink2)
        .lineHeight(19)
        .width('100%')

      if (!this.canMarkParked()) {
        Text('还有 ' + this.distanceCopy(this.remainingMeters()) +
          '，进到 2 公里内就能点「已停车」；GPS 飘了也可以手动确认。')
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink3)
          .lineHeight(17)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button() {
          Text('导航到附近')
            .fontSize(WAFont.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.iconOnBrand)
        }
        .type(ButtonType.Capsule)
        .height(40)
        .layoutWeight(1)
        .backgroundColor(WAColor.amber)
        .onClick(() => {
          this.openParkingNavigation();
        })

        Button() {
          Text('已停车')
            .fontSize(WAFont.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink2)
        }
        .type(ButtonType.Capsule)
        .height(40)
        .layoutWeight(1)
        .backgroundColor(WAColor.paper2)
        .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
        .onClick(() => {
          this.markParked();
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .margin({ left: WASize.pagePadding, right: WASize.pagePadding })
  }

  /** 用系统地图导航到「停车点」（目的地 1 公里外的随机落点，不泄露终点） */
  private openParkingNavigation(): void {
    const point: GeoPoint | undefined = this.parkingPoint();
    if (point === undefined) return;
    try {
      const context = getContext() as common.UIAbilityContext;
      if (context.startAbility !== undefined) {
        const want: Want = {
          action: 'ohos.want.action.viewData',
          entities: ['entity.system.browsable'],
          uri: 'geo:' + point.latitude.toFixed(6) + ',' + point.longitude.toFixed(6) +
            '?q=目的地附近&driving=1'
        };
        context.startAbility(want).catch(() => {
          // 没有地图应用时静默失败（不影响旅程）
        });
      }
    } catch (err) {
      // 同上
    }
  }

  /** 进停车圈后的提示条 */
  @Builder
  roamParkedBanner() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.' + (this.inParkingZone() ? 'figure_walk' : 'pin')))
        .fontSize(WAFont.caption)
        .fontColor([WAColor.teal])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(this.inParkingZone()
        ? '已进入停车圈 · 开始步行探索，线索按距离解锁'
        : '已按「已停车」处理 · 还有 ' + this.distanceCopy(this.remainingMeters()) + ' 走到停车圈')
        .fontSize(WAFont.microSm)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.teal)
        .layoutWeight(1)
        .maxLines(2)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WAColor.tealSoft)
    .borderRadius(WASize.cardRadiusSm)
  }

  /** 开车段不显示线索：给一个说明，而不是空着 */
  @Builder
  lockedCluePlaceholder() {
    Column({ space: 6 }) {
      Text('线索')
        .fontSize(WAFont.titleMd)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.ink)
      Text('进入停车圈后才会解锁。现在看线索，你也找不准。')
        .fontSize(WAFont.captionSm)
        .fontColor(WAColor.ink2)
        .lineHeight(19)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
  }

  // ============================================================
  // 区块
  // ============================================================

  @Builder
  topBar() {
    Row({ space: 10 }) {
      WaIconButton({
        name: 'chevron_left',
        onTap: () => {
          this.onBack();
        }
      })

      Column({ space: 2 }) {
        WaMicroLabel({ text: '盲盒进行中' })
        Text(clockHHMMSS(this.elapsedSeconds()))
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Button() {
        Text(this.paused ? '继续' : '暂停')
          .fontSize(WAFont.captionSm)
          .fontColor(WAColor.ink2)
      }
      .type(ButtonType.Capsule)
      .height(28)
      .padding({ left: 11, right: 11 })
      .backgroundColor(WAColor.paper2)
      .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
      .onClick(() => {
        this.togglePause();
      })
    }
    .width('100%')
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding, top: 6, bottom: 6 })
  }

  @Builder
  statusRow() {
    Row({ space: 6 }) {
      Row({ space: 4 }) {
        Circle()
          .width(6)
          .height(6)
          .fill(WAColor.teal)
        Text('实时定位 · 真实坐标')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.teal)
      }
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .backgroundColor(WAColor.tealSoft)
      .borderRadius(WASize.chipRadius)

      if (this.isRealMode()) {
        Text('GPS')
          .fontSize(WAFont.microSm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink3)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
      }

      Blank()
    }
    .width('100%')
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding, bottom: 8 })
  }

  /** 当前路线折线（真实模式才有） */
  private routePoints(): number[][] {
    const route: RoutePolyline | undefined = this.snapshot.route;
    if (route === undefined) return [];
    return route.points;
  }

  private routeDistance(): number {
    const route: RoutePolyline | undefined = this.snapshot.route;
    if (route === undefined) return 0;
    return route.distanceMeters;
  }

  private hasRoute(): boolean {
    return this.routePoints().length >= 2;
  }

  private routeProgress(): RouteProgress | undefined {
    if (!this.hasRoute() || this.fixLat === 0 && this.fixLon === 0) return undefined;
    const route: RoutePolyline | undefined = this.snapshot.route;
    if (route === undefined) return undefined;
    return routeProgressOf(route, { latitude: this.fixLat, longitude: this.fixLon });
  }

  private upcomingManeuver(progress: RouteProgress): UpcomingManeuver | undefined {
    const route: RoutePolyline | undefined = this.snapshot.route;
    if (route === undefined || route.maneuvers === undefined) return undefined;
    for (let i = 0; i < route.maneuvers.length; i += 1) {
      const maneuver: RouteManeuver = route.maneuvers[i];
      if (maneuver.direction === 'start' || maneuver.direction === 'arrive') continue;
      if (maneuver.cumulative + 8 < progress.walked) continue;
      const upcoming: UpcomingManeuver = {
        maneuver: maneuver,
        distance: Math.max(0, Math.round(maneuver.cumulative - progress.walked))
      };
      return upcoming;
    }
    return undefined;
  }

  private routeRemaining(progress: RouteProgress): number {
    return Math.max(0, Math.round(this.routeDistance() - progress.walked));
  }

  private hasNavigationProgress(): boolean {
    return this.routeProgress() !== undefined;
  }

  private activeManeuver(): UpcomingManeuver | undefined {
    const progress: RouteProgress | undefined = this.routeProgress();
    return progress === undefined ? undefined : this.upcomingManeuver(progress);
  }

  private navigationRemainingMeters(): number {
    const progress: RouteProgress | undefined = this.routeProgress();
    return progress === undefined ? this.remainingMeters() : this.routeRemaining(progress);
  }

  private navigationWalkedMeters(): number {
    const progress: RouteProgress | undefined = this.routeProgress();
    return progress === undefined ? this.walkedMeters() : Math.round(progress.walked);
  }

  private navigationTotalMeters(): number {
    return this.hasNavigationProgress() ? this.routeDistance() : this.totalMeters();
  }

  private navigationProgressPercent(): number {
    const progress: RouteProgress | undefined = this.routeProgress();
    if (progress === undefined || this.routeDistance() <= 0) return this.progressValue() * 100;
    return Math.min(100, Math.round(progress.walked / this.routeDistance() * 100));
  }

  private activeManeuverText(): string {
    const next: UpcomingManeuver | undefined = this.activeManeuver();
    if (next === undefined) {
      return this.navigationRemainingMeters() < 60 ? '就在附近，抬头看看周围' : '沿步行路线继续走';
    }
    return next.distance <= 12
      ? '现在' + next.maneuver.label
      : String(next.distance) + ' 米后' + next.maneuver.label;
  }

  private activeManeuverHint(): string {
    const next: UpcomingManeuver | undefined = this.activeManeuver();
    if (next === undefined) {
      return this.navigationRemainingMeters() < 60 ? '到了就揭晓' : '跟着蓝色路线走';
    }
    if (next.distance <= 12) return '拐过去继续走';
    if (next.distance <= 45) return '留意路口，准备转向';
    return '沿当前方向继续走';
  }

  private activeManeuverGlyph(): string {
    const next: UpcomingManeuver | undefined = this.activeManeuver();
    return next === undefined ? '↑' : this.maneuverGlyph(next.maneuver.direction);
  }

  private maneuverGlyph(direction: string): string {
    if (direction === 'left' || direction === 'sharp-left' || direction === 'slight-left') return '↰';
    if (direction === 'right' || direction === 'sharp-right' || direction === 'slight-right') return '↱';
    if (direction === 'uturn') return '↶';
    if (direction === 'roundabout') return '⟳';
    return '↑';
  }

  /**
   * 迷雾路径视图（真实模式 + 有路线时）。
   * 没有路线时退回抽象地图（并且不显示任何终点标记）。
   */
  @Builder
  pathSection() {
    if (this.isRealMode() && this.hasRoute()) {
      Column({ space: 10 }) {
        // 转向横幅压在导航地图上方：主提示先进眼睛，再看地图（与 iOS 一致）
        if (this.hasNavigationProgress()) {
          this.maneuverBanner()
        }

        WaFogPath({
          routePoints: this.routePoints(),
          routeDistance: this.routeDistance(),
          hereLat: this.fixLat,
          hereLon: this.fixLon,
          viewHeight: this.mapHeight(),
          heading: this.heading,
          northUp: !this.mapFollowsHeading,
          onToggleOrientation: () => {
            this.mapFollowsHeading = !this.mapFollowsHeading;
          },
          onCaption: (text: string) => {
            this.fogCaption = text;
          }
        })

        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.eye'))
            .fontColor([WAColor.ink3])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontSize(WAFont.microSm)
          Text(this.fogCaption)
            .fontSize(WAFont.micro)
            .fontColor(WAColor.ink3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
      }
      .width('100%')
      .padding({ left: WASize.pagePadding, right: WASize.pagePadding })
    } else {
      this.mapSection()
    }
  }

  /**
   * 转向横幅：图标 + 一句话 + 一句副文案。
   * 距离只在下方主读数里出现一次，避免两个数字互相矛盾（docs/navigation.md §2.1）。
   */
  @Builder
  maneuverBanner() {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(52)
          .height(52)
          .backgroundColor(this.activeManeuverDistance() <= 15 ? WAColor.amberDeep : WAColor.amberSoft)
          .borderRadius(WASize.cardRadiusSm)
        Text(this.activeManeuverGlyph())
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.activeManeuverDistance() <= 15 ? WAColor.paper : WAColor.amberDeep)
      }

      Column({ space: 3 }) {
        Text(this.activeManeuverText())
          .fontSize(WAFont.titleMd)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
          .maxLines(1)
        Text(this.activeManeuverHint())
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
  }

  /** 距下一个转向还有多少米（没有转向时给一个大数） */
  private activeManeuverDistance(): number {
    const next: UpcomingManeuver | undefined = this.activeManeuver();
    return next === undefined ? 999 : next.distance;
  }

  @Builder
  mapSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      WaAbstractMap({
        progress: this.progressValue(),
        realMode: this.isRealMode()
      })

      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.eye'))
          .fontSize(WAFont.caption)
          .fontColor([WAColor.ink3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontSize(WAFont.microSm)
        Text((this.isRealMode() ? '真实位置 · ' : '') + '目的地保密中 · 还有 ' +
          this.remainingMeters() + ' 米')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(WAColor.creamTranslucent)
      .borderRadius(WASize.chipRadius)
      .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
      .margin(12)
    }
    .width('100%')
    .height(this.mapHeight())
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding })
  }

  private remainingMeters(): number {
    const session: QuestSession | undefined = this.session();
    return session === undefined ? 0 : session.remainingMeters;
  }

  @Builder
  distanceSection() {
    Column({ space: 8 }) {
      Row() {
        Row() {
          // 漫游里程动辄十几公里：一律用公里读数，「还有 23456 米」没法读
          if (this.navigationRemainingMeters() >= 1000) {
            Text((this.navigationRemainingMeters() / 1000).toFixed(1))
              .fontSize(this.isShort() ? 46 : WAFont.digits)
              .fontWeight(FontWeight.Bold)
              .fontColor(WAColor.ink)
            Text(' 公里')
              .fontSize(WAFont.titleMd)
              .fontColor(WAColor.ink2)
              .margin({ left: 4 })
          } else {
            Text(String(this.navigationRemainingMeters()))
              .fontSize(this.isShort() ? 46 : WAFont.digits)
              .fontWeight(FontWeight.Bold)
              .fontColor(WAColor.ink)
            Text(' 米')
              .fontSize(WAFont.titleMd)
              .fontColor(WAColor.ink2)
              .margin({ left: 4 })
          }
        }
        .alignItems(VerticalAlign.Bottom)

        Blank()

        if (!this.hasNavigationProgress()) {
          Text(this.bearingGlyph())
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.amberDeep)
        }
      }
      .width('100%')

      if (this.hasNavigationProgress()) {
        Text('步行 ' + String(this.estimateMinutes()) + ' 分钟 · 约 ' + this.arrivalClock() + ' 到')
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink2)
          .width('100%')
      } else {
        Text(this.directionCopy())
          .fontSize(WAFont.bodySm)
          .fontColor(WAColor.ink2)
          .width('100%')
      }

      Progress({ value: this.navigationProgressPercent(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(5)
        .color(WAColor.amber)
        .backgroundColor(WAColor.line)

      if (this.hasNavigationProgress()) {
        Text('已走 ' + this.distanceShort(this.navigationWalkedMeters()) +
          ' · 路线全长 ' + this.distanceShort(this.navigationTotalMeters()))
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .width('100%')
      } else {
        Text('已走 ' + this.distanceShort(this.walkedMeters()) +
          ' · 共 ' + this.distanceShort(this.totalMeters()))
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding, top: 16 })
  }

  /** 预计到达时刻（`22:58`）—— 用户看导航最先想知道「几点能到」 */
  private arrivalClock(): string {
    const arrival: Date = new Date(Date.now() + this.estimateMinutes() * 60000);
    const h: string = String(arrival.getHours()).padStart(2, '0');
    const m: string = String(arrival.getMinutes()).padStart(2, '0');
    return h + ':' + m;
  }

  /** 距离紧凑写法：<1000 用米，否则用公里 */
  private distanceShort(meters: number): string {
    if (meters >= 1000) return (meters / 1000).toFixed(1) + ' 公里';
    return String(Math.round(meters)) + ' 米';
  }

  /** 按 75 米/分钟估算剩下的步行时间 */
  private estimateMinutes(remainingMeters: number = this.navigationRemainingMeters()): number {
    const meters: number = remainingMeters;
    if (this.isDriveSegment()) {
      // 开车段：按 40km/h 粗估，至少 1 分钟
      const minutes: number = Math.round(meters / 1000 / 40 * 60);
      return minutes < 1 ? 1 : minutes;
    }
    const minutes: number = Math.round(meters / 75);
    return minutes < 1 ? 1 : minutes;
  }

  private walkedMeters(): number {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return 0;
    }
    return Math.max(0, session.totalMeters - session.remainingMeters);
  }

  private totalMeters(): number {
    const session: QuestSession | undefined = this.session();
    return session === undefined ? 0 : session.totalMeters;
  }

  @Builder
  clueRow(index: number) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(26)
          .height(26)
          .fill(this.isClueUnlocked(index) ? '#292E7D78' : WAColor.paper2)
          .stroke(this.isClueUnlocked(index) ? '#662E7D78' : WAColor.line)
          .strokeWidth(1)

        if (this.isClueUnlocked(index)) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(WAFont.micro)
            .fontColor([WAColor.teal])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        } else {
          Text(String(index + 1))
            .fontSize(WAFont.microSm)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.ink3)
        }
      }

      if (this.isClueUnlocked(index)) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(WAFont.caption)
            .fontColor([WAColor.teal])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontSize(WAFont.caption)
          Text(this.clueText(index))
            .fontSize(WAFont.caption)
            .fontColor(WAColor.ink)
            .lineHeight(21)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(WAColor.paper)
        .borderRadius(18)
        .border({ width: 1, color: WAColor.line, radius: 18 })
        .shadow({ radius: 10, color: WAColor.shadowSoft, offsetX: 0, offsetY: 6 })
      } else {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.lock'))
            .fontSize(WAFont.caption)
            .fontColor([WAColor.ink3])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontSize(WAFont.captionSm)
          Text(this.lockedClueCopy(index))
            .fontSize(WAFont.caption)
            .fontColor(WAColor.ink3)
            .lineHeight(20)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor('#8CFBF4E9')
        .borderRadius(18)
        .border({ width: 1, color: WAColor.line, style: BorderStyle.Dashed, radius: 18 })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  clueSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('线索')
          .fontSize(WAFont.titleMd)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
        Text(this.unlockedHintCountText())
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink3)
        Blank()
      }
      .width('100%')

      Column({ space: 10 }) {
        ForEach(CLUE_INDEXES, (index: number) => {
          this.clueRow(index)
        }, (index: number) => String(index))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding, top: 16 })
  }

  private unlockedHintCountText(): string {
    const session: QuestSession | undefined = this.session();
    if (session === undefined) {
      return '0/3';
    }
    return Math.min(session.unlockedHintCount, 3) + '/3';
  }

  @Builder
  actionSection() {
    Column({ space: 8 }) {
      if (this.isArrived()) {
        WaPrimaryButton({
          title: '揭晓盲盒',
          onTap: () => {
            this.beginArrival();
          }
        })
      } else if (this.snapshot.demoMode) {
        WaPrimaryButton({
          title: '模拟步行 +50m',
          tag: '演示',
          onTap: () => {
            this.simulateWalk();
          }
        })
        WaQuietButton({
          title: '我到了',
          onTap: () => {
            this.arriveNow();
          }
        })
      } else {
        WaPrimaryButton({
          title: '走累了？直接揭晓',
          tag: '兜底',
          onTap: () => {
            this.arriveNow();
          }
        })
      }
    }
    .width('100%')
    .padding({
      left: WASize.pagePadding,
      right: WASize.pagePadding,
      top: 14,
      bottom: 18
    })
  }

  @Builder
  journeyBody() {
    Column({ space: 0 }) {
      this.topBar()
      this.statusRow()

      if (this.isDriveSegment()) {
        // 开车段：先开车过去（不给线索、不画迷雾路径）
        this.driveSection()
      } else {
        if (this.isRoamQuest()) {
          Column() {
            this.roamParkedBanner()
          }
          .padding({ left: WASize.pagePadding, right: WASize.pagePadding, bottom: 10 })
        }
        this.pathSection()
        this.distanceSection()
        this.clueSection()
      }

      this.actionSection()
    }
    .width('100%')
    .constraintSize({ maxWidth: WASize.contentMaxWidth })
  }

  @Builder
  emptyBody() {
    Column({ space: 14 }) {
      WaMicroLabel({ text: '盲盒进行中' })
      Text('还没有正在进行的盲盒。')
        .fontSize(WAFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.ink)
      Text('让城市替你选一个。')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink3)
      Row() {
        WaQuietButton({
          title: '返回今日',
          onTap: () => {
            this.onBack();
          }
        })
      }
      .width(180)
    }
    .width('100%')
    .padding(30)
    .justifyContent(FlexAlign.Center)
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WAColor.cream)

      if (this.session() === undefined) {
        this.emptyBody()
      } else {
        Scroll() {
          Column({ space: 0 }) {
            this.journeyBody()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      // 到达闪屏
      if (this.flashOpacity > 0) {
        Column({ space: 14 }) {
          Text('到了')
            .fontSize(46)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.creamOnStage)
          Text('这个地点，只为你亮一次。')
            .fontSize(WAFont.bodySm)
            .fontColor(WAColor.creamOnStageDim)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(WAColor.stage)
        .opacity(this.flashOpacity)
      }

      // 「还没到停车圈，确定已经停好车了吗？」确认弹层
      if (this.confirmParkedFar) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(WAColor.scrim)
            .onClick(() => {
              this.confirmParkedFar = false;
            })

          Column({ space: 12 }) {
            Text('还没到停车圈，确定已经停好车了吗？')
              .fontSize(WAFont.titleSm)
              .fontWeight(FontWeight.Medium)
              .fontColor(WAColor.ink)
              .width('100%')

            Text('现在离目的地还有 ' + this.distanceCopy(this.remainingMeters()) +
              '。按步行段继续后，线索仍按真实距离解锁。')
              .fontSize(WAFont.caption)
              .fontColor(WAColor.ink2)
              .lineHeight(20)
              .width('100%')

            Button() {
              Text('已经停好车，按步行段继续')
                .fontSize(WAFont.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(WAColor.iconOnBrand)
            }
            .type(ButtonType.Capsule)
            .height(42)
            .width('100%')
            .backgroundColor(WAColor.amber)
            .onClick(() => {
              this.confirmParkedAnyway();
            })

            Button() {
              Text('再开一会儿')
                .fontSize(WAFont.caption)
                .fontColor(WAColor.ink2)
            }
            .type(ButtonType.Capsule)
            .height(40)
            .width('100%')
            .backgroundColor(WAColor.paper2)
            .onClick(() => {
              this.confirmParkedFar = false;
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: 380 })
          .padding(18)
          .backgroundColor(WAColor.paper)
          .borderRadius(WASize.cardRadius)
          .margin({ left: WASize.pagePadding, right: WASize.pagePadding })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
