/**
 * 步迷 Walkaholic · HarmonyOS 逻辑层 — 疆域身份卡（分享卡）布局
 *
 * 分享卡是一张 720×960 的图片（docs/territory.md §展示要求 3）：
 * 爵位色带 / 印章 / 爵位名 / 释义 / 疆域形状 / 三项数据 / 页脚。
 *
 * 为什么把布局抽到 core：
 *   Canvas 画出来的东西只能在真机上看，但「每块该放在哪、字是什么」全是纯计算。
 *   放 core 里就能用 Node 断言：不出界、不重叠、文案与 Web 逐字一致、无疆域时不画假多边形。
 *   UI（components/TerritoryShareCard.ets）只负责把这份 layout 画到 Canvas 上。
 *
 * 纯函数、零 `@ohos.*` 依赖。
 */

import { TerritoryRank, TerritoryRankResult, TerritoryStats, formatTerritoryArea, formatTerritorySpan } from './territory';

// ============================================================
// 画布尺寸（Web renderTerritoryCard 同款 720×960）
// ============================================================

/** 逻辑尺寸（vp）；实际导出时 ×scale 渲染 */
export const CARD_WIDTH: number = 720;
export const CARD_HEIGHT: number = 960;

/** 顶部爵位色带高度 */
export const BAND_HEIGHT: number = 10;

/** 印章圆心与半径 */
export const SEAL_CENTER_X: number = CARD_WIDTH / 2;
export const SEAL_CENTER_Y: number = 150;
export const SEAL_RADIUS: number = 62;

/** 标题 / 释义基线 */
export const TITLE_Y: number = 268;
export const DESC_Y: number = 305;

/** 疆域图形区域（正方形） */
export const MAP_TOP: number = 350;
export const MAP_SIZE: number = 340;
/** 图形区域内留白（顶点小圆不被裁掉） */
export const MAP_PADDING: number = 24;

/** 数据行基线 */
export const STAT_ROW_Y: number = MAP_TOP + MAP_SIZE + 40;

/** 页脚基线 */
export const FOOTER_Y: number = CARD_HEIGHT - 56;

/** 卡片背景（淡蓝渐变，Web 同款两色） */
export const CARD_BG_TOP: string = '#F3F5FB';
export const CARD_BG_BOTTOM: string = '#E8ECFB';

/** 文字色（卡内固定浅色背景，所以用自己的深灰而不是页面 ink） */
export const CARD_TEXT_PRIMARY: string = '#111827';
export const CARD_TEXT_SECONDARY: string = '#6B7280';
export const CARD_TEXT_TERTIARY: string = '#9CA3AF';

// ============================================================
// 布局
// ============================================================

export interface CardPoint {
  x: number;
  y: number;
}

export interface CardStatCell {
  value: string;
  label: string;
  /** 基线中心 x（三等分） */
  x: number;
  /** 数值基线 y */
  y: number;
  /** 标签基线 y */
  labelY: number;
}

export interface ShareCardLayout {
  width: number;
  height: number;
  /** 爵位主色（色带 / 印章底 / 多边形描边） */
  color: string;
  /** 印章里的汉字 */
  seal: string;
  sealX: number;
  sealY: number;
  sealRadius: number;
  /** 爵位名 */
  title: string;
  titleY: number;
  /** 释义 */
  desc: string;
  descY: number;
  /**
   * 疆域多边形（画布坐标，已做 Y 轴翻转：数学上 y 向上，画布 y 向下）。
   * **空数组 = 没有疆域，UI 不许画任何多边形**（docs：不画假多边形）。
   */
  polygon: CardPoint[];
  /** 无疆域时的替代文案（polygon 为空才用） */
  emptyTerritoryText: string;
  emptyTerritoryY: number;
  /** 三项数据 */
  stats: CardStatCell[];
  footer: string;
  footerY: number;
}

/**
 * 把平面米坐标的凸包「装进」一个方框，并翻转 Y 轴。
 *
 * 做法与 Web `renderTerritoryCard` 一致：取包围盒 → 等比缩放 → 居中 → `y` 取反。
 * 返回值都是画布坐标（可以直接 `moveTo/lineTo`）。
 */
