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
 * 疆域（docs/territory.md §展示要求 2）：
 *   - 已收录的**真实地点**凸包 = 疆域，叠在轨迹和地点**之上**
 *   - 填充爵位色 20% + 描边爵位色 2.5 + 凸包顶点小圆
 *   - **无疆域时不画任何多边形**（不画假多边形），只在统计卡里说明还差几个点
 *   - 面积/爵位计算全部在 core/territory.ts（纯 TS，有单测）
 *
 * 边界：
 * - 只在本地画，不上传任何坐标（与「隐私与安全」的承诺一致）。
 * - 轨迹按天分线，最近一天最亮，越久越淡。
 * - 拿不到地图 Key 时退化为手绘网格，并明确标注「未配置地图 Key」。
 */

import { AppSnapshot } from '../core/contract';
import { GeoPoint, Place, PlaceCard, WalkPoint } from '../core/types';
import { TrackDay, simplifyPoints, splitTrackSegments, trackOpacity } from '../core/track';
import { HttpClient } from '../core/http';
import { KeyValueStore } from '../core/contract';
import { WaMicroLabel, WaProgressBar, WaStatsRow, StatItem } from '../components/Common';
import { emptySnapshot, readSnapshot } from '../components/StoreBridge';
import { WAColor, WAFont, WASize } from '../theme/Theme';
import { getStoreInstance } from '../core/store';
import { decimal1 } from '../components/Format';
import { wgs84ToGcj02 } from '../core/geo';
import { loadMapKeys } from '../core/mapkeys';
import {
  MIN_POINTS_FOR_TERRITORY,
  TerritoryRankResult,
  TerritoryStats,
  formatTerritoryArea,
  formatTerritorySpan,
  hullToGeoPoints,
  occupiedPoints,
  progressCopy,
  territoryRank,
  territoryStats
} from '../core/territory';
import {
  MAX_ZOOM,
  MIN_ZOOM,
  MapPixel,
  MapViewport,
  fitZoom,
  metersPerPixel,
  projectToCanvas,
  staticMapUrl,
  panViewport,
  worldPixel,
  worldPixelToLatLon,
  zoomViewportAtPoint
} from '../core/staticmap';

/** 地图窗口：全部 / 最近 7 天 */
const WINDOW_ALL: string = 'all';
const WINDOW_RECENT: string = 'recent';

