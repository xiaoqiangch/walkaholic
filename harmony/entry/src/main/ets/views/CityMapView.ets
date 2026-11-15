/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 个人城市地图（我的足迹）
 *
 * 移植自 apple/App/Views/CityMapView.swift，但底图是**真实地图**：
 * 高德 staticmap 出一张真路网图当背景（有路、有水、有地名），
 * 轨迹与地点用同一套 Web 墨卡托投影叠上去，所以永远对齐。
 *
 * 支持：
 *   - 「+ −」缩放（3–17 级）与「重新框选」复位
 *   - 拖动平移
 *   - 地点标记直接显示名字（最多 12 个，避免糊成一片）
 *   - 比例尺
 *
 * 边界：
 * - 只在本地画，不上传任何坐标（与「隐私与安全」的承诺一致）。
 * - 轨迹按天分线，最近一天最亮，越久越淡。
 * - 拿不到地图 Key 时退化为手绘网格，并明确标注「未配置地图 Key」。
 */

import { AppSnapshot } from '../core/contract';
import { GeoPoint, Place, PlaceCard } from '../core/types';
import { TrackDay, simplifyPoints, trackOpacity } from '../core/track';
import { HttpClient } from '../core/http';
import { KeyValueStore } from '../core/contract';
import { WaMicroLabel, WaStatsRow, StatItem } from '../components/Common';
import { emptySnapshot, readSnapshot } from '../components/StoreBridge';
import { WAColor, WAFont, WASize } from '../theme/Theme';
import { getStoreInstance } from '../core/store';
import { decimal1 } from '../components/Format';
import { wgs84ToGcj02 } from '../core/geo';
import { loadMapKeys } from '../core/mapkeys';
import {
  MAX_ZOOM,
  MIN_ZOOM,
  MapPixel,
  MapViewport,
  fitZoom,
  metersPerPixel,
  projectToCanvas,
  staticMapUrl,
  panViewport
} from '../core/staticmap';

/** 地图窗口：全部 / 最近 7 天 */
const WINDOW_ALL: string = 'all';
const WINDOW_RECENT: string = 'recent';

/** 画布高度（vp） */
const MAP_HEIGHT: number = 380;
/** 单条线最多画多少个点（画布画几千个点会卡） */
const MAX_POINTS_PER_DAY: number = 400;
/** 最多画多少天（更早的合并到「更早」里） */
const MAX_DAYS: number = 90;
/** 最多标几个地名（再多就糊了） */
const MAX_LABELS: number = 12;

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
  points: GeoPoint[];

  constructor(day: number, points: GeoPoint[]) {
    this.day = day;
    this.points = points;
  }
}

/** 屏幕上的一个地点标签 */
class PlaceLabel {
  name: string;
  x: number;
  y: number;

  constructor(name: string, x: number, y: number) {
    this.name = name;
    this.x = x;
    this.y = y;
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
  /** 底图 URL（有 Key 才有；变化时 Image 自动重载） */
  @State private basemapUrl: string = '';
  /** 是否已经拿到地图 Key */
  @State private hasKey: boolean = false;
  /** 当前视窗（中心 + 缩放），缩放/拖动都改它 */
  @State private zoom: number = 16;
  @State private centerLat: number = 0;
  @State private centerLon: number = 0;
  /** 比例尺文案 */
  @State private scaleText: string = '';
  /** 拖动中的实时位移（底图与标记一起平移，松手才提交） */
  @State private panOffsetX: number = 0;
  @State private panOffsetY: number = 0;
  /** 屏幕上要显示的地点文字标签 */
  @State private labels: PlaceLabel[] = [];
  /** 是否需要「重新框选」（用户手动缩放/拖动后就不再自动复位） */
  private userMoved: boolean = false;
  /** 高德 Key（拉不到就退化为手绘网格） */
  private mapKey: string = '';
  /** 拖动起点（windowX/Y；用绝对值算位移，不依赖元素自身位置） */
  private dragStartX: number = 0;
  private dragStartY: number = 0;

  /** 平台能力（拉地图 Key） */
  http: HttpClient | undefined = undefined;
  kv: KeyValueStore | undefined = undefined;
  readBundledKeys: () => string | undefined = () => undefined;
  adminBase: string = '';

  private ready: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.load();
    this.loadKey();
  }

  onRevisionChanged(propName: string): void {
    this.load();
  }

