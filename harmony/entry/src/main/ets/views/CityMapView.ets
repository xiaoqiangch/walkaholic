/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 个人城市地图（我的足迹）
 *
 * 移植自 apple/App/Views/CityMapView.swift。
 *
 * 为什么要有这一页：卡片是「产品给的」，走过的路是「我自己留下的」。
 * 它把两件事画在同一张图上：
 *   1. 真实走过的轨迹（core/track.ts，只在步行段记录，开车段不画）；
 *   2. 已经收下的地点（图鉴里的卡，有真实坐标的）。
 *
 * 边界：
 * - 只在本地画，不上传任何坐标（与「隐私与安全」的承诺一致）。
 * - 轨迹按天分线，最近一天最亮，越久越淡。
 * - 没有轨迹、也没有收过卡时给空状态，不画假数据。
 *
 * 鸿蒙没有 MapKit（要 AGC 配置），所以这里用 Canvas 手绘：
 * 归一化到包围盒的折线 + 地点圆点，风格与旅程页的迷雾路径一致。
 */

import { AppSnapshot } from '../core/contract';
import { GeoPoint, Place, PlaceCard, WalkPoint } from '../core/types';
import {
  GeoProjection,
  PixelCoordinate,
  TrackDay,
  fitGeoProjection,
  projectGeoPoint,
  simplifyPoints,
  splitTrackSegments,
  trackOpacity
} from '../core/track';
import { WaMicroLabel, WaStatsRow, StatItem } from '../components/Common';
import { emptySnapshot, readSnapshot } from '../components/StoreBridge';
import { WAColor, WAFont, WASize } from '../theme/Theme';
import { getStoreInstance } from '../core/store';
import { decimal1 } from '../components/Format';

/** 地图窗口：全部 / 最近 7 天 */
const WINDOW_ALL: string = 'all';
const WINDOW_RECENT: string = 'recent';

/** 画布高度（vp） */
const MAP_HEIGHT: number = 380;
/** 单条线最多画多少个点（画布画几千个点会卡） */
const MAX_POINTS_PER_DAY: number = 400;
/** 最多画多少天（更早的合并到「更早」里） */
const MAX_DAYS: number = 90;

/** 已收集地点（带坐标） */
class VisitedPlace {
  place: Place;
  card: PlaceCard;

  constructor(place: Place, card: PlaceCard) {
    this.place = place;
    this.card = card;
  }
}

/** 一天的轨迹（已抽稀） */
class DayLine {
  day: number;
  rank: number;
  points: GeoPoint[];

  constructor(day: number, rank: number, points: GeoPoint[]) {
    this.day = day;
    this.rank = rank;
    this.points = points;
  }
}

@Component
export struct CityMapView {
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop winWidth: number = 400;
  @Prop winHeight: number = 800;

  onBack: () => void = () => {
  };

  @State private snapshot: AppSnapshot = emptySnapshot();
  @State private window: string = WINDOW_ALL;
  @State private canvasWidth: number = 320;

