/**
 * 步迷 Walkaholic · HarmonyOS 逻辑层 — 疆域与爵位
 *
 * 唯一规格：docs/territory.md；Web 参考实现：prototype/web/territory.js（9 项单测）。
 * 三端（Web / iOS / HarmonyOS）的爵位表、算法、格式化必须逐字/逐值一致。
 *
 * ## 概念
 * - 每个「成功开盒」的**真实地点**（必须有真实坐标）= 一个已占领的点
 * - 这些点的**凸包面积** = 用户的「疆域」
 * - 疆域面积决定爵位（中国古代五等爵 + 扩展）
 *
 * 为什么用凸包：要的是「围起来的最大面积」。凸包 = 能包住所有点的最小凸多边形，
 * 也就是用户能围出的最大地盘。不是逐点算，是整体版图。
 *
 * **只统计真实地点**：内置演示地点没有真实坐标，不计入疆域（与「不造假」原则一致）。
 *
 * 纯函数、零 `@ohos.*` 依赖，可在 Node 里直接测。
 */

import { GeoPoint, Place } from './types';

// ============================================================
// 1. 中国古代爵位体系（docs/territory.md 表格，逐字一致）
//
// 周代五等爵：公、侯、伯、子、男（公爵最高）
// 之下设「士」，之上设「王」（加分项，需极大疆域）
// ============================================================

export interface TerritoryRank {
  key: string;
  /** 序号 0…7（越大越高） */
  order: number;
  /** 爵位名 */
  title: string;
  /** 印章字（圆形印章里那一个汉字） */
  seal: string;
  /** 门槛：平方公里 */
  thresholdKm2: number;
  /**
   * 最少探索点数（docs/territory.md §三、点数门槛）。
   *
   * 为什么需要：凸包只看面积 → 在远处 4 个角各开一个盲盒就能围出上千 km² 直接封王。
   * 加一条「最少点数」后，4 点围 1163 km² 会从「王」降到「士」。
   */
  minPoints: number;
  /** 主色（#RRGGBB） */
  color: string;
  /** 释义（一句话） */
  desc: string;
}

export const TERRITORY_RANKS: TerritoryRank[] = [
  { key: 'commoner', order: 0, title: '白身', seal: '民', thresholdKm2: 0, minPoints: 0, color: '#9CA3AF', desc: '还没有自己的疆域' },
  { key: 'shi', order: 1, title: '士', seal: '士', thresholdKm2: 0.05, minPoints: 3, color: '#64748B', desc: '初立门户，方寸之地' },
  { key: 'nan', order: 2, title: '男爵', seal: '男', thresholdKm2: 0.3, minPoints: 5, color: '#0EA5E9', desc: '一街一巷，始有封地' },
  { key: 'zi', order: 3, title: '子爵', seal: '子', thresholdKm2: 1.2, minPoints: 7, color: '#14B8A6', desc: '数坊之间，渐成版图' },
  { key: 'bo', order: 4, title: '伯爵', seal: '伯', thresholdKm2: 4, minPoints: 9, color: '#5B6CFF', desc: '半城风物，已在掌中' },
  { key: 'hou', order: 5, title: '侯爵', seal: '侯', thresholdKm2: 12, minPoints: 12, color: '#8B5CF6', desc: '纵横十余里，一方之望' },
  { key: 'gong', order: 6, title: '公爵', seal: '公', thresholdKm2: 30, minPoints: 15, color: '#F59E0B', desc: '半壁城池，位极人臣' },
  { key: 'wang', order: 7, title: '王', seal: '王', thresholdKm2: 80, minPoints: 21, color: '#EF4444', desc: '一城之主，疆域无出其右' }
];

/** 最低爵位（白身） */
export function baseRank(): TerritoryRank {
  return TERRITORY_RANKS[0];
}

/** 最高爵位（王） */
export function topRank(): TerritoryRank {
  return TERRITORY_RANKS[TERRITORY_RANKS.length - 1];
}