/** 画布高度（vp） */
const MAP_HEIGHT: number = 380;
/** 允许前端继续放大到 19 级（高德底图最多到 17 级，17→19 级由 17 级高清底图无损放大 1–4 倍） */
const MAX_DISPLAY_ZOOM: number = 19;
/** 初始自动框选的最大缩放级别（避免只有 1–2 个近距离点时一进来就顶到 17 级上限，留出放大空间） */
const FIT_MAX_INITIAL_ZOOM: number = 15;
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
  /** 距今天数排名（0 = 最近），用于透明度；同一天拆成多段时共用 */
  rank: number;
  points: GeoPoint[];

  constructor(day: number, rank: number, points: GeoPoint[]) {
    this.day = day;
    this.rank = rank;
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
  /** 当前请求中的底图 URL（有 Key 才有） */
  @State private basemapUrl: string = '';
  /** 已解码完成的底图 URL（双缓冲：新底图未下载完成前保持旧底图并按当前视窗实时缩放/平移） */
  @State private loadedBasemapUrl: string = '';
  /** 已加载底图相对当前视窗的实时缩放与位移（保证缩放/拖动时底图与地点零延迟同步随动） */
  @State private basemapScale: number = 1;
  @State private basemapOffsetX: number = 0;
  @State private basemapOffsetY: number = 0;
  /** 是否已经拿到地图 Key */
  @State private hasKey: boolean = false;
  /** 当前视窗（中心 + 缩放），缩放/拖动都改它 */
  @State private zoom: number = 15;
  @State private centerLat: number = 0;
  @State private centerLon: number = 0;
  /** 比例尺文案 */
  @State private scaleText: string = '';
  /** 手指正在地图区域内交互（锁定外层 Scroll，防止拖动地图变成拖动整页） */
  @State private mapInteracting: boolean = false;
  /** 双指缩放激活态 */
  @State private pinchActive: boolean = false;
  @State private pinchCenterX: number = 0;
  @State private pinchCenterY: number = 0;
  /** 屏幕上要显示的地点文字标签 */
  @State private labels: PlaceLabel[] = [];
  /** 疆域统计（页面刷新时重算） */
  @State private territoryAreaText: string = '0 m²';
  @State private territoryPointText: string = '0';
  @State private territorySpanText: string = '0 m';
  @State private territoryRankTitle: string = '白身';
  @State private territoryRankDesc: string = '还没有自己的疆域';
  @State private territoryRankColor: string = '#9CA3AF';
  @State private territorySeal: string = '民';
  @State private territoryProgress: number = 0;
  @State private territoryProgressText: string = '';
  @State private territoryHullCount: number = 0;
  @State private territoryHasArea: boolean = false;
  /** 是否被点数门槛卡住（docs §三） */
  @State private territoryCapped: boolean = false;
  /** 是否需要「重新框选」（用户手动缩放/拖动后就不再自动复位） */
  @State private userMoved: boolean = false;
  /** 高德 Key（拉不到就退化为手绘网格） */
  private mapKey: string = '';
  /** 单指拖动起点视窗 */
  private panStartViewport: MapViewport = new MapViewport(0, 0, 15);
  private panActive: boolean = false;
  private pinchStartViewport: MapViewport = new MapViewport(0, 0, 15);
  private pinchStartZoom: number = 15;
  private multiTouchActive: boolean = false;
  /** 已加载底图对应的视窗与请求中底图对应的视窗 */
  private loadedViewport: MapViewport = new MapViewport(0, 0, 15);
  private pendingViewport: MapViewport = new MapViewport(0, 0, 15);
  private pageScroller: Scroller = new Scroller();

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
    this.refreshTerritory();
    this.draw();
  }

  // ============================================================
  // 数据
  // ============================================================

  // ============================================================
  // 疆域（docs/territory.md）
  // ============================================================

  /** 疆域统计：只统计真实来源 + 有坐标的已收录地点 */
  private territory(): TerritoryStats {
    const ids: string[] = [];
    for (let i = 0; i < this.snapshot.profile.cards.length; i += 1) {
      ids.push(this.snapshot.profile.cards[i].placeID);
    }
    return territoryStats(occupiedPoints(ids, this.snapshot.places));
  }

  /** 把疆域结果同步到 @State（UI 与 Canvas 共用同一份，避免两处各算一遍） */
  private refreshTerritory(): void {
    const stats: TerritoryStats = this.territory();
    const rank: TerritoryRankResult = territoryRank(stats.areaKm2, stats.pointCount);
    this.territoryAreaText = formatTerritoryArea(stats.areaKm2);
    this.territoryPointText = String(stats.pointCount);
    this.territorySpanText = formatTerritorySpan(stats.spanM);
    this.territoryRankTitle = rank.rank.title;
    this.territoryRankDesc = rank.rank.desc;
    this.territoryRankColor = rank.rank.color;
    this.territorySeal = rank.rank.seal;
    this.territoryProgress = rank.progress;
    this.territoryProgressText = stats.pointCount >= MIN_POINTS_FOR_TERRITORY
      ? progressCopy(rank)
      : '至少 3 个真实地点才能围成一片疆域';
    this.territoryCapped = rank.capped;
    this.territoryHullCount = stats.hullPointCount;
    this.territoryHasArea = stats.hull.length >= 3;
  }

  /** 疆域凸包 → 画布像素（走与地点圆点完全相同的投影，保证严丝合缝） */
  private territoryHullPixels(): MapPixel[] {
    const out: MapPixel[] = [];
    const ids: string[] = [];
    for (let i = 0; i < this.snapshot.profile.cards.length; i += 1) {
      ids.push(this.snapshot.profile.cards[i].placeID);
    }
    const points: GeoPoint[] = occupiedPoints(ids, this.snapshot.places);
    const stats: TerritoryStats = territoryStats(points);
    if (stats.hull.length < 3) return out;
    const hullGeo: GeoPoint[] = hullToGeoPoints(stats.hull, points);
    for (let i = 0; i < hullGeo.length; i += 1) {
      out.push(this.project(hullGeo[i]));
    }
    return out;
  }

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
      // 走路断成几段（停车/信号中断）时分别抽稀、分别成线，
      // 否则跨段的直线会把两段路连成一条根本不存在的轨迹。
      const segments: WalkPoint[][] = splitTrackSegments(entry.points);
      const visible: WalkPoint[][] = [];
      for (let j = 0; j < segments.length; j += 1) {
        if (segments[j].length >= 2) visible.push(segments[j]);
      }
      const segmentLimit: number = Math.min(visible.length, Math.floor(MAX_POINTS_PER_DAY / 2));
      if (segmentLimit === 0) continue;
      const perSegment: number = Math.max(2, Math.floor(MAX_POINTS_PER_DAY / segmentLimit));
      for (let j = 0; j < segmentLimit; j += 1) {
        const source: WalkPoint[] = visible[Math.floor(j * visible.length / segmentLimit)];
        const coordinates: GeoPoint[] = [];
        for (let k = 0; k < source.length; k += 1) {
          coordinates.push({ latitude: source[k].latitude, longitude: source[k].longitude });
        }
        lines.push(new DayLine(entry.day, i, simplifyPoints(coordinates, perSegment)));
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
      this.loadedBasemapUrl = '';
      return;
    }
    const minGcj: GeoPoint = wgs84ToGcj02(bounds[0], bounds[2]);
    const maxGcj: GeoPoint = wgs84ToGcj02(bounds[1], bounds[3]);
    this.centerLat = (minGcj.latitude + maxGcj.latitude) / 2;
    this.centerLon = (minGcj.longitude + maxGcj.longitude) / 2;
    const fitted: number = fitZoom(
      minGcj.latitude, maxGcj.latitude, minGcj.longitude, maxGcj.longitude,
      this.canvasWidth, MAP_HEIGHT, 44
    );
    // 初始框选上限到 15 级（约 1 公里视野），给单点或紧邻点留出继续放大的空间
    this.zoom = Math.max(MIN_ZOOM, Math.min(FIT_MAX_INITIAL_ZOOM, fitted));
    this.userMoved = false;
    this.refreshBasemap();
  }

  /** 更新比例尺文案 + 已加载底图的实时墨卡托对齐变换 */
  private syncScaleAndTransform(): void {
    if (this.centerLat === 0 && this.centerLon === 0) {
      this.basemapScale = 1;
      this.basemapOffsetX = 0;
      this.basemapOffsetY = 0;
      return;
    }
    const mpp: number = metersPerPixel(this.centerLat, this.zoom);
    const metersAcross: number = mpp * this.canvasWidth;
    this.scaleText = metersAcross >= 1000
      ? (metersAcross / 1000).toFixed(1) + ' 公里宽'
      : Math.round(metersAcross) + ' 米宽';

    if (this.loadedBasemapUrl.length === 0 ||
      (this.loadedViewport.centerLat === 0 && this.loadedViewport.centerLon === 0)) {
      this.basemapScale = 1;
      this.basemapOffsetX = 0;
      this.basemapOffsetY = 0;
      return;
    }
    const current: MapViewport = this.viewport();
    const scale: number = Math.pow(2, current.zoom - this.loadedViewport.zoom);
    const loadedCenterInCurrent: MapPixel = worldPixel(
      this.loadedViewport.centerLat,
      this.loadedViewport.centerLon,
      current.zoom
    );
    const currentCenter: MapPixel = worldPixel(
      current.centerLat,
      current.centerLon,
      current.zoom
    );
    this.basemapScale = scale;
    this.basemapOffsetX = loadedCenterInCurrent.x - currentCenter.x;
    this.basemapOffsetY = loadedCenterInCurrent.y - currentCenter.y;
  }

  /** 请求匹配当前视窗的高清静态底图，同时立即重算当前底图与标记的对齐位置 */
  private refreshBasemap(): void {
    if (this.centerLat === 0 && this.centerLon === 0) {
      this.basemapUrl = '';
      this.draw();
      return;
    }
    this.syncScaleAndTransform();

    if (this.hasKey && this.mapKey.length > 0) {
      const tileZoom: number = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, Math.round(this.zoom)));
      const requestVp: MapViewport = new MapViewport(this.centerLat, this.centerLon, tileZoom);
      this.pendingViewport = requestVp;
      this.basemapUrl = staticMapUrl(requestVp, this.canvasWidth, MAP_HEIGHT, this.mapKey);
    } else {
      this.basemapUrl = '';
      this.loadedBasemapUrl = '';
    }
    this.draw();
  }

  /** 新底图在后台解码完成后原子切换，消除网络延迟期间底图与地点的错位 */
  private commitLoadedBasemap(url: string): void {
    if (url.length === 0) return;
    this.loadedBasemapUrl = url;
    this.loadedViewport = new MapViewport(
      this.pendingViewport.centerLat,
      this.pendingViewport.centerLon,
      this.pendingViewport.zoom
    );
    this.syncScaleAndTransform();
    this.draw();
  }

  /** 围绕画布指定焦点缩放（支持 3..19 连续缩放） */
  private zoomAtFocalPoint(
    viewport: MapViewport,
    targetZoom: number,
    focalX: number,
    focalY: number
  ): MapViewport {
    const zoom: number = Math.max(MIN_ZOOM, Math.min(MAX_DISPLAY_ZOOM, targetZoom));
    if (zoom <= MAX_ZOOM && viewport.zoom <= MAX_ZOOM) {
      return zoomViewportAtPoint(viewport, zoom, focalX, focalY, this.canvasWidth, MAP_HEIGHT);
    }
    const offsetX: number = focalX - this.canvasWidth / 2;
    const offsetY: number = focalY - MAP_HEIGHT / 2;
    const oldCenter: MapPixel = worldPixel(viewport.centerLat, viewport.centerLon, viewport.zoom);
    const focalGeoPixel: MapPixel = new MapPixel(oldCenter.x + offsetX, oldCenter.y + offsetY);
    const focalGeo: MapPixel = worldPixelToLatLon(focalGeoPixel, viewport.zoom);
    const focalAtZoom: MapPixel = worldPixel(focalGeo.x, focalGeo.y, zoom);
    const nextCenterPixel: MapPixel = new MapPixel(focalAtZoom.x - offsetX, focalAtZoom.y - offsetY);
    const center: MapPixel = worldPixelToLatLon(nextCenterPixel, zoom);
    return new MapViewport(center.x, center.y, zoom);
  }

  /** 缩放一档（dir = +1 放大 / -1 缩小） */
  private zoomBy(dir: number): void {
    if (this.centerLat === 0 && this.centerLon === 0) return;
    const base: number = dir > 0 ? Math.floor(this.zoom + 0.001) : Math.ceil(this.zoom - 0.001);
    const next: number = Math.max(MIN_ZOOM, Math.min(MAX_DISPLAY_ZOOM, base + dir));
    if (Math.abs(next - this.zoom) < 0.01) return;
    this.zoom = next;
    this.userMoved = true;
    this.refreshBasemap();
  }

  /** 单指拖动开始 */
  private beginPan(): void {
    if (this.centerLat === 0 && this.centerLon === 0) return;
    if (this.pinchActive || this.multiTouchActive) return;
    this.panStartViewport = new MapViewport(this.centerLat, this.centerLon, this.zoom);
    this.panActive = true;
    this.mapInteracting = true;
  }

  /** 单指拖动中：实时推进视窗中心，底图与地点同帧重绘 */
  private updatePan(deltaX: number, deltaY: number): void {
    if (!this.panActive || this.pinchActive || this.multiTouchActive) return;
    if (!isFinite(deltaX) || !isFinite(deltaY)) return;
    const moved: MapViewport = panViewport(this.panStartViewport, deltaX, deltaY);
    this.centerLat = moved.centerLat;
    this.centerLon = moved.centerLon;
    this.userMoved = true;
    this.syncScaleAndTransform();
    this.draw();
  }

  /** 单指拖动结束：后台请求新位置的高清底图 */
  private finishPan(): void {
    if (!this.panActive) return;
    this.panActive = false;
    this.refreshBasemap();
  }

  private clampFocalX(x: number): number {
    if (!isFinite(x) || x <= 0) return this.canvasWidth / 2;
    return Math.max(0, Math.min(this.canvasWidth, x));
  }

  private clampFocalY(y: number): number {
    if (!isFinite(y) || y <= 0) return MAP_HEIGHT / 2;
    return Math.max(0, Math.min(MAP_HEIGHT, y));
  }

  private beginPinch(event: GestureEvent): void {
    if (this.centerLat === 0 && this.centerLon === 0) return;
    this.panActive = false;
    this.pinchStartViewport = new MapViewport(this.centerLat, this.centerLon, this.zoom);
    this.pinchStartZoom = this.zoom;
    this.pinchCenterX = this.clampFocalX(event.pinchCenterX);
    this.pinchCenterY = this.clampFocalY(event.pinchCenterY);
    this.pinchActive = true;
    this.mapInteracting = true;
    this.userMoved = true;
  }

  private updatePinch(event: GestureEvent): void {
    if (!this.pinchActive) return;
    const safeScale: number = isFinite(event.scale) && event.scale > 0.05 ? event.scale : 1;
    const rawZoom: number = this.pinchStartZoom + Math.log(safeScale) / Math.LN2;
    const nextZoom: number = Math.max(MIN_ZOOM, Math.min(MAX_DISPLAY_ZOOM, rawZoom));
    const zoomed: MapViewport = this.zoomAtFocalPoint(
      this.pinchStartViewport,
      nextZoom,
      this.pinchCenterX,
      this.pinchCenterY
    );
    const curFocalX: number = this.clampFocalX(event.pinchCenterX);
    const curFocalY: number = this.clampFocalY(event.pinchCenterY);
    const moved: MapViewport = panViewport(
      zoomed,
      curFocalX - this.pinchCenterX,
      curFocalY - this.pinchCenterY
    );
    this.zoom = moved.zoom;
    this.centerLat = moved.centerLat;
    this.centerLon = moved.centerLon;
    this.syncScaleAndTransform();
    this.draw();
  }

  private finishPinch(): void {
    if (!this.pinchActive) return;
    this.pinchActive = false;
    this.refreshBasemap();
  }

  /**
   * 重算文字标签（与圆点同一次 draw 在 Canvas 内绘制，彻底消除组件叠层不同步与错位）。
   *
   * 重叠处理：按屏幕位置取前 MAX_LABELS 个，两两间距 < 64vp 的只保留第一个。
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

  /** 在 Canvas 上绘制地点名胶囊（与圆点同一帧同一坐标系，水平严格居中） */
  private drawPlaceLabel(ctx: CanvasRenderingContext2D, label: PlaceLabel): void {
    const rawName: string = label.name.trim();
    if (rawName.length === 0) return;
    const text: string = rawName.length > 8 ? rawName.substring(0, 7) + '…' : rawName;
    ctx.save();
    ctx.font = '500 10vp sans-serif';
    let textWidth: number = 0;
    try {
      textWidth = ctx.measureText(text).width;
    } catch (err) {
      textWidth = text.length * 10;
    }
    if (!isFinite(textWidth) || textWidth <= 0) {
      textWidth = text.length * 10;
    }
    const padX: number = 6;
    const pillW: number = Math.min(116, Math.max(28, textWidth + padX * 2));
    const pillH: number = 18;
    const pillX: number = Math.max(4, Math.min(this.canvasWidth - pillW - 4, label.x - pillW / 2));
    const pillY: number = label.y + 9;
    const r: number = 5;

    ctx.beginPath();
    ctx.moveTo(pillX + r, pillY);
    ctx.lineTo(pillX + pillW - r, pillY);
    ctx.arcTo(pillX + pillW, pillY, pillX + pillW, pillY + r, r);
    ctx.lineTo(pillX + pillW, pillY + pillH - r);
    ctx.arcTo(pillX + pillW, pillY + pillH, pillX + pillW - r, pillY + pillH, r);
    ctx.lineTo(pillX + r, pillY + pillH);
    ctx.arcTo(pillX, pillY + pillH, pillX, pillY + pillH - r, r);
    ctx.lineTo(pillX, pillY + r);
    ctx.arcTo(pillX, pillY, pillX + r, pillY, r);
    ctx.closePath();

    ctx.fillStyle = '#E6FFFFFF';
    ctx.fill();
    ctx.strokeStyle = '#33182431';
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.fillStyle = WAColor.ink;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, pillX + pillW / 2, pillY + pillH / 2);
    ctx.restore();
  }

  /** 底图尚未加载完成或无 Key 时，绘制随视窗缩放/平移的墨卡托网格底图 */
  private drawBackdropGrid(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    ctx.save();
    ctx.fillStyle = '#F2EEE6';
    ctx.fillRect(0, 0, width, height);
    if (this.centerLat === 0 && this.centerLon === 0) {
      ctx.restore();
      return;
    }
    const vp: MapViewport = this.viewport();
    const baseZoom: number = Math.floor(vp.zoom);
    const fracScale: number = Math.pow(2, vp.zoom - baseZoom);
    const step: number = 48 * fracScale;
    const centerWorld: MapPixel = worldPixel(vp.centerLat, vp.centerLon, vp.zoom);
    const offsetX: number = ((width / 2 - centerWorld.x) % step + step) % step;
    const offsetY: number = ((height / 2 - centerWorld.y) % step + step) % step;
    ctx.strokeStyle = '#14182431';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = offsetX; x < width; x += step) {
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
    }
    for (let y = offsetY; y < height; y += step) {
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
    }
    ctx.stroke();
    ctx.restore();
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
    // 底图由 Image(loadedBasemapUrl) 铺在下面；底图未就绪时画随视窗联动的网格底色
    if (this.loadedBasemapUrl.length === 0) {
      this.drawBackdropGrid(ctx, width, height);
    }

    if (this.centerLat === 0 && this.centerLon === 0) return;

    // ---------- 轨迹（按天；越新越亮） ----------
    const lines: DayLine[] = this.dayLines();
    ctx.lineCap = 'round';
    for (let i = 0; i < lines.length; i += 1) {
      const points: GeoPoint[] = lines[i].points;
      if (points.length < 2) continue;
      ctx.globalAlpha = trackOpacity(lines[i].rank);
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

    // ---------- 疆域多边形（docs/territory.md §展示要求 2） ----------
    //
    // 顺序：轨迹 → 地点圆点 → **疆域多边形**（叠在上面）。
    // 填充爵位色 20%、描边 2.5、凸包顶点画白底小圆（与 Web mymapHTML 一致）。
    // 无疆域时**一个点都不画**，绝不画假多边形。
    const hullPixels: MapPixel[] = this.territoryHullPixels();
    if (hullPixels.length >= 3) {
      const rankColor: string = this.territoryRankColor;
      const fallbackFill: string = rankColor + '33';

      // ① 面：爵位色 20% 半透明（用 globalAlpha = 0.2 避免鸿蒙 #AARRGGBB 解析把红通道当成不透明度）
      ctx.save();
      ctx.beginPath();
      for (let i = 0; i < hullPixels.length; i += 1) {
        if (i === 0) {
          ctx.moveTo(hullPixels[i].x, hullPixels[i].y);
        } else {
          ctx.lineTo(hullPixels[i].x, hullPixels[i].y);
        }
      }
      ctx.closePath();
      ctx.globalAlpha = 0.2;
      ctx.fillStyle = rankColor.length > 0 ? rankColor : fallbackFill;
      ctx.fill();
      ctx.restore();

      // ② 描边：爵位色，线宽 2.5
      ctx.strokeStyle = rankColor;
      ctx.lineWidth = 2.5;
      ctx.lineJoin = 'round';
      ctx.stroke();

      // ③ 凸包顶点：白底 + 爵位色描边（与「占领点」区分开）
      for (let i = 0; i < hullPixels.length; i += 1) {
        ctx.beginPath();
        ctx.arc(hullPixels[i].x, hullPixels[i].y, 6.5, 0, Math.PI * 2);
        ctx.fillStyle = WAColor.paper;
        ctx.fill();
        ctx.strokeStyle = rankColor;
        ctx.lineWidth = 2.5;
        ctx.stroke();
      }
    }

    // ④ 地点文字标签（直接画在 Canvas 上，与圆点/凸包同帧随动）
    this.refreshLabels();
    for (let i = 0; i < this.labels.length; i += 1) {
      this.drawPlaceLabel(ctx, this.labels[i]);
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

  /**
   * 疆域卡（统计卡下方）
   *
   * 有疆域：印章 + 爵位 + 面积/地点/跨度 + 进度
   * 无疆域：明确说「还差几个点」，**不显示 0 m² 的假数据行**
   */
  @Builder
  territoryCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(44)
            .height(44)
            .fill(this.territoryRankColor)
          Text(this.territorySeal)
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.iconOnBrand)
        }

        Column({ space: 2 }) {
          Text(this.territoryRankTitle)
            .fontSize(WAFont.titleSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
            .maxLines(1)
          Text(this.territoryRankDesc)
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ink2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.territoryHasArea) {
        // 三项数据（内联，不用 WaStatsRow：那个组件自带白底卡片，嵌在卡里会双重描边）
        Row() {
          this.territoryMetric(this.territoryAreaText, '疆域面积')
          Divider().vertical(true).height(24).strokeWidth(1).color(WAColor.line)
          this.territoryMetric(this.territoryPointText, '占领地点')
          Divider().vertical(true).height(24).strokeWidth(1).color(WAColor.line)
          this.territoryMetric(this.territorySpanText, '最长跨度')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Column({ space: 5 }) {
          WaProgressBar({
            progress: this.territoryProgress,
            barColor: this.territoryRankColor,
            trackColor: WAColor.line,
            barHeight: 6
          })
          // 被点数卡住时文案较长，允许 2 行并用警示色（docs §三 UI 要求）
          Text(this.territoryProgressText)
            .fontSize(WAFont.microSm)
            .fontColor(this.territoryCapped ? WAColor.ember : WAColor.ink2)
            .maxLines(this.territoryCapped ? 2 : 1)
            .lineHeight(15)
            .width('100%')
        }
        .width('100%')

        Text(this.formatHullNote())
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .maxLines(2)
          .lineHeight(15)
          .width('100%')
      } else {
        Text(this.territoryProgressText)
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
          .width('100%')
          .lineHeight(18)
        Text('开盒后去「我的城市」看看，真实地点会一块块连起来。')
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink3)
          .width('100%')
          .lineHeight(16)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
  }

  /** 疆域数据行里的一个指标 */
  @Builder
  territoryMetric(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(WAFont.titleSm)
        .fontWeight(FontWeight.Medium)
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

  /** 「X 的疆域由 N 个边界点围成」（与 Web mymapHTML 的 note 一致） */
  private formatHullNote(): string {
    if (!this.territoryHasArea) return '至少 3 个真实地点才能围成一片疆域';
    return this.territoryAreaText + ' 的疆域由 ' + String(this.territoryHullCount) +
      ' 个边界点围成 · 再开新地点可以扩大范围';
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
    // 结构说明：
    //   1. 已加载底图（loadedBasemapUrl）通过墨卡托缩放+位移实时对齐当前视窗，
    //      新底图（basemapUrl）在后台静默加载，onComplete 解码完成后再原子切换，
    //      彻底消除缩放/拖动时「地点先跳、底图半秒后才动」的不同步问题。
    //   2. 轨迹、地点圆点、疆域半透明凸包与文字标签全部在同一 Canvas 同帧绘制。
    //   3. 手势层固定不动，按下即锁定外层 Scroll（mapInteracting = true）并拦截 Pan/Pinch，
    //      彻底杜绝在地图内拖动时带动整个页面滚动。
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 已就绪的真实地图底图：随当前视窗实时缩放与平移
      if (this.loadedBasemapUrl.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.loadedBasemapUrl)
            .width('100%')
            .height(MAP_HEIGHT)
            .objectFit(ImageFit.Fill)
            .interpolation(ImageInterpolation.High)
            .scale({
              x: this.basemapScale,
              y: this.basemapScale,
              centerX: '50%',
              centerY: '50%'
            })
        }
        .width('100%')
        .height(MAP_HEIGHT)
        .translate({ x: this.basemapOffsetX, y: this.basemapOffsetY })
      }

      // ①-b 后台预加载的新底图：解码完成后原子替换 loadedBasemapUrl
      if (this.basemapUrl.length > 0 && this.basemapUrl !== this.loadedBasemapUrl) {
        Image(this.basemapUrl)
          .width('100%')
          .height(MAP_HEIGHT)
          .objectFit(ImageFit.Fill)
          .opacity(0.01)
          .onComplete((event) => {
            if (event !== undefined && (event.loadingStatus === 1 ||
              (this.loadedBasemapUrl.length === 0 && event.width > 0))) {
              this.commitLoadedBasemap(this.basemapUrl);
            }
          })
      }

      // ② 轨迹、地点圆点、半透明疆域凸包与地点标签（与底图共用墨卡托投影，严格同帧对齐）
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

      // ③ 手势层：透明、固定不动，独占地图区域内的单指拖动与双指缩放，阻止外层页面滚动
      Column()
        .width('100%')
        .height(MAP_HEIGHT)
        .backgroundColor('#00000000')
        .onTouch((event: TouchEvent) => {
          event.stopPropagation();
          if (event.touches.length > 1) {
            this.multiTouchActive = true;
            this.mapInteracting = true;
            return;
          }
          if (event.type === TouchType.Down) {
            this.multiTouchActive = false;
            this.mapInteracting = true;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.multiTouchActive = false;
            if (!this.pinchActive && !this.panActive) {
              this.mapInteracting = false;
            }
          }
        })
        .priorityGesture(
          GestureGroup(
            GestureMode.Parallel,
            PanGesture({ fingers: 1, distance: 1 })
              .onActionStart(() => {
                this.beginPan();
              })
              .onActionUpdate((event: GestureEvent) => {
                this.updatePan(event.offsetX, event.offsetY);
              })
              .onActionEnd(() => {
                this.finishPan();
                if (!this.pinchActive) {
                  this.mapInteracting = false;
                }
              })
              .onActionCancel(() => {
                this.finishPan();
                if (!this.pinchActive) {
                  this.mapInteracting = false;
                }
              }),
            PinchGesture({ fingers: 2, distance: 2 })
              .onActionStart((event: GestureEvent) => {
                this.beginPinch(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.updatePinch(event);
              })
              .onActionEnd(() => {
                this.finishPinch();
                this.multiTouchActive = false;
                this.mapInteracting = false;
              })
              .onActionCancel(() => {
                this.finishPinch();
                this.multiTouchActive = false;
                this.mapInteracting = false;
              })
          )
        )

      // ④ 缩放与复位按钮（右上角，位于手势层之上）
      Column({ space: 6 }) {
        this.zoomButton('+', () => {
          this.zoomBy(1);
        })
        this.zoomButton('−', () => {
          this.zoomBy(-1);
        })
        this.zoomButton('⌖', () => {
          this.resetView();
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

      Scroll(this.pageScroller) {
        Column({ space: 0 }) {
          this.header()

          Column() {
            this.statsCard()
          }
          .margin({ top: 6 })

          Column() {
            this.territoryCard()
          }
          .margin({ top: 12 })

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
      .scrollable(this.mapInteracting ? ScrollDirection.None : ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }
}
