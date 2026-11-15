/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 迷雾路径视图（docs/parity.md §3）
 *
 * 规格全部来自 core/fog.ts（纯 TS、可单测），本组件只负责把计算好的
 * segments / chevrons 画到 Canvas 上 —— 这样「参数对不对」有测试兜底，
 * 「画得对不对」才需要真机/DevEco 看。
 *
 * 关键规则（产品灵魂）：
 * - heading-up：行进方向朝上
 * - 只画「前后一段」，两端渐隐；前方永远短于剩余里程
 * - 剩余 < 60m 整段隐藏，只留「就在附近 · 抬头看看周围」
 * - **绝不画终点、绝不画街道名**
 *
 * ⚠️ 待 DevEco 验证：Canvas 2D 的 rotate / setLineDash / 透明度写法（API 12）。
 */

import { GeoPoint } from '../core/types';
import {
  FogChevron,
  FogGeometry,
  FogLayout,
  FogSegment,
  FogPoint,
  NEARBY_COPY,
  defaultLayout,
  fogGeometry
} from '../core/fog';
import { RoutePolyline } from '../core/contract';
import { WAColor, WAFont, WASize } from '../theme/Theme';

@Component
export struct WaFogPath {
  /** 步行路线（真实模式有值） */
  @Prop @Watch('onDataChanged') routePoints: number[][] = [];
  @Prop @Watch('onDataChanged') routeDistance: number = 0;
  /** 当前位置 */
  @Prop @Watch('onDataChanged') hereLat: number = 0;
  @Prop @Watch('onDataChanged') hereLon: number = 0;
  /** 画布高度 */
  @Prop viewHeight: number = 196;
  /** 设备朝向（0–360）。<0 表示没有罗盘 */
  @Prop @Watch('onDataChanged') heading: number = -1;
  /** true = 固定北朝上（地图不跟随朝向旋转） */
  @Prop @Watch('onDataChanged') northUp: boolean = false;
  /** 说明文案变化时通知外层（UI 展示在画布下方） */
  onCaption: (text: string) => void = () => {
  };

  @State private geometry: FogGeometry = emptyGeometry();
  @State private canvasWidth: number = 320;

  private ready: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private captionValue: string = '';

  onDataChanged(propName: string): void {
    this.recompute();
  }

  aboutToAppear(): void {
    this.recompute();
  }

  /** 用 core/fog.ts 算一遍绘制数据 */
  private recompute(): void {
    const points: number[][] = this.routePoints;
    if (points.length < 2 || this.hereLat === 0 && this.hereLon === 0) {
      this.geometry = emptyGeometry();
      this.emitCaption('正在规划路径…');
      return;
    }
    const route: RoutePolyline = {
      points: points,
      distanceMeters: this.routeDistance,
      fetchedAt: 0
    };
    const layout: FogLayout = defaultLayout(this.canvasWidth, this.viewHeight);
    // 地图朝上方向：北朝上 = 0；否则用设备朝向（没有就退回路线方向）
    const up: number | undefined = this.northUp ? 0 : (this.heading >= 0 ? this.heading : undefined);
    const deviceHeading: number | undefined = this.heading >= 0 ? this.heading : undefined;
    const geometry: FogGeometry = fogGeometry(
      { points: route.points, distanceMeters: route.distanceMeters },
      { latitude: this.hereLat, longitude: this.hereLon },
      layout,
      up,
      deviceHeading
    );
    this.geometry = geometry;
    this.emitCaption(geometry.caption);
    this.draw();
  }

  private emitCaption(text: string): void {
    if (this.captionValue === text) return;
    this.captionValue = text;
    this.onCaption(text);
  }

  // ============================================================
  // 绘制
  // ============================================================

  private draw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.ctx;
    const w: number = this.canvasWidth;
    const h: number = this.viewHeight;
    if (w <= 0 || h <= 0) return;

    ctx.clearRect(0, 0, w, h);

    // 纸底（与卡片同色，不用纯白）
    ctx.fillStyle = WAColor.cream;
    ctx.fillRect(0, 0, w, h);

    const geometry: FogGeometry = this.geometry;

    // ---------- 0. 底图（街区网格 + 河，随地图朝向旋转） ----------
    // 之前画布上只有一条细线，剩下全是空白 —— 像地图没加载出来。
    // 这里补一层淡淡的街区底图，让人一眼看出「这是地图，不是白板」。
    this.drawBackdrop(ctx, w, h, geometry.compassRotation);