/** 按 key 找爵位；找不到返回白身 */
export function rankByKey(key: string): TerritoryRank {
  for (let i = 0; i < TERRITORY_RANKS.length; i += 1) {
    if (TERRITORY_RANKS[i].key === key) return TERRITORY_RANKS[i];
  }
  return baseRank();
}

// ============================================================
// 2. 几何：投影 / 凸包 / 面积
// ============================================================

/** 平面坐标（米） */
export interface PlanePoint {
  x: number;
  y: number;
}

/**
 * 叉积容差（单位 **m²**）。
 *
 * 这是本文件最关键的一个常量（Web 版踩过的坑）：
 * 严格用 `cross > 0` 判「左转」时，浮点误差会让共线的三点偶尔被判成左转，
 * 于是凸包里留下一个面积约 1e-12 m² 的退化细长三角 —— 面积还是对的，
 * 但顶点数、跨度和画出来的形状都会错。
 * `<= 0.5 m²` 以下一律视为共线并弹出，城市尺度下 0.5 m² 完全无意义，可安全忽略。
 */
export const COLLINEAR_EPS_M2: number = 0.5;

/** 地球经纬度 → 米：赤道经度 1° 的米数 */
const METERS_PER_DEGREE_LAT: number = 110540;
/** 赤道纬度 1° 的米数（乘 cos(meanLat) 得到实际值） */
const METERS_PER_DEGREE_LON_EQUATOR: number = 111320;

/**
 * 把经纬度投影到本地平面（米）。
 * 以所有点的**平均纬度**做等距圆柱近似 —— 城市尺度（几公里）足够准，
 * 且比墨卡托简单、没有极点问题。
 *
 * origin = 第一个点（与 Web 版一致），所以同一批点的投影结果可复现。
 */
export function projectMeters(points: GeoPoint[]): PlanePoint[] {
  const out: PlanePoint[] = [];
  if (points.length === 0) return out;

  let sumLat: number = 0;
  for (let i = 0; i < points.length; i += 1) sumLat += points[i].latitude;
  const meanLat: number = sumLat / points.length;
  const kx: number = Math.cos(meanLat * Math.PI / 180) * METERS_PER_DEGREE_LON_EQUATOR;
  const ky: number = METERS_PER_DEGREE_LAT;
  const origin: GeoPoint = points[0];

  for (let i = 0; i < points.length; i += 1) {
    const point: PlanePoint = {
      x: (points[i].longitude - origin.longitude) * kx,
      y: (points[i].latitude - origin.latitude) * ky
    };
    out.push(point);
  }
  return out;
}