export function fitHullToBox(
  hull: CardPoint[],
  boxX: number,
  boxY: number,
  boxW: number,
  boxH: number
): CardPoint[] {
  const out: CardPoint[] = [];
  if (hull.length < 3 || boxW <= 0 || boxH <= 0) return out;

  let minX: number = Infinity;
  let maxX: number = -Infinity;
  let minY: number = Infinity;
  let maxY: number = -Infinity;
  for (let i = 0; i < hull.length; i += 1) {
    if (hull[i].x < minX) minX = hull[i].x;
    if (hull[i].x > maxX) maxX = hull[i].x;
    if (hull[i].y < minY) minY = hull[i].y;
    if (hull[i].y > maxY) maxY = hull[i].y;
  }
  // 退化（共线）时给 1 米兜底，避免除零
  const spanX: number = Math.max(1, maxX - minX);
  const spanY: number = Math.max(1, maxY - minY);
  const scale: number = Math.min(boxW / spanX, boxH / spanY);

  const centerX: number = boxX + boxW / 2;
  const centerY: number = boxY + boxH / 2;
  const hullCenterX: number = (minX + maxX) / 2;
  const hullCenterY: number = (minY + maxY) / 2;

  for (let i = 0; i < hull.length; i += 1) {
    const point: CardPoint = {
      x: centerX + (hull[i].x - hullCenterX) * scale,
      // 翻转：数学 y 向上，画布 y 向下
      y: centerY - (hull[i].y - hullCenterY) * scale
    };
    out.push(point);
  }
  return out;
}

/** 无疆域时卡片上写什么（与 Web `再开 3 个盲盒即可围出疆域` 同义） */
export const CARD_EMPTY_TERRITORY_TEXT: string = '再开 3 个盲盒即可围出疆域';

/** 页脚品牌名（与 docs「步谜 StepRiddle」一致；本工程品牌已改为 步迷 Walkaholic） */
export const CARD_FOOTER_BRAND: string = '步迷 Walkaholic';

/** 页脚日期格式：2026-11-20 */
export function formatCardDate(timestampMs: number): string {
  const date: Date = new Date(timestampMs);
  const month: string = date.getMonth() + 1 < 10
    ? '0' + String(date.getMonth() + 1)
    : String(date.getMonth() + 1);
  const day: string = date.getDate() < 10 ? '0' + String(date.getDate()) : String(date.getDate());
  return String(date.getFullYear()) + '-' + month + '-' + day;
}

/**
 * 生成整张分享卡的布局。
 *
 * @param stats 疆域统计（hull 为空 → 不画多边形）
 * @param rankResult 爵位 + 进度
 * @param nowMs 当前时间（页脚日期）
 */
export function shareCardLayout(
  stats: TerritoryStats,
  rankResult: TerritoryRankResult,
  nowMs: number
): ShareCardLayout {
  const rank: TerritoryRank = rankResult.rank;
  const polygon: CardPoint[] = fitHullToBox(
    stats.hull,
    CARD_WIDTH / 2 - MAP_SIZE / 2 + MAP_PADDING,
    MAP_TOP + MAP_PADDING,
    MAP_SIZE - MAP_PADDING * 2,
    MAP_SIZE - MAP_PADDING * 2
  );

  const stats3: CardStatCell[] = [
    {
      value: formatTerritoryArea(stats.areaKm2),
      label: '疆域面积',
      x: CARD_WIDTH * 0.5 / 3,
      y: STAT_ROW_Y,
      labelY: STAT_ROW_Y + 34
    },
    {
      value: String(stats.pointCount),
      label: '占领地点',
      x: CARD_WIDTH * 1.5 / 3,
      y: STAT_ROW_Y,
      labelY: STAT_ROW_Y + 34
    },
    {
      value: formatTerritorySpan(stats.spanM),
      label: '最长跨度',
      x: CARD_WIDTH * 2.5 / 3,
      y: STAT_ROW_Y,
      labelY: STAT_ROW_Y + 34
    }
  ];

  const layout: ShareCardLayout = {
    width: CARD_WIDTH,
    height: CARD_HEIGHT,
    color: rank.color,
    seal: rank.seal,
    sealX: SEAL_CENTER_X,
    sealY: SEAL_CENTER_Y,
    sealRadius: SEAL_RADIUS,
    title: rank.title,
    titleY: TITLE_Y,
    desc: rank.desc,
    descY: DESC_Y,
    polygon: polygon,
    emptyTerritoryText: CARD_EMPTY_TERRITORY_TEXT,
    emptyTerritoryY: MAP_TOP + MAP_SIZE / 2,
    stats: stats3,
    footer: CARD_FOOTER_BRAND + ' · ' + formatCardDate(nowMs),
    footerY: FOOTER_Y
  };
  return layout;
}