    // 剩余 < 60m：整段不画（不露终点）
    if (geometry.hidden || geometry.segments.length === 0) {
      this.drawNearbyMark(ctx, w, h);
      return;
    }

    // ---------- 1. 路径线段（两端渐隐） ----------
    ctx.lineCap = 'round';
    for (let i = 0; i < geometry.segments.length; i += 1) {
      const segment: FogSegment = geometry.segments[i];
      ctx.globalAlpha = segment.opacity;
      ctx.strokeStyle = segment.color;
      ctx.lineWidth = segment.width;
      ctx.beginPath();
      ctx.moveTo(segment.x1, segment.y1);
      ctx.lineTo(segment.x2, segment.y2);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // ---------- 2. 行进箭头（每 55m） ----------
    for (let i = 0; i < geometry.chevrons.length; i += 1) {
      const chevron: FogChevron = geometry.chevrons[i];
      ctx.globalAlpha = chevron.opacity;
      ctx.save();
      ctx.translate(chevron.x, chevron.y);
      ctx.rotate(chevron.angle * Math.PI / 180);
      ctx.strokeStyle = 'rgba(23, 20, 16, 0.50)';
      ctx.lineWidth = 2.2;
      ctx.beginPath();
      ctx.moveTo(-5, 3);
      ctx.lineTo(0, -4);
      ctx.lineTo(5, 3);
      ctx.stroke();
      ctx.restore();
    }
    ctx.globalAlpha = 1;

    // ---------- 3. 偏离路径的红色虚线 ----------
    const deviateTo: FogPoint | undefined = geometry.deviateTo;
    if (deviateTo !== undefined) {
      ctx.strokeStyle = '#FA2A2D';
      ctx.globalAlpha = 0.7;
      ctx.lineWidth = 2;
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      ctx.moveTo(geometry.userX, geometry.userY);
      ctx.lineTo(deviateTo.x, deviateTo.y);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
    }

    // ---------- 4. 「你」：白底琥珀圈 + 深色三角箭头（按 geometry.userRotation 旋转） ----------
    this.drawUserMark(ctx, geometry.userX, geometry.userY, geometry.userRotation);

    // ---------- 5. 右下角指北针（指针按 -bearing 旋转） ----------
    this.drawCompass(ctx, w - 26, h - 26, geometry.compassRotation);
  }