/** 三点叉积（m²；>0 = 左转） */
function cross(o: PlanePoint, a: PlanePoint, b: PlanePoint): number {
  return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

/**
 * Andrew 单调链求凸包，返回**逆时针**点序。
 *
 * 共线容差见 `COLLINEAR_EPS_M2`：`cross <= EPS` 一律当作「不是左转」并弹出。
 */
export function convexHull(flatPoints: PlanePoint[]): PlanePoint[] {
  const sorted: PlanePoint[] = flatPoints.slice();
  sorted.sort((a: PlanePoint, b: PlanePoint): number => {
    if (a.x === b.x) return a.y - b.y;
    return a.x - b.x;
  });

  // 去重（排序后相邻比较即可）
  const uniq: PlanePoint[] = [];
  for (let i = 0; i < sorted.length; i += 1) {
    if (i === 0) {
      uniq.push(sorted[i]);
      continue;
    }
    const last: PlanePoint = uniq[uniq.length - 1];
    if (sorted[i].x !== last.x || sorted[i].y !== last.y) uniq.push(sorted[i]);
  }
  if (uniq.length <= 2) return uniq;

  const lower: PlanePoint[] = [];
  for (let i = 0; i < uniq.length; i += 1) {
    while (lower.length >= 2 &&
      cross(lower[lower.length - 2], lower[lower.length - 1], uniq[i]) <= COLLINEAR_EPS_M2) {
      lower.pop();
    }
    lower.push(uniq[i]);
  }

  const upper: PlanePoint[] = [];
  for (let i = uniq.length - 1; i >= 0; i -= 1) {
    while (upper.length >= 2 &&
      cross(upper[upper.length - 2], upper[upper.length - 1], uniq[i]) <= COLLINEAR_EPS_M2) {
      upper.pop();
    }
    upper.push(uniq[i]);
  }

  lower.pop();
  upper.pop();
  return lower.concat(upper);
}

/** 鞋带公式求多边形面积（平方米）；顶点 < 3 → 0 */
export function polygonAreaM2(hull: PlanePoint[]): number {
  if (hull.length < 3) return 0;
  let sum: number = 0;
  for (let i = 0; i < hull.length; i += 1) {
    const a: PlanePoint = hull[i];
    const b: PlanePoint = hull[(i + 1) % hull.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return Math.abs(sum) / 2;
}

/** 平面两点距离 */
function planeDistance(a: PlanePoint, b: PlanePoint): number {
  const dx: number = a.x - b.x;
  const dy: number = a.y - b.y;
  return Math.sqrt(dx * dx + dy * dy);
}

// ============================================================
// 3. 疆域计算
// ============================================================

export interface TerritoryStats {
  /** 合法真实点总数（去重前） */
  pointCount: number;
  /** 凸包顶点（米，相对第一个点） */
  hull: PlanePoint[];
  hullPointCount: number;
  areaM2: number;
  areaKm2: number;
  /** 最长跨度：凸包顶点两两最大距离（米） */
  spanM: number;
}

/** 空疆域（点数不足 / 无坐标） */
export function emptyTerritory(pointCount: number): TerritoryStats {
  const stats: TerritoryStats = {
    pointCount: pointCount,
    hull: [],
    hullPointCount: 0,
    areaM2: 0,
    areaKm2: 0,
    spanM: 0
  };
  return stats;
}

/** 坐标是否合法（有限 / 范围内） */
export function isValidCoordinate(point: GeoPoint | undefined): boolean {
  if (point === undefined) return false;
  if (!isFinite(point.latitude) || !isFinite(point.longitude)) return false;
  if (Math.abs(point.latitude) > 90) return false;
  if (Math.abs(point.longitude) > 180) return false;
  return true;
}

/**
 * 由已占领的真实坐标点计算疆域。
 *
 * 规则（docs/territory.md §算法）：
 * 1. 过滤非法坐标
 * 2. 点数 < 3 → 面积 0、凸包为空
 * 3. 等距圆柱投影 → 凸包（共线容差 0.5 m²）→ 鞋带公式
 * 4. 跨度为凸包顶点两两最大距离
 */
export function territoryStats(points: GeoPoint[]): TerritoryStats {
  const valid: GeoPoint[] = [];
  for (let i = 0; i < points.length; i += 1) {
    if (isValidCoordinate(points[i])) valid.push(points[i]);
  }
  if (valid.length < 3) return emptyTerritory(valid.length);

  const flat: PlanePoint[] = projectMeters(valid);
  const hull: PlanePoint[] = convexHull(flat);
  const areaM2: number = polygonAreaM2(hull);

  let spanM: number = 0;
  for (let i = 0; i < hull.length; i += 1) {
    for (let j = i + 1; j < hull.length; j += 1) {
      const d: number = planeDistance(hull[i], hull[j]);
      if (d > spanM) spanM = d;
    }
  }

  const stats: TerritoryStats = {
    pointCount: valid.length,
    hull: hull,
    hullPointCount: hull.length,
    areaM2: areaM2,
    areaKm2: areaM2 / 1000000,
    spanM: spanM
  };
  return stats;
}

// ============================================================
// 4. 爵位判定 + 进度
// ============================================================

export interface TerritoryRankResult {
  rank: TerritoryRank;
  /**
   * 目标档：
   * - 被点数卡住时 = 被卡住的那一档（提示「再探索 M 个点」）
   * - 否则 = 面积上的下一档（提示「再扩 X km²」）
   * - 最高档且没被卡 = undefined
   */
  next?: TerritoryRank;
  /** 0…1：被点数卡住时按点数算，否则按面积算 */
  progress: number;
  /** 距下一档还差多少 km²（最高档 / 被点数卡住时为 0） */
  toNextKm2: number;
  /** 归一化后的面积（负数/NaN 夹到 0） */
  areaKm2: number;
  /** 传入的探索点数；未传时 undefined（保持旧行为） */
  pointCount?: number;
  /** 面积够格但因为点数不够被降到的档（= areaRank）；没被卡为 undefined */
  blockedBy?: TerritoryRank;
  /** 是否因为探索点太少被降级 */
  capped: boolean;
  /** 距下一档还差多少个探索点（不传点数时为 0） */
  pointsNeeded: number;
}

/**
 * 面积（+ 可选点数）→ 爵位 + 进度。
 *
 * 判定逻辑（docs/territory.md §三，三端一致）：
 * ```
 * areaRank  = 面积够格的最高一档
 * current   = 从 areaRank 往下找第一个「点数也够」的档
 * blockedBy = areaRank（若 areaRank.order > current.order）
 * capped    = blockedBy !== undefined
 * next      = capped ? blockedBy : current 的下一档
 * progress  = capped ? 按点数算 : 按面积算
 * ```
 *
 * **不传 `pointCount` 时完全保持旧行为**（只按面积判定，capped=false）。
 * 老调用方（测试/分享卡历史版本）不传参数也不会被点数门槛打回。
 */
export function territoryRank(areaKm2: number, pointCount?: number): TerritoryRankResult {
  let area: number = 0;
  if (typeof areaKm2 === 'number' && isFinite(areaKm2)) {
    area = Math.max(0, areaKm2);
  }
  // 点数：只有真的传了有效数字才参与判定（null/undefined/NaN 都算「未传」）
  let points: number | undefined = undefined;
  if (pointCount !== undefined && pointCount !== null && isFinite(pointCount)) {
    points = Math.max(0, pointCount);
  }

  // ① 面积够格的最高一档
  let areaRank: TerritoryRank = TERRITORY_RANKS[0];
  for (let i = 0; i < TERRITORY_RANKS.length; i += 1) {
    if (area >= TERRITORY_RANKS[i].thresholdKm2) areaRank = TERRITORY_RANKS[i];
  }

  // ② 扣点数门槛：从面积档往下找第一个「点数也够」的档
  let current: TerritoryRank = TERRITORY_RANKS[0];
  if (points === undefined) {
    current = areaRank;
  } else {
    const safePoints: number = points;
    for (let k = areaRank.order; k >= 0; k -= 1) {
      if (safePoints >= TERRITORY_RANKS[k].minPoints) {
        current = TERRITORY_RANKS[k];
        break;
      }
    }
  }

  // ③ 目标档 + 进度
  const blockedBy: TerritoryRank | undefined = areaRank.order > current.order ? areaRank : undefined;
  const capped: boolean = blockedBy !== undefined;
  let next: TerritoryRank | undefined = undefined;
  if (blockedBy !== undefined) {
    next = blockedBy;
  } else if (current.order + 1 < TERRITORY_RANKS.length) {
    next = TERRITORY_RANKS[current.order + 1];
  }

  let progress: number = 1;
  let toNextKm2: number = 0;
  let pointsNeeded: number = 0;
  if (next !== undefined) {
    if (blockedBy !== undefined && points !== undefined) {
      // 被点数卡住：进度按点数算
      const span: number = Math.max(1, next.minPoints - current.minPoints);
      progress = Math.min(1, Math.max(0, (points - current.minPoints) / span));
      pointsNeeded = Math.max(0, next.minPoints - points);
      toNextKm2 = 0;
    } else {
      const spanKm: number = next.thresholdKm2 - current.thresholdKm2;
      progress = spanKm > 0
        ? Math.min(1, Math.max(0, (area - current.thresholdKm2) / spanKm))
        : 1;
      toNextKm2 = Math.max(0, next.thresholdKm2 - area);
      pointsNeeded = points === undefined ? 0 : Math.max(0, next.minPoints - points);
    }
  }

  const result: TerritoryRankResult = {
    rank: current,
    progress: progress,
    toNextKm2: toNextKm2,
    areaKm2: area,
    capped: capped,
    pointsNeeded: pointsNeeded
  };
  if (next !== undefined) result.next = next;
  if (points !== undefined) result.pointCount = points;
  if (blockedBy !== undefined) result.blockedBy = blockedBy;
  return result;
}

// ============================================================
// 5. 格式化
// ============================================================

/**
 * 面积格式化（docs/territory.md §面积格式化）：
 * - `0` → `0 m²`
 * - `< 0.01 km²` → `{round(area*1e6)} m²`
 * - `< 100 km²` → `{area < 1 ? 2 位 : 1 位小数} km²`
 * - 其他 → `{round(area)} km²`
 */
export function formatTerritoryArea(areaKm2: number): string {
  let a: number = 0;
  if (typeof areaKm2 === 'number' && isFinite(areaKm2)) a = areaKm2;
  if (a <= 0) return '0 m²';
  if (a < 0.01) return String(Math.round(a * 1000000)) + ' m²';
  if (a < 100) return a.toFixed(a < 1 ? 2 : 1) + ' km²';
  return String(Math.round(a)) + ' km²';
}

/** 跨度格式化：`< 1000m` 用米，否则一位小数公里 */
export function formatTerritorySpan(spanM: number): string {
  let m: number = 0;
  if (typeof spanM === 'number' && isFinite(spanM)) m = Math.max(0, spanM);
  if (m < 1000) return String(Math.round(m)) + ' m';
  return (m / 1000).toFixed(1) + ' km';
}

/** 封号：给爵位加地名前缀，例如「金陵 · 子爵」；没地名就用爵位名 */
export function fiefTitle(rank: TerritoryRank, placeName?: string): string {
  if (placeName === undefined || placeName.length === 0) return rank.title;
  return placeName + ' · ' + rank.title;
}

/**
 * 进度文案：
 * - 有下一档 → `再扩 {toNext} 晋 {下一档爵位名}`
 * - 已最高 → `已是最高爵位`
 */
export function progressCopy(result: TerritoryRankResult): string {
  if (result.next === undefined) return '已是最高爵位';
  if (result.capped) {
    // 被点数卡住（docs §三「UI 要求」）
    const count: number = result.pointCount === undefined ? 0 : result.pointCount;
    return '边界够了，但只有 ' + String(count) + ' 个探索点 · 再探索 ' +
      String(result.pointsNeeded) + ' 个点才能晋 ' + result.next.title;
  }
  // 没被卡：面积路线 + 顺带提示还差几个点
  let text: string = '再扩 ' + formatTerritoryArea(result.toNextKm2) + ' 晋 ' + result.next.title;
  if (result.pointCount !== undefined && result.pointsNeeded > 0) {
    text += '（还需 ' + String(result.pointsNeeded) + ' 个探索点）';
  }
  return text;
}

/** 点数不足时的引导文案（docs「展示要求 1」） */
export const MIN_POINTS_FOR_TERRITORY: number = 3;

export function needMorePointsCopy(pointCount: number): string {
  const remaining: number = MIN_POINTS_FOR_TERRITORY - pointCount;
  const n: number = remaining < 1 ? 1 : remaining;
  return '再开 ' + String(n) + ' 个盲盒就能围出你的第一块疆域';
}

/** 不足 3 点时的副文案 */
export const NEED_MORE_POINTS_HINT: string = '至少 3 个真实地点才能围成一片地';

/** 数据行标签（三端一致） */
export const TERRITORY_METRIC_LABELS: string[] = ['疆域面积', '占领地点', '最长跨度'];

// ============================================================
// 6. 从「已收录卡片 + 地点库」提取真实坐标点
// ============================================================

/**
 * 真实来源白名单（docs/territory.md §概念）。
 *
 * 比 `core/store.ts` 的 `isRealPlaceSource` **多一个 `wikipedia`**：
 * 老版本语料里维基来源曾写作 `wikipedia`，store 那边的白名单只放行 `wiki`。
 * 疆域统计走这个更宽的白名单 —— 宁可多算一个真实地点，也不能少算用户的地盘。
 */
export function isRealPlaceSource(source: string): boolean {
  return source === 'curated' || source === 'osm' || source === 'wikipedia' ||
    source === 'amap' || source === 'baidu' || source === 'wiki';
}

/**
 * 从卡片 + 地点库提取「已占领的真实坐标」。
 *
 * **只统计真实来源且有坐标的地点**：内置演示地点（source = 'catalog'）没有坐标，
 * 自然被排除 —— 这正是「不造假」原则的体现。
 *
 * @param placeIDs 已收录卡片的 placeID（按收集时间顺序无所谓）
 * @param places 地点库（用于把 placeID 还原成 Place）
 */
export function occupiedPoints(placeIDs: string[], places: Place[]): GeoPoint[] {
  const out: GeoPoint[] = [];
  for (let i = 0; i < placeIDs.length; i += 1) {
    const placeID: string = placeIDs[i];
    for (let j = 0; j < places.length; j += 1) {
      const place: Place = places[j];
      if (place.id !== placeID) continue;
      if (place.coordinate === undefined) break;
      if (!isRealPlaceSource(place.source)) break;
      if (!isValidCoordinate(place.coordinate)) break;
      const point: GeoPoint = {
        latitude: place.coordinate.latitude,
        longitude: place.coordinate.longitude
      };
      out.push(point);
      break;
    }
  }
  return out;
}

/**
 * 凸包顶点（平面米）→ 经纬度：`projectMeters` 的逆运算。
 *
 * 为什么需要：个人地图要在**真实底图**上叠加疆域多边形。
 * 底图是高德（GCJ-02），地图上的地点圆点走的是「WGS → GCJ → 画布像素」。
 * 凸包点只有平面米坐标，必须先还原成 WGS 经纬度，再走同一套投影，
 * 多边形才能和圆点、路网严丝合缝对齐（否则会整体偏移几百米）。
 *
 * @param hull convexHull 的返回值（相对 origin 的米）
 * @param sourcePoints 同一批原始经纬度点（用它们的第一个点 + 平均纬度反算）
 */
export function hullToGeoPoints(hull: PlanePoint[], sourcePoints: GeoPoint[]): GeoPoint[] {
  const out: GeoPoint[] = [];
  if (hull.length === 0 || sourcePoints.length === 0) return out;

  let sumLat: number = 0;
  for (let i = 0; i < sourcePoints.length; i += 1) sumLat += sourcePoints[i].latitude;
  const meanLat: number = sumLat / sourcePoints.length;
  const kx: number = Math.cos(meanLat * Math.PI / 180) * METERS_PER_DEGREE_LON_EQUATOR;
  const ky: number = METERS_PER_DEGREE_LAT;
  const origin: GeoPoint = sourcePoints[0];

  for (let i = 0; i < hull.length; i += 1) {
    const point: GeoPoint = {
      latitude: origin.latitude + hull[i].y / ky,
      longitude: origin.longitude + hull[i].x / kx
    };
    out.push(point);
  }
  return out;
}

/** 卡片级别的紧凑入口：placeIDs + places → 完整疆域统计 */
export function territoryFromCards(placeIDs: string[], places: Place[]): TerritoryStats {
  return territoryStats(occupiedPoints(placeIDs, places));
}