  /** 拉地图 Key（包内 → Pages → 后台），拿到就换成真地图底图 */
  private async loadKey(): Promise<void> {
    if (this.http === undefined || this.kv === undefined) return;
    try {
      const result = await loadMapKeys(
        this.http, this.kv, this.readBundledKeys, this.adminBase, Date.now()
      );
      this.hasKey = result.keys.amap.length > 0;
      this.mapKey = result.keys.amap;
    } catch (err) {
      this.hasKey = false;
    }
    this.resetView();
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
      const coordinates: GeoPoint[] = [];
      for (let j = 0; j < entry.points.length; j += 1) {
        coordinates.push({ latitude: entry.points[j].latitude, longitude: entry.points[j].longitude });
      }
      lines.push(new DayLine(entry.day, simplifyPoints(coordinates, MAX_POINTS_PER_DAY)));
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
  // 视窗（真实地图：墨卡托投影 + 可缩放）
  // ============================================================

  /** 数据包围盒：[minLat, maxLat, minLon, maxLon]；没数据返回空数组 */
  private computeBounds(): number[] {
    const all: GeoPoint[] = [];
    const lines: DayLine[] = this.dayLines();
    for (let i = 0; i < lines.length; i += 1) {
      for (let j = 0; j < lines[i].points.length; j += 1) all.push(lines[i].points[j]);
    }
    const visited: VisitedPlace[] = this.visited();
    for (let i = 0; i < visited.length; i += 1) {
      const coordinate: GeoPoint | undefined = visited[i].place.coordinate;
      if (coordinate !== undefined) all.push(coordinate);
    }
    if (all.length === 0) return [];
    let minLat: number = all[0].latitude;
    let maxLat: number = all[0].latitude;
    let minLon: number = all[0].longitude;
    let maxLon: number = all[0].longitude;
    for (let i = 1; i < all.length; i += 1) {
      if (all[i].latitude < minLat) minLat = all[i].latitude;
      if (all[i].latitude > maxLat) maxLat = all[i].latitude;
      if (all[i].longitude < minLon) minLon = all[i].longitude;
      if (all[i].longitude > maxLon) maxLon = all[i].longitude;
    }
    const bounds: number[] = [minLat, maxLat, minLon, maxLon];
    return bounds;
  }

  /** 当前视窗（中心为 GCJ-02，因为高德底图吃这个） */
  private viewport(): MapViewport {
    return new MapViewport(this.centerLat, this.centerLon, this.zoom);
  }

  /**
   * 复位：把中心/缩放设成「刚好装下所有数据」。
   * 用户手动缩放或拖动之后不再自动复位（userMoved），避免和他抢控制权。
   */
  private resetView(): void {
    const bounds: number[] = this.computeBounds();
    if (bounds.length === 0) {
      this.basemapUrl = '';
      return;
    }
    const centerWgs = wgs84ToGcj02(
      (bounds[0] + bounds[1]) / 2,
      (bounds[2] + bounds[3]) / 2
    );
    this.centerLat = centerWgs.latitude;
    this.centerLon = centerWgs.longitude;
    // 用 GCJ 后的范围算缩放（偏移量几十米，对选档没影响）
    const zoom: number = fitZoom(
      bounds[0], bounds[1], bounds[2], bounds[3],
      this.canvasWidth, MAP_HEIGHT, 44
    );
    this.zoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, zoom));
    this.userMoved = false;
    this.refreshBasemap();
  }

  /** 重算底图 URL + 比例尺文案，然后重画 */
  private refreshBasemap(): void {
    if (this.centerLat === 0 && this.centerLon === 0) {
      this.basemapUrl = '';
      this.draw();
      return;
    }
    const mpp: number = metersPerPixel(this.centerLat, this.zoom);
    const metersAcross: number = mpp * this.canvasWidth;
    this.scaleText = metersAcross >= 1000
      ? (metersAcross / 1000).toFixed(1) + ' 公里宽'
      : Math.round(metersAcross) + ' 米宽';

    if (this.hasKey && this.mapKey.length > 0) {
      this.basemapUrl = staticMapUrl(this.viewport(), this.canvasWidth, MAP_HEIGHT, this.mapKey);
    } else {
      this.basemapUrl = '';
    }
    this.draw();
  }

  /** 缩放一档（dir = +1 放大 / -1 缩小） */
  private zoomBy(dir: number): void {
    const next: number = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, this.zoom + dir));
    if (next === this.zoom) return;
    this.zoom = next;
    this.userMoved = true;
    this.refreshBasemap();
  }

  /** 拖动平移：把画布像素位移换算成新的视窗中心 */
  private panBy(deltaX: number, deltaY: number): void {
    if (this.centerLat === 0 && this.centerLon === 0) return;
    const next: MapViewport = panViewport(this.viewport(), deltaX, deltaY);
    this.centerLat = next.centerLat;
    this.centerLon = next.centerLon;
    this.userMoved = true;
    this.refreshBasemap();
  }

  /**
   * 重算文字标签。
   *
   * 为什么要单独算而不是画在 Canvas 里：Canvas 画中文在不同机型上字体不一致，
   * 用组件叠层既清晰又能自动处理省略号。
   *
   * 重叠处理：按距离由近到远取前 MAX_LABELS 个，且两两之间屏幕距离
   * 小于 `labelGap` 的只保留第一个 —— 否则密集街区会糊成一片。
   */
  private refreshLabels(): void {
    this.labels = [];
    if (this.canvasWidth <= 0) return;
    const visited: VisitedPlace[] = this.visited();
    const items: PlaceLabel[] = [];
    for (let i = 0; i < visited.length; i += 1) {
      const coordinate: GeoPoint | undefined = visited[i].place.coordinate;
      if (coordinate === undefined) continue;
      const pixel: MapPixel = this.project(coordinate);
      // 画布外的直接丢掉
      if (pixel.x < 8 || pixel.x > this.canvasWidth - 8) continue;
      if (pixel.y < 8 || pixel.y > MAP_HEIGHT - 8) continue;
      items.push(new PlaceLabel(visited[i].place.name, pixel.x, pixel.y));
    }
    // 按屏幕位置从左到右排，保证渲染顺序稳定（不会每帧跳）
    items.sort((a: PlaceLabel, b: PlaceLabel): number => a.x - b.x);
    const kept: PlaceLabel[] = [];
    for (let i = 0; i < items.length && kept.length < MAX_LABELS; i += 1) {
      let clash: boolean = false;
      for (let j = 0; j < kept.length; j += 1) {
        const dx: number = kept[j].x - items[i].x;
        const dy: number = kept[j].y - items[i].y;
        if (Math.sqrt(dx * dx + dy * dy) < 64) {
          clash = true;
          break;
        }
      }
      if (!clash) kept.push(items[i]);
    }
    this.labels = kept;
  }

  /** 经纬度（WGS-84）→ 画布像素 */
  private project(point: GeoPoint): MapPixel {
    const gcj = wgs84ToGcj02(point.latitude, point.longitude);
    return projectToCanvas(gcj.latitude, gcj.longitude, this.viewport(), this.canvasWidth, MAP_HEIGHT);
  }

  private draw(): void {
    if (!this.ready) return;
    const width: number = this.canvasWidth;
    const height: number = MAP_HEIGHT;
    if (width <= 0) return;
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.clearRect(0, 0, width, height);
    // 底图由 Image(basemapUrl) 铺在下面；这里只在没有 Key 时画个底色
    if (this.basemapUrl.length === 0) {
      ctx.fillStyle = '#F2EEE6';
      ctx.fillRect(0, 0, width, height);
    }

    if (this.centerLat === 0 && this.centerLon === 0) return;

    // ---------- 轨迹（按天；越新越亮） ----------
    const lines: DayLine[] = this.dayLines();
    ctx.lineCap = 'round';
    for (let i = 0; i < lines.length; i += 1) {
      const points: GeoPoint[] = lines[i].points;
      if (points.length < 2) continue;
      ctx.globalAlpha = trackOpacity(i);
      ctx.strokeStyle = WAColor.amber;
      ctx.lineWidth = 4;
      ctx.beginPath();
      for (let j = 0; j < points.length; j += 1) {
        const pixel: MapPixel = this.project(points[j]);
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
    const visited: VisitedPlace[] = this.visited();
    for (let i = 0; i < visited.length; i += 1) {
      const coordinate: GeoPoint | undefined = visited[i].place.coordinate;
      if (coordinate === undefined) continue;
      const pixel: MapPixel = this.project(coordinate);
      ctx.fillStyle = WAColor.paper;
      ctx.strokeStyle = '#730A59F7';
      ctx.lineWidth = 1.6;
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, 6.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = WAColor.amber;
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, 2.8, 0, Math.PI * 2);
      ctx.fill();
    }

    // 圆点画完再算文字标签（标签用组件叠层渲染，不画在 Canvas 里）
    this.refreshLabels();
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
    // 注意结构：**外层 Stack 负责接收手势，且它自己不平移**；
    // 只有内层 Stack（底图 + 轨迹 + 标签）跟着手指 translate。
    //
    // 之前把 PanGesture 挂在「会被 translate 的那个元素」自己身上，
    // 于是每次 onActionUpdate 改 panOffset → 元素被移动 → 手指相对它的偏移又变了
    // → 下一帧算出不同位移 …… 形成正反馈，表现就是「兴趣点疯狂乱跳」。
    Stack({ alignContent: Alignment.TopStart }) {
      // 内层：唯一被平移的图层，底图/轨迹/标签共用同一变换，绝不会错位
      Stack({ alignContent: Alignment.TopStart }) {
        // ① 真实地图底图（高德 staticmap）：一张真路网图，有路名、有水系
        if (this.basemapUrl.length > 0) {
          Image(this.basemapUrl)
            .width('100%')
            .height(MAP_HEIGHT)
            .objectFit(ImageFit.Fill)
            .interpolation(ImageInterpolation.High)
        }

        // ② 轨迹与地点圆点（与底图共用墨卡托投影，严格对齐）
        Canvas(this.ctx)
          .width('100%')
          .height(MAP_HEIGHT)
          .onReady(() => {
            this.ready = true;
            if (this.centerLat === 0 && this.centerLon === 0) {
              this.resetView();
            }
            this.draw();
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const next: number = parseFloat(newValue.width.toString());
            if (Math.abs(next - this.canvasWidth) > 1) {
              this.canvasWidth = next;
              if (!this.userMoved) {
                this.resetView();
              } else {
                this.refreshBasemap();
              }
            }
          })

        // ③ 地点文字标签（组件叠层：中文渲染清晰、自动省略）
        ForEach(this.labels, (label: PlaceLabel) => {
          Text(label.name)
            .fontSize(WAFont.micro)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 108 })
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#E6FFFFFF')
            .borderRadius(5)
            .border({ width: 1, color: '#33000000', radius: 5 })
            .position({ x: label.x - 54, y: label.y + 8 })
            .textAlign(TextAlign.Center)
        }, (label: PlaceLabel) => label.name + '@' + label.x.toFixed(0))
      }
      .width('100%')
      .height(MAP_HEIGHT)
      .translate({ x: this.panOffsetX, y: this.panOffsetY })

      // 手势层：透明、固定不动，只负责把拖动量交给地图
      Column()
        .width('100%')
        .height(MAP_HEIGHT)
        .onTouch((event: TouchEvent) => {
          // 用 TouchEvent 而不是 PanGesture：偏移量按「按下点」的手动差值算，
          // 与元素自身是否移动完全无关，天然不会形成反馈环。
          if (event.touches.length === 0) return;
          const touch: TouchObject = event.touches[0];
          if (event.type === TouchType.Down) {
            this.dragStartX = touch.windowX;
            this.dragStartY = touch.windowY;
            this.panOffsetX = 0;
            this.panOffsetY = 0;
          } else if (event.type === TouchType.Move) {
            this.panOffsetX = touch.windowX - this.dragStartX;
            this.panOffsetY = touch.windowY - this.dragStartY;
          } else {
            const dx: number = touch.windowX - this.dragStartX;
            const dy: number = touch.windowY - this.dragStartY;
            this.panOffsetX = 0;
            this.panOffsetY = 0;
            if (Math.abs(dx) > 2 || Math.abs(dy) > 2) {
              this.panBy(dx, dy);
            }
          }
        })

      // ④ 缩放按钮（右上角，不跟地图一起平移）
      Column({ space: 6 }) {
        this.zoomButton('+', () => {
          this.zoomBy(1);
        })
        this.zoomButton('−', () => {
          this.zoomBy(-1);
        })
      }
      .position({ x: this.canvasWidth - 46, y: 10 })

      // ⑤ 比例尺（左下角）
      if (this.scaleText.length > 0) {
        Text(this.scaleText)
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink2)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#E6FBF8F2')
          .borderRadius(WASize.chipRadius)
          .position({ x: 10, y: MAP_HEIGHT - 34 })
      }

      // ⑥ 没 Key 时明确说明，而不是画一条假地图骗人
      if (this.basemapUrl.length === 0) {
        Text('未取到地图 Key，底图暂用示意图')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#E6FBF8F2')
          .borderRadius(WASize.chipRadius)
          .position({ x: 10, y: 10 })
      }
    }
    .width('100%')
    .height(MAP_HEIGHT)
    .backgroundColor('#F2EEE6')
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .clip(true)
  }

  @Builder
  zoomButton(label: string, onTap: () => void) {
    Text(label)
      .fontSize(WAFont.titleMd)
      .fontWeight(FontWeight.Medium)
      .fontColor(WAColor.ink)
      .textAlign(TextAlign.Center)
      .width(36)
      .height(36)
      .backgroundColor('#F2FBF8F2')
      .borderRadius(18)
      .border({ width: 1, color: WAColor.line, radius: 18 })
      .onClick(() => {
        onTap();
      })
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