  private ready: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.load();
  }

  onRevisionChanged(propName: string): void {
    this.load();
  }

  private load(): void {
    this.snapshot = readSnapshot(this.snapshot);
    this.draw();
  }

  // ============================================================
  // 数据
  // ============================================================

  private track() {
    return getStoreInstance().track();
  }

  /** 按天切好的轨迹（新的在前），取样到「够画一条线」的密度 */
  private dayLines(): DayLine[] {
    let days: TrackDay[] = [];
    try {
      days = this.window === WINDOW_RECENT ? this.track().recentDays(7, Date.now()) : this.track().days();
    } catch (err) {
      days = [];
    }
    const lines: DayLine[] = [];
    const limit: number = Math.min(days.length, MAX_DAYS);
    for (let i = 0; i < limit; i += 1) {
      const entry: TrackDay = days[i];
      const segments: WalkPoint[][] = splitTrackSegments(entry.points);
      const visibleSegments: WalkPoint[][] = [];
      for (let j = 0; j < segments.length; j += 1) {
        if (segments[j].length >= 2) visibleSegments.push(segments[j]);
      }
      const segmentLimit: number = Math.min(visibleSegments.length, Math.floor(MAX_POINTS_PER_DAY / 2));
      const pointsPerSegment: number = segmentLimit > 0
        ? Math.max(2, Math.floor(MAX_POINTS_PER_DAY / segmentLimit))
        : 0;
      for (let j = 0; j < segmentLimit; j += 1) {
        const segmentIndex: number = Math.floor(j * visibleSegments.length / segmentLimit);
        const coordinates: GeoPoint[] = [];
        for (let k = 0; k < visibleSegments[segmentIndex].length; k += 1) {
          coordinates.push({
            latitude: visibleSegments[segmentIndex][k].latitude,
            longitude: visibleSegments[segmentIndex][k].longitude
          });
        }
        lines.push(new DayLine(
          entry.day,
          i,
          simplifyPoints(coordinates, pointsPerSegment)
        ));
      }
    }
    return lines;
  }

  /** 已收录且带真实坐标的地点 */
  private visited(): VisitedPlace[] {
    const list: VisitedPlace[] = [];
    for (let i = 0; i < this.snapshot.profile.cards.length; i += 1) {
      const card: PlaceCard = this.snapshot.profile.cards[i];
      for (let j = 0; j < this.snapshot.places.length; j += 1) {
        const place: Place = this.snapshot.places[j];
        if (place.id !== card.placeID) continue;
        if (place.coordinate === undefined) continue;
        list.push(new VisitedPlace(place, card));
        break;
      }
    }
    return list;
  }

  private isEmpty(): boolean {
    const lines: DayLine[] = this.dayLines();
    for (let i = 0; i < lines.length; i += 1) {
      if (lines[i].points.length >= 2) return false;
    }
    return this.visited().length === 0;
  }

  private statsItems(): StatItem[] {
    let days: number = 0;
    let meters: number = 0;
    let cells: number = 0;
    let area: number = 0;
    try {
      const stats = this.track().stats();
      days = stats.walkedDayCount;
      meters = stats.totalMeters;
      cells = stats.exploredCellCount;
      area = stats.areaSquareKm;
    } catch (err) {
      days = 0;
    }
    const items: StatItem[] = [];
    items.push({ value: String(days), label: '天在路上' });
    items.push({ value: decimal1(meters / 1000), label: '走过公里' });
    items.push({ value: String(cells), label: '探索街区' });
    items.push({ value: decimal1(area), label: '平方公里' });
    return items;
  }

  // ============================================================
  // 绘制（Canvas 手绘：包围盒归一化 + 按天分线）
  // ============================================================

  private projection(lines: DayLine[], visited: VisitedPlace[]): GeoProjection | undefined {
    const all: GeoPoint[] = [];
    for (let i = 0; i < lines.length; i += 1) {
      for (let j = 0; j < lines[i].points.length; j += 1) all.push(lines[i].points[j]);
    }
    for (let i = 0; i < visited.length; i += 1) {
      const coordinate: GeoPoint | undefined = visited[i].place.coordinate;
      if (coordinate !== undefined) all.push(coordinate);
    }
    return fitGeoProjection(all, this.canvasWidth, MAP_HEIGHT);
  }

  private draw(): void {
    if (!this.ready) return;
    const width: number = this.canvasWidth;
    const height: number = MAP_HEIGHT;
    if (width <= 0) return;
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = WAColor.cream;
    ctx.fillRect(0, 0, width, height);

    const lines: DayLine[] = this.dayLines();
    const visited: VisitedPlace[] = this.visited();
    const projection: GeoProjection | undefined = this.projection(lines, visited);
    if (projection === undefined) return;

    // ---------- 轨迹（按天分段；越新越亮） ----------
    ctx.lineCap = 'round';
    for (let i = 0; i < lines.length; i += 1) {
      const points: GeoPoint[] = lines[i].points;
      if (points.length < 2) continue;
      ctx.globalAlpha = trackOpacity(lines[i].rank);
      ctx.strokeStyle = WAColor.amber;
      ctx.lineWidth = 3.4;
      ctx.beginPath();
      for (let j = 0; j < points.length; j += 1) {
        const pixel: PixelCoordinate = projectGeoPoint(points[j], projection);
        if (j === 0) {
          ctx.moveTo(pixel.x, pixel.y);
        } else {
          ctx.lineTo(pixel.x, pixel.y);
        }
      }
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // ---------- 收下的地点（圆点） ----------
    for (let i = 0; i < visited.length; i += 1) {
      const coordinate: GeoPoint | undefined = visited[i].place.coordinate;
      if (coordinate === undefined) continue;
      const pixel: PixelCoordinate = projectGeoPoint(coordinate, projection);
      ctx.fillStyle = WAColor.paper;
      ctx.strokeStyle = '#730A59F7';
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, 6, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = WAColor.amber;
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, 2.6, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // ============================================================
  // 区块
  // ============================================================

  @Builder
  header() {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(WAFont.titleSm)
        .fontColor(WAColor.ink2)
        .textAlign(TextAlign.Center)
        .width(34)
        .height(34)
        .backgroundColor(WAColor.paper)
        .borderRadius(17)
        .border({ width: 1, color: WAColor.line, radius: 17 })
        .onClick(() => {
          this.onBack();
        })

      Column({ space: 2 }) {
        WaMicroLabel({ text: '我的城市' })
        Text('走过的路长在这里')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
      }
      .alignItems(HorizontalAlign.Start)

      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ bottom: 10 })
  }

  @Builder
  statsCard() {
    Column({ space: 10 }) {
      Row() {
        Text(this.snapshot.profile.name)
          .fontSize(WAFont.titleSm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink)
        Blank()
        Text(this.statsItems()[0].value + ' 天在路上')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
      }
      .width('100%')

      WaStatsRow({ items: this.statsItems(), roomy: true })

      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.pin'))
          .fontSize(WAFont.caption)
          .fontColor([WAColor.ink2])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text('收下的地点 ' + String(this.visited().length) + ' 处')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
  }

  @Builder
  windowPicker() {
    Row({ space: 8 }) {
      this.windowChip('全部', WINDOW_ALL)
      this.windowChip('最近 7 天', WINDOW_RECENT)
      Blank()
    }
    .width('100%')
  }

  @Builder
  windowChip(label: string, value: string) {
    Button() {
      Text(label)
        .fontSize(WAFont.captionSm)
        .fontWeight(this.window === value ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.window === value ? WAColor.amber : WAColor.ink2)
    }
    .type(ButtonType.Capsule)
    .height(30)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.window === value ? WAColor.amberSoft : WAColor.paper2)
    .onClick(() => {
      if (this.window === value) return;
      this.window = value;
      this.draw();
    })
  }

  @Builder
  mapCard() {
    Column({ space: 0 }) {
      Canvas(this.ctx)
        .width('100%')
        .height(MAP_HEIGHT)
        .onReady(() => {
          this.ready = true;
          this.draw();
        })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const next: number = parseFloat(newValue.width.toString());
          if (Math.abs(next - this.canvasWidth) > 1) {
            this.canvasWidth = next;
            this.draw();
          }
        })
    }
    .width('100%')
    .backgroundColor(WAColor.cream)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .clip(true)
  }

  @Builder
  legend() {
    Row({ space: 14 }) {
      this.legendDot(WAColor.amber, '最近走过')
      this.legendDot('#590A59F7', '更早的')
      this.legendDot(WAColor.ink3, '收下的地点')
      Blank()
    }
    .width('100%')
  }

  @Builder
  legendDot(color: string, text: string) {
    Row({ space: 5 }) {
      Circle()
        .width(7)
        .height(7)
        .fill(color)
      Text(text)
        .fontSize(WAFont.microSm)
        .fontColor(WAColor.ink2)
    }
  }

  @Builder
  emptyCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.map'))
        .fontSize(36)
        .fontColor([WAColor.ink4])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text('城市地图还是空的。')
        .fontSize(WAFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.ink)
      Text('打开一个盲盒走完，走过的路会自己长在这张图上。')
        .fontSize(WAFont.caption)
        .fontColor(WAColor.ink3)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 32, bottom: 32, left: 24, right: 24 })
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
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

          Column() {
            this.statsCard()
          }
          .margin({ top: 6 })

          Column() {
            if (this.isEmpty()) {
              this.emptyCard()
            } else {
              Column({ space: 10 }) {
                this.windowPicker()
                this.mapCard()
                this.legend()
              }
              .width('100%')
            }
          }
          .margin({ top: 16 })

          Text('轨迹只存在这台手机上，不会上传。开车段不记，只留走路的那部分。')
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ink3)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 16, bottom: 26 })
        }
        .width('100%')
        .constraintSize({ maxWidth: WASize.contentMaxWidth })
        .padding({
          left: WASize.pagePadding,
          right: WASize.pagePadding,
          top: 8
        })
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
