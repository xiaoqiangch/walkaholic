/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 步行导航地图（docs/parity.md §3）
 *
 * 几何全部来自 core/fog.ts（纯 TS、可单测），本组件只负责把计算好的
 * segments / chevrons 画到 Canvas 上 —— 「参数对不对」有测试兜底，
 * 「画得对不对」才需要真机/DevEco 看。
 *
 * 视觉对齐 iOS / Apple Maps 步行导航：
 * - 一条带白色描边的蓝色路线，越远越淡，在画布上缘化开（没有「线的尽头」）
 * - 「你」= 蓝点 + 朝向扇形，钉在画面偏下 72% 处（地图跟着人走）
 * - 左上保密标签、右上指北针、右下「正北 / 随动」两档切换、左下比例尺
 * - 剩余 < 60m 整段隐藏，只留「路线到这里为止」
 * - **绝不画终点、绝不画街道名**
 */

import {
  FogChevron,
  FogGeometry,
  FogLayout,
  FogPoint,
  FogSegment,
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
  @Prop @Watch('onDataChanged') locationAccuracyMeters: number = 0;
  /** 画布高度 */
  @Prop viewHeight: number = 240;
  /** 设备朝向（0–360）。<0 表示没有罗盘 */
  @Prop @Watch('onDataChanged') heading: number = -1;
  /** true = 固定北朝上（地图不跟随朝向旋转） */
  @Prop @Watch('onDataChanged') northUp: boolean = false;
  /** 切换朝向（点地图上的「正北 / 随动」） */
  onToggleOrientation: () => void = () => {
  };
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
      deviceHeading,
      this.locationAccuracyMeters
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

  /** 每米对应的画布像素（比例尺要跟它一致） */
  private pixelsPerMeter(): number {
    const ahead: number = this.geometry.aheadMeters;
    if (ahead <= 0) return 1;
    return this.viewHeight * 0.68 / ahead;
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
    ctx.fillStyle = WAColor.paper2;
    ctx.fillRect(0, 0, w, h);

    const geometry: FogGeometry = this.geometry;

    // ---------- 0. 底图（街区网格 + 距离圆环，随地图朝向旋转） ----------
    this.drawBackdrop(ctx, w, h, geometry.compassRotation);

    // 剩余 < 60m：整段不画（不露终点）
    if (geometry.hidden || geometry.segments.length === 0) {
      this.drawNearbyMark(ctx, w, h);
      return;
    }

    // ---------- 1. 路线：一条连续路径 + 竖向渐变（不是逐段描边） ----------
    this.drawPath(ctx, w, h, geometry);

    // ---------- 2. 行进箭头（白色，压在蓝线上） ----------
    for (let i = 0; i < geometry.chevrons.length; i += 1) {
      const chevron: FogChevron = geometry.chevrons[i];
      if (chevron.opacity <= 0.25) continue;
      ctx.globalAlpha = Math.min(1, chevron.opacity);
      ctx.save();
      ctx.translate(chevron.x, chevron.y);
      ctx.rotate(chevron.angle * Math.PI / 180);
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 2.2;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(-4.5, 3);
      ctx.lineTo(0, -3.5);
      ctx.lineTo(4.5, 3);
      ctx.stroke();
      ctx.restore();
    }
    ctx.globalAlpha = 1;

    // ---------- 3. 偏离路径的红色虚线 ----------
    const deviateTo: FogPoint | undefined = geometry.deviateTo;
    if (deviateTo !== undefined) {
      ctx.strokeStyle = WAColor.ember;
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

    // ---------- 4. 「你」：朝向扇形 + 白边蓝点 ----------
    this.drawUserMark(ctx, geometry.userX, geometry.userY, geometry.userRotation);

    // ---------- 5. 指北针（右上，纯指示） ----------
    this.drawCompass(ctx, w - 28, 28, geometry.compassRotation);

    // ---------- 6. 比例尺（左下） ----------
    this.drawScaleBar(ctx, w, h);
  }

  /**
   * 路线：已走部分灰、前方靛蓝，各自一条连续路径。
   *
   * 关键点：**先起一条 path 再一次 stroke**。逐段描边时每段的白描边会盖掉
   * 前一段的线芯，看起来像一串珠子 —— 这是旧版「一塌糊涂」的主因。
   */
  private drawPath(ctx: CanvasRenderingContext2D, w: number, h: number, geometry: FogGeometry): void {
    const segments: FogSegment[] = geometry.segments;
    const userY: number = geometry.userY;

    const aheadStops = this.buildPath(segments, false);
    const behindStops = this.buildPath(segments, true);

    // ⚠️ 这里判的是「有几条折线」而不是「有几个点」：一条连续的路线只会产生 1 条折线。
    // 早期写成 `length > 1` 时，正常路线永远画不出来，只剩箭头和圆环浮在空白底图上。
    if (behindStops.length > 0) {
      const gray: CanvasGradient = ctx.createLinearGradient(0, userY, 0, h);
      gray.addColorStop(0, 'rgba(169, 175, 187, 0.40)');
      gray.addColorStop(1, 'rgba(169, 175, 187, 0.05)');
      ctx.strokeStyle = gray;
      ctx.lineWidth = 6;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      this.strokeStops(ctx, behindStops);
    }

    if (aheadStops.length > 0) {
      const fadeEnd: number = -h * 0.12;
      // 白色描边（从用户位置往上越来越淡，上缘化开）
      const casing: CanvasGradient = ctx.createLinearGradient(0, userY, 0, fadeEnd);
      casing.addColorStop(0, 'rgba(255, 255, 255, 0.98)');
      casing.addColorStop(0.55, 'rgba(255, 255, 255, 0.55)');
      casing.addColorStop(1, 'rgba(255, 255, 255, 0)');
      ctx.strokeStyle = casing;
      ctx.lineWidth = 12;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      this.strokeStops(ctx, aheadStops);

      const core: CanvasGradient = ctx.createLinearGradient(0, userY, 0, fadeEnd);
      core.addColorStop(0, WAColor.amber);
      core.addColorStop(0.5, 'rgba(10, 89, 247, 0.92)');
      core.addColorStop(1, 'rgba(10, 89, 247, 0)');
      ctx.strokeStyle = core;
      ctx.lineWidth = 7.5;
      this.strokeStops(ctx, aheadStops);
    }
  }

  /** 把相邻线段拼成若干段折线（跳太远的断开，不要连成假直线） */
  private buildPath(segments: FogSegment[], behind: boolean): FogPoint[][] {
    const lines: FogPoint[][] = [];
    let current: FogPoint[] = [];
    for (let i = 0; i < segments.length; i += 1) {
      const segment: FogSegment = segments[i];
      if (segment.behind !== behind) continue;
      const start: FogPoint = { x: segment.x1, y: segment.y1 };
      const end: FogPoint = { x: segment.x2, y: segment.y2 };
      if (current.length === 0) {
        current.push(start);
        current.push(end);
        continue;
      }
      const last: FogPoint = current[current.length - 1];
      const dx: number = start.x - last.x;
      const dy: number = start.y - last.y;
      if (Math.sqrt(dx * dx + dy * dy) < 80) {
        current.push(end);
      } else {
        lines.push(current);
        current = [start, end];
      }
    }
    if (current.length > 1) lines.push(current);
    return lines;
  }

  private strokeStops(ctx: CanvasRenderingContext2D, lines: FogPoint[][]): void {
    for (let i = 0; i < lines.length; i += 1) {
      const line: FogPoint[] = lines[i];
      ctx.beginPath();
      ctx.moveTo(line[0].x, line[0].y);
      for (let j = 1; j < line.length; j += 1) {
        ctx.lineTo(line[j].x, line[j].y);
      }
      ctx.stroke();
    }
  }

  /**
   * 「你」：朝向扇形 + 白边蓝点（Apple Maps 同款）。
   *
   * rotation 是**屏幕上的朝向**（0 = 朝上）：
   * - 随动模式（画布上方 = 设备朝向）恒为 0，扇形朝上；
   * - 北朝上模式按 (设备朝向 - 0) 旋转，扇形指向你实际面朝的方向。
   */
  private drawUserMark(ctx: CanvasRenderingContext2D, x: number, y: number, rotation: number): void {
    // 朝向扇形
    if (this.heading >= 0) {
      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(rotation * Math.PI / 180);
      ctx.fillStyle = 'rgba(10, 89, 247, 0.20)';
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.arc(0, 0, 34, -Math.PI / 2 - 0.38, -Math.PI / 2 + 0.38);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    }

    // 光晕
    ctx.fillStyle = 'rgba(10, 89, 247, 0.14)';
    ctx.beginPath();
    ctx.arc(x, y, 16, 0, Math.PI * 2);
    ctx.fill();

    // 白底圆
    ctx.fillStyle = '#FFFFFF';
    ctx.strokeStyle = 'rgba(24, 36, 49, 0.10)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(x, y, 9.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();

    // 蓝芯
    ctx.fillStyle = WAColor.amber;
    ctx.beginPath();
    ctx.arc(x, y, 6, 0, Math.PI * 2);
    ctx.fill();
  }

  /** 指北针：红头朝北、灰尾朝南，整体按 -bearing 旋转 */
  private drawCompass(ctx: CanvasRenderingContext2D, x: number, y: number, rotation: number): void {
    ctx.fillStyle = 'rgba(255, 255, 255, 0.95)';
    ctx.strokeStyle = WAColor.line;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(x, y, 17, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();

    // 上缘的「N」：告诉用户红针指的是北（拉丁字母，Canvas 里能可靠显示）
    ctx.fillStyle = 'rgba(24, 36, 49, 0.55)';
    ctx.font = '9px sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('N', x, y - 8);

    ctx.save();
    ctx.translate(x, y + 3);
    ctx.rotate(rotation * Math.PI / 180);
    // 北：红
    ctx.fillStyle = WAColor.ember;
    ctx.beginPath();
    ctx.moveTo(0, -9);
    ctx.lineTo(4, 0);
    ctx.lineTo(-4, 0);
    ctx.closePath();
    ctx.fill();
    // 南：灰
    ctx.fillStyle = 'rgba(24, 36, 49, 0.30)';
    ctx.beginPath();
    ctx.moveTo(0, 9);
    ctx.lineTo(4, 0);
    ctx.lineTo(-4, 0);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  /** 比例尺：给人「这段路大概多长」的参照 */
  private drawScaleBar(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    const scale: number = this.pixelsPerMeter();
    if (scale <= 0) return;
    const candidates: number[] = [20, 25, 50, 75, 100, 150, 200];
    let meters: number = candidates[candidates.length - 1];
    for (let i = 0; i < candidates.length; i += 1) {
      if (candidates[i] * scale >= 40) {
        meters = candidates[i];
        break;
      }
    }
    const length: number = meters * scale;
    const x0: number = 14;
    const y0: number = h - 20;
    ctx.strokeStyle = 'rgba(24, 36, 49, 0.35)';
    ctx.lineWidth = 1.5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    ctx.lineTo(x0 + length, y0);
    ctx.moveTo(x0, y0 - 4);
    ctx.lineTo(x0, y0 + 4);
    ctx.moveTo(x0 + length, y0 - 4);
    ctx.lineTo(x0 + length, y0 + 4);
    ctx.stroke();

    // 标签压在白底 + 网格线上：先描一圈纸色描边再填字，否则细字会被网格线切碎。
    // 填充色不能用 ink2（40% 透明）：10px 的字再打折就看不清了。
    const label: string = String(Math.round(meters)) + ' 米';
    const labelX: number = x0 + length / 2;
    const labelY: number = y0 - 8;
    ctx.font = '10px sans-serif';
    ctx.textAlign = 'center';
    ctx.lineWidth = 3;
    ctx.strokeStyle = WAColor.paper2;
    ctx.strokeText(label, labelX, labelY);
    ctx.fillStyle = 'rgba(24, 36, 49, 0.62)';
    ctx.fillText(label, labelX, labelY);
  }

  /**
   * 底图：淡街区网格 + 距离圆环。
   * 只做氛围，不承载任何信息（不画街道名、不画终点）。
   */
  private drawBackdrop(ctx: CanvasRenderingContext2D, w: number, h: number, rotation: number): void {
    const cx: number = this.geometry.userX > 0 ? this.geometry.userX : w / 2;
    const cy: number = this.geometry.userY > 0 ? this.geometry.userY : h * 0.72;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(rotation * Math.PI / 180);
    ctx.translate(-cx, -cy);

    const span: number = Math.max(w, h) * 1.8;
    const left: number = cx - span / 2;
    const top: number = cy - span / 2;

    ctx.strokeStyle = 'rgba(24, 36, 49, 0.05)';
    ctx.lineWidth = 1;
    const step: number = 54;
    ctx.beginPath();
    // 正交网格：不做斜切。斜切的网格会让「正北朝上」看起来也是歪的，
    // 用户会以为地图坏了。旋转交给上面的 rotate 统一处理。
    for (let x = left; x <= left + span; x += step) {
      ctx.moveTo(x, top);
      ctx.lineTo(x, top + span);
    }
    for (let y = top; y <= top + span; y += step) {
      ctx.moveTo(left, y);
      ctx.lineTo(left + span, y);
    }
    ctx.stroke();
    ctx.restore();

    // 距离圆环（不随朝向转）
    const scale: number = this.pixelsPerMeter();
    const steps: number[] = [50, 100, 150, 200];
    ctx.strokeStyle = 'rgba(24, 36, 49, 0.055)';
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 6]);
    for (let i = 0; i < steps.length; i += 1) {
      const radius: number = steps[i] * scale;
      if (radius < 24 || radius > Math.max(w, h) * 1.1) continue;
      ctx.beginPath();
      ctx.arc(cx, cy, radius, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.setLineDash([]);
  }

  /** 剩余 < 60m：只画一个柔和的光点（不画路径、不画终点） */
  private drawNearbyMark(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    const x: number = w / 2;
    const y: number = h * 0.55;
    ctx.fillStyle = 'rgba(10, 89, 247, 0.10)';
    ctx.beginPath();
    ctx.arc(x, y, 46, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = 'rgba(10, 89, 247, 0.16)';
    ctx.beginPath();
    ctx.arc(x, y, 26, 0, Math.PI * 2);
    ctx.fill();
    this.drawUserMark(ctx, x, y, 0);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.ready = true;
          this.draw();
        })

      // 左上：保密标签
      Row({ space: 4 }) {
        Text('迷雾路径')
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink2)
      }
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor('rgba(255, 255, 255, 0.92)')
      .borderRadius(WASize.chipRadius)
      .margin({ left: 10, top: 10 })

      // 右下：正北 / 随动 两档切换
      //
      // ⚠️ 这里必须内联写死两个 Text，不能抽成 `orientationChip(label, active)`：
      // ArkUI 的 @Builder 参数是**按值传递**的，状态变化不会让 Builder 内部 UI 刷新，
      // 表现为「点了没反应」——状态其实变了，只是高亮不跟着走。
      Stack({ alignContent: Alignment.BottomEnd }) {
        Row({ space: 0 }) {
          Text('正北')
            .fontSize(11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.northUp ? WAColor.paper : WAColor.ink2)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.northUp ? WAColor.ink : '#00000000')
            .borderRadius(WASize.chipRadius)
            .onClick(() => {
              if (this.northUp) return;
              this.onToggleOrientation();
            })

          Text('随动')
            .fontSize(11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.northUp ? WAColor.ink2 : WAColor.paper)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.northUp ? '#00000000' : WAColor.ink)
            .borderRadius(WASize.chipRadius)
            .onClick(() => {
              if (!this.northUp) return;
              this.onToggleOrientation();
            })
        }
        .padding(2)
        .backgroundColor('rgba(255, 255, 255, 0.96)')
        .borderRadius(WASize.chipRadius)
        .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
        .margin({ right: 10, bottom: 10 })
      }
      .width('100%')
      .height('100%')

      // 剩余 < 60m 的居中提示（Canvas 里画中文字体不可靠，用组件叠）
      if (this.geometry.hidden) {
        Column({ space: 4 }) {
          Text('路线到这里为止')
            .fontSize(WAFont.titleSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
          Text('剩下的路，用眼睛找')
            .fontSize(WAFont.caption)
            .fontColor(WAColor.ink3)
        }
        // 光点在 55%，文案压到 74%：再高就会盖住光晕（实测 66% 正好压上圆环边缘）
        .position({ x: 0, y: this.viewHeight * 0.74 })
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height(this.viewHeight)
    .backgroundColor(WAColor.paper2)
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
    offRoute: 0,
    aheadMeters: 0
  };
  return geometry;
}
