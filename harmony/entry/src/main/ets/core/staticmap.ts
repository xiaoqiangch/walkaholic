/**
 * 步迷 Walkaholic · HarmonyOS 逻辑层 — 真实静态地图（高德 staticmap）
 *
 * 为什么用它：个人城市地图需要**真地图**当底图（路网、水系、地名），
 * 而鸿蒙没有 MapKit（要 AGC 配置 + 版权流程），自己拼瓦片又要处理授权与坐标系。
 * 高德 staticmap 是「一个 URL 换一张真地图」，最省事也最稳。
 *
 * 纯计算（可 Node 单测）：墨卡托投影 / 自动选缩放 / 拼 URL / 经纬度 → 画布像素。
 * 真正的图片加载交给 ArkUI 的 Image()（它原生支持网络图片）。
 */

/** 瓦片边长（Web 墨卡托的基准尺度） */
export const TILE_SIZE: number = 256;

/** 高德 staticmap 的缩放范围 */
export const MIN_ZOOM: number = 3;
export const MAX_ZOOM: number = 17;

/** 画布中心点（GCJ-02）与缩放 */
export class MapViewport {
  centerLat: number = 0;
  centerLon: number = 0;
  zoom: number = 15;

  constructor(centerLat: number, centerLon: number, zoom: number) {
    this.centerLat = centerLat;
    this.centerLon = centerLon;
    this.zoom = zoom;
  }
}

export class MapPixel {
  x: number = 0;
  y: number = 0;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

/**
 * 经纬度 → 世界像素（Web 墨卡托，与高德/OSM 完全一致）。
 * 返回值是「该缩放级别下整张世界地图的像素坐标」。
 */
export function worldPixel(latitude: number, longitude: number, zoom: number): MapPixel {
  const scale: number = TILE_SIZE * Math.pow(2, zoom);
  const lat: number = Math.max(-85.05112878, Math.min(85.05112878, latitude));
  const x: number = (longitude + 180) / 360 * scale;
  const sinLat: number = Math.sin(lat * Math.PI / 180);
  const y: number = (0.5 - Math.log((1 + sinLat) / (1 - sinLat)) / (4 * Math.PI)) * scale;
  return new MapPixel(x, y);
}

/**
 * 经纬度 → 画布像素。
 *
 * 画布上显示的是一张以 viewport 为中心、边长 = width×height 的静态图，
 * 所以「点相对中心的墨卡托偏移」直接就是画布偏移 —— 与 Image(url) 严格对齐。
 */
export function projectToCanvas(
  latitude: number,
  longitude: number,
  viewport: MapViewport,
  width: number,
  height: number
): MapPixel {
  const world: MapPixel = worldPixel(latitude, longitude, viewport.zoom);
  const center: MapPixel = worldPixel(viewport.centerLat, viewport.centerLon, viewport.zoom);
  return new MapPixel(width / 2 + (world.x - center.x), height / 2 + (world.y - center.y));
}

/** 屏上 1 米等于多少像素（用于判断视野尺度） */
export function metersPerPixel(latitude: number, zoom: number): number {
  const earth: number = 6378137;
  return Math.cos(latitude * Math.PI / 180) * 2 * Math.PI * earth / (TILE_SIZE * Math.pow(2, zoom));
}

/**
 * 自动选缩放级别：让给定的经纬范围刚好装进 width×height（留 padding）。
 * 从最细往粗找，第一个「装得下」的即采用。
 */
export function fitZoom(
  minLat: number,
  maxLat: number,
  minLon: number,
  maxLon: number,
  width: number,
  height: number,
  paddingPx: number
): number {
  const usableW: number = Math.max(48, width - paddingPx * 2);
  const usableH: number = Math.max(48, height - paddingPx * 2);
  for (let zoom = MAX_ZOOM; zoom >= MIN_ZOOM; zoom -= 1) {
    const a: MapPixel = worldPixel(maxLat, minLon, zoom);
    const b: MapPixel = worldPixel(minLat, maxLon, zoom);
    const spanX: number = Math.abs(b.x - a.x);
    const spanY: number = Math.abs(b.y - a.y);
    if (spanX <= usableW && spanY <= usableH) return zoom;
  }
  return MIN_ZOOM;
}

/** 世界像素 → 经纬度（墨卡托反算），用于拖动平移 */
export function worldPixelToLatLon(pixel: MapPixel, zoom: number): MapPixel {
  const scale: number = TILE_SIZE * Math.pow(2, zoom);
  const x: number = (pixel.x / scale) - 0.5;
  const y: number = 0.5 - (pixel.y / scale);
  const lon: number = 360 * x;
  const lat: number = 90 - 360 * Math.atan(Math.exp(-y * 2 * Math.PI)) / Math.PI;
  // 复用 MapPixel 承载 (lat, lon)，避免再引入一个类型
  return new MapPixel(lat, lon);
}

/**
 * 拖动平移：给定画布像素位移，返回新的视窗。
 *
 * 方向约定与真实地图一致：手指往右拖，地图跟着往右走，于是「中心」往左移。
 */
export function panViewport(
  viewport: MapViewport,
  deltaX: number,
  deltaY: number
): MapViewport {
  const center: MapPixel = worldPixel(viewport.centerLat, viewport.centerLon, viewport.zoom);
  const moved: MapPixel = new MapPixel(center.x - deltaX, center.y - deltaY);
  const latLon: MapPixel = worldPixelToLatLon(moved, viewport.zoom);
  return new MapViewport(latLon.x, latLon.y, viewport.zoom);
}

/**
 * 高德静态地图 URL。
 *
 * 注意坐标系：高德吃的是 **GCJ-02**，调用方必须先把 WGS-84 转好再传进来
 * （core/geo.ts 的 `wgs84ToGcj02`）。
 *
 * size 上限 1024；scale=2 返回高清（实际像素翻倍），这里固定用高清保证文字清楚。
 */
export function staticMapUrl(
  viewport: MapViewport,
  width: number,
  height: number,
  key: string
): string {
  const w: number = Math.round(Math.min(1024, Math.max(64, width)));
  const h: number = Math.round(Math.min(1024, Math.max(64, height)));
  return 'https://restapi.amap.com/v3/staticmap' +
    '?location=' + viewport.centerLon.toFixed(6) + ',' + viewport.centerLat.toFixed(6) +
    '&zoom=' + String(Math.round(viewport.zoom)) +
    '&size=' + String(w) + '*' + String(h) +
    '&scale=2' +
    '&key=' + key;
}

/** 距离（米）：供「缩放到刚好装下」与比例尺文案用 */
export function approxMeters(
  minLat: number, maxLat: number, minLon: number, maxLon: number
): number[] {
  const centerLat: number = (minLat + maxLat) / 2;
  const latMeters: number = Math.abs(maxLat - minLat) * 110540;
  const lonMeters: number = Math.abs(maxLon - minLon) * 111320 * Math.cos(centerLat * Math.PI / 180);
  return [latMeters, lonMeters];
}