  /**
   * 「你」：琥珀光晕 + 白底圆 + 深色三角。
   *
   * rotation 是**屏幕上的朝向**（0 = 朝上）：
   * - 跟随模式（画布上方 = 设备朝向）恒为 0，箭头朝上；
   * - 北朝上模式按 (设备朝向 - 0) 旋转，箭头指向你实际面朝的方向。
   *
   * 以前这里无视 rotation 恒定朝上 —— 于是在「北朝上」时，
   * 指北针和路线都在说「北在上」，箭头却仍然指着北，和实际朝向自相矛盾。
   */
  private drawUserMark(ctx: CanvasRenderingContext2D, x: number, y: number, rotation: number): void {
    ctx.fillStyle = 'rgba(232, 155, 76, 0.22)';
    ctx.beginPath();
    ctx.arc(x, y, 17, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = WAColor.paper;
    ctx.strokeStyle = WAColor.amber;
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    ctx.arc(x, y, 12, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();

    // 深色三角箭头（按 rotation 旋转）
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(rotation * Math.PI / 180);
    ctx.fillStyle = WAColor.ink;
    ctx.beginPath();
    ctx.moveTo(0, -8);
    ctx.lineTo(6, 5);
    ctx.lineTo(0, 2);
    ctx.lineTo(-6, 5);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  /** 指北针：北向指针按 -bearing 旋转（画布上方是行进方向） */
  private drawCompass(ctx: CanvasRenderingContext2D, x: number, y: number, rotation: number): void {
    ctx.fillStyle = WAColor.paper;
    ctx.strokeStyle = '#E4D9C6';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(x, y, 14, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();

    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(rotation * Math.PI / 180);
    // 北：红
    ctx.fillStyle = '#FA2A2D';
    ctx.beginPath();
    ctx.moveTo(0, -9);
    ctx.lineTo(4, 0);
    ctx.lineTo(0, -2);
    ctx.lineTo(-4, 0);
    ctx.closePath();
    ctx.fill();
    // 南：灰
    ctx.fillStyle = '#C7CEDB';
    ctx.beginPath();
    ctx.moveTo(0, 9);
    ctx.lineTo(4, 0);
    ctx.lineTo(0, 2);
    ctx.lineTo(-4, 0);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  /**
   * 底图：淡街区网格 + 一条河。
   *
   * 只做氛围，不承载任何信息（不画街道名、不画终点），
   * 旋转角度与路径一致，这样「地图随动」看起来才是一整张地图在动。
   */
  private drawBackdrop(ctx: CanvasRenderingContext2D, w: number, h: number, rotation: number): void {
    const cx: number = w / 2;
    const cy: number = h / 2;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(rotation * Math.PI / 180);
    ctx.translate(-cx, -cy);

    const span: number = Math.max(w, h) * 1.8;
    const left: number = cx - span / 2;
    const top: number = cy - span / 2;

    // 街区网格（两组平行线，斜一点，避免死板的正交）
    ctx.strokeStyle = 'rgba(166, 156, 140, 0.16)';
    ctx.lineWidth = 1;
    const step: number = 46;
    ctx.beginPath();
    for (let x = left; x <= left + span; x += step) {
      ctx.moveTo(x, top);
      ctx.lineTo(x + span * 0.06, top + span);
    }
    for (let y = top; y <= top + span; y += step) {
      ctx.moveTo(left, y);
      ctx.lineTo(left + span, y + span * 0.05);
    }
    ctx.stroke();

    // 主干道（比网格粗、比路径淡）
    ctx.strokeStyle = 'rgba(232, 222, 204, 0.85)';
    ctx.lineWidth = 9;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(left, cy + 40);
    ctx.quadraticCurveTo(cx, cy - 30, left + span, cy - 10);
    ctx.stroke();

    // 河
    ctx.strokeStyle = 'rgba(46, 125, 120, 0.10)';
    ctx.lineWidth = 22;
    ctx.beginPath();
    ctx.moveTo(left, cy - span * 0.18);
    ctx.quadraticCurveTo(cx + span * 0.1, cy + span * 0.10, left + span, cy - span * 0.06);
    ctx.stroke();

    ctx.restore();
  }

  /** 剩余 < 60m：只画一个柔和的光点（不画路径、不画终点） */
  private drawNearbyMark(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    const x: number = w / 2;
    const y: number = h * 0.52;
    ctx.fillStyle = 'rgba(232, 155, 76, 0.14)';
    ctx.beginPath();
    ctx.arc(x, y, 46, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = 'rgba(232, 155, 76, 0.20)';
    ctx.beginPath();
    ctx.arc(x, y, 26, 0, Math.PI * 2);
    ctx.fill();
    this.drawUserMark(ctx, x, y, 0);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.ready = true;
          this.draw();
        })

      // 剩余 < 60m 的居中提示（Canvas 里画中文字体不可靠，用组件叠）
      if (this.geometry.hidden) {
        Column({ space: 4 }) {
          Text('就在附近')
            .fontSize(WAFont.titleSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
          Text('抬头看看周围')
            .fontSize(WAFont.caption)
            .fontColor(WAColor.ink3)
        }
        .position({ x: 0, y: this.viewHeight * 0.62 })
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height(this.viewHeight)
    .backgroundColor(WAColor.cream)
    .borderRadius(WASize.cardRadius)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadius })
    .clip(true)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const next: number = parseFloat(newValue.width.toString());
      if (Math.abs(next - this.canvasWidth) > 1) {
        this.canvasWidth = next;
        this.recompute();
      }
    })
  }
}

/** 空几何（还没规划出路线时的初始值） */
function emptyGeometry(): FogGeometry {
  const geometry: FogGeometry = {
    segments: [],
    chevrons: [],
    userX: 0,
    userY: 0,
    compassRotation: 0,
    userRotation: 0,
    caption: '正在规划路径…',
    hidden: false,
    remaining: 0,
    offRoute: 0
  };
  return geometry;
}

/** 供外部判断「是否处于保密隐藏态」 */
export function fogIsNearby(geometry: FogGeometry): boolean {
  return geometry.hidden;
}

/** 供外部取文案（与 core/fog.ts 的 NEARBY_COPY 同源） */
export function fogNearbyCopy(): string {
  return NEARBY_COPY;
}