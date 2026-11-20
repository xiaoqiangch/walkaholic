/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 疆域身份卡（分享卡）
 *
 * 720×960 的图片卡（docs/territory.md §展示要求 3）：爵位色带 / 印章 / 爵位名 /
 * 释义 / 疆域形状 / 三项数据 / 页脚。
 *
 * 布局全部由 `core/sharecard.ts` 算好（纯 TS，有单测），本组件只负责画 + 存。
 *
 * ⚠️ 需 DevEco 验证的 API（「保存到相册」这一整条链路）：
 *   1. `componentSnapshot.get(nodeId)` → PixelMap（若签名要求 options，改成 getWithOptions）
 *   2. `image.createImagePacker().packing(pixelMap, { format:'image/png', quality:100 })`
 *   3. 先把 PNG 写进**应用沙箱**，再用
 *      `photoAccessHelper.showAssetsCreationDialog([沙箱uri], [{ title, fileNameExtension }])`
 *      拿到相册目标 uri，最后把字节复制过去（这是官方推荐的白盒流程：
 *      showAssetsCreationDialog 收的是 **源文件 uri 数组**，不是 buffer）。
 *   任一环节失败 → 提示「直接截屏保存」，绝不崩、不假装保存成功。
 */

import { componentSnapshot, promptAction } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TerritoryRankResult, TerritoryStats } from '../core/territory';
import {
  BAND_HEIGHT,
  CARD_BG_BOTTOM,
  CARD_BG_TOP,
  CARD_HEIGHT,
  CARD_TEXT_PRIMARY,
  CARD_TEXT_SECONDARY,
  CARD_TEXT_TERTIARY,
  CARD_WIDTH,
  CardPoint,
  CardStatCell,
  MAP_SIZE,
  MAP_TOP,
  ShareCardLayout,
  shareCardLayout
} from '../core/sharecard';
import { WAColor, WAFont, WASize } from '../theme/Theme';

/** 组件节点 id（componentSnapshot 用） */
const CARD_NODE_ID: string = 'territoryShareCard';

@Component
export struct TerritoryShareCard {
  /** 疆域统计（由 ProfileView 传入） */
  @Prop statsJson: string = '';
  /** 爵位结果（同上一并传：用 JSON 传是为了 @Prop 能感知变化） */
  @Prop rankJson: string = '';
  /** 当前时间戳（页脚日期；同样用数字 @Prop 保证可响应） */
  @Prop nowMs: number = 0;

  onClose: () => void = () => {
  };

  @State private busying: boolean = false;
  /** 画布逻辑尺寸（vp）；实际按 720×960 布局，外层缩放适配屏宽 */
  @State private canvasWidth: number = CARD_WIDTH;

  private ready: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.draw();
  }

  /** 解析外部传入的 JSON（坏数据 → 空统计，卡面显示「再开 3 个盲盒」而不是崩） */
  private layout(): ShareCardLayout {
    let stats: TerritoryStats = emptyStats();
    let rank: TerritoryRankResult = emptyRank();
    try {
      if (this.statsJson.length > 0) {
        const parsed = JSON.parse(this.statsJson) as TerritoryStats;
        if (parsed !== null && parsed !== undefined) stats = parsed;
      }
    } catch (err) {
      stats = emptyStats();
    }
    try {
      if (this.rankJson.length > 0) {
        const parsedRank = JSON.parse(this.rankJson) as TerritoryRankResult;
        if (parsedRank !== null && parsedRank !== undefined) rank = parsedRank;
      }
    } catch (err) {
      rank = emptyRank();
    }
    return shareCardLayout(stats, rank, this.nowMs > 0 ? this.nowMs : Date.now());
  }

  // ============================================================
  // 绘制（全部坐标来自 core/sharecard.ts）
  // ============================================================

  private draw(): void {
    if (!this.ready) return;
    const layout: ShareCardLayout = this.layout();
    const ctx: CanvasRenderingContext2D = this.ctx;
    const scale: number = this.canvasWidth / CARD_WIDTH;

    ctx.clearRect(0, 0, this.canvasWidth, CARD_HEIGHT * scale);
    ctx.save();
    ctx.scale(scale, scale);

    // ① 背景：淡蓝渐变
    const bg = ctx.createLinearGradient(0, 0, CARD_WIDTH, CARD_HEIGHT);
    bg.addColorStop(0, CARD_BG_TOP);
    bg.addColorStop(1, CARD_BG_BOTTOM);
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, CARD_WIDTH, CARD_HEIGHT);

    // ② 顶部爵位色带
    ctx.fillStyle = layout.color;
    ctx.fillRect(0, 0, CARD_WIDTH, BAND_HEIGHT);

    // ③ 印章圆 + 汉字
    ctx.beginPath();
    ctx.arc(layout.sealX, layout.sealY, layout.sealRadius, 0, Math.PI * 2);
    ctx.fillStyle = layout.color;
    ctx.fill();
    ctx.fillStyle = WAColor.iconOnBrand;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 64px sans-serif';
    ctx.fillText(layout.seal, layout.sealX, layout.sealY + 3);

    // ④ 爵位名 / 释义
    ctx.fillStyle = CARD_TEXT_PRIMARY;
    ctx.font = 'bold 46px sans-serif';
    ctx.fillText(layout.title, CARD_WIDTH / 2, layout.titleY);

    ctx.fillStyle = CARD_TEXT_SECONDARY;
    ctx.font = '22px sans-serif';
    ctx.fillText(layout.desc, CARD_WIDTH / 2, layout.descY);

    // ⑤ 疆域形状（polygon 为空就只写文字，绝不画假多边形）
    if (layout.polygon.length >= 3) {
      ctx.beginPath();
      for (let i = 0; i < layout.polygon.length; i += 1) {
        const point: CardPoint = layout.polygon[i];
        if (i === 0) {
          ctx.moveTo(point.x, point.y);
        } else {
          ctx.lineTo(point.x, point.y);
        }
      }
      ctx.closePath();
      ctx.fillStyle = layout.color + '33';
      ctx.fill();
      ctx.strokeStyle = layout.color;
      ctx.lineWidth = 3;
      ctx.lineJoin = 'round';
      ctx.stroke();

      // 顶点小圆
      for (let i = 0; i < layout.polygon.length; i += 1) {
        ctx.beginPath();
        ctx.arc(layout.polygon[i].x, layout.polygon[i].y, 5, 0, Math.PI * 2);
        ctx.fillStyle = layout.color;
        ctx.fill();
      }
    } else {
      ctx.fillStyle = CARD_TEXT_TERTIARY;
      ctx.font = '22px sans-serif';
      ctx.fillText(layout.emptyTerritoryText, CARD_WIDTH / 2, layout.emptyTerritoryY);
    }

    // ⑥ 三项数据
    const stats: CardStatCell[] = layout.stats;
    for (let i = 0; i < stats.length; i += 1) {
      const cell: CardStatCell = stats[i];
      ctx.fillStyle = CARD_TEXT_PRIMARY;
      ctx.font = 'bold 40px sans-serif';
      ctx.fillText(cell.value, cell.x, cell.y);
      ctx.fillStyle = CARD_TEXT_TERTIARY;
      ctx.font = '20px sans-serif';
      ctx.fillText(cell.label, cell.x, cell.labelY);
    }

    // ⑦ 页脚
    ctx.fillStyle = CARD_TEXT_TERTIARY;
    ctx.font = '20px sans-serif';
    ctx.fillText(layout.footer, CARD_WIDTH / 2, layout.footerY);

    ctx.restore();
  }

  // ============================================================
  // 保存到相册
  // ============================================================

  private toast(text: string): void {
    promptAction.showToast({ message: text, duration: 2200 });
  }

  /** 沙箱里临时落的 PNG 路径（保存成功/失败都清掉） */
  private tempCardPath(): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.filesDir + '/territory-card-' + String(Date.now()) + '.png';
  }

  private writeBuffer(path: string, buffer: ArrayBuffer): boolean {
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  private deleteQuietly(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (err) {
      // 忽略
    }
  }

  private async saveToAlbum(): Promise<void> {
    if (this.busying) return;
    this.busying = true;

    // ---------- ① 组件截图 → PixelMap ----------
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      pixelMap = await componentSnapshot.get(CARD_NODE_ID);
    } catch (err) {
      const error = err as BusinessError;
      pixelMap = undefined;
    }
    if (pixelMap === undefined) {
      this.busying = false;
      this.toast('截图失败，可以直接截屏保存');
      return;
    }

    // ---------- ② PixelMap → PNG bytes ----------
    let pngBuffer: ArrayBuffer | undefined = undefined;
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      try {
        pngBuffer = await packer.packing(pixelMap, { format: 'image/png', quality: 100 });
      } finally {
        packer.release();
        pixelMap.release();
      }
    } catch (err) {
      const error = err as BusinessError;
      pngBuffer = undefined;
    }
    if (pngBuffer === undefined) {
      this.busying = false;
      this.toast('图片编码失败，可以直接截屏保存');
      return;
    }

    // ---------- ③ 先写沙箱（showAssetsCreationDialog 要的是源文件 uri） ----------
    const tempPath: string = this.tempCardPath();
    if (!this.writeBuffer(tempPath, pngBuffer)) {
      this.busying = false;
      this.toast('临时文件写入失败，可以直接截屏保存');
      return;
    }

    // ---------- ④ 申请相册写入（用户点确认才落盘） ----------
    const tempUri: string = 'file://' + tempPath;
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const configs: photoAccessHelper.PhotoCreationConfig[] = [{
        title: 'walkaholic-territory',
        fileNameExtension: '.png',
        photoType: photoAccessHelper.PhotoType.IMAGE,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      }];
      const targetUris: string[] = await helper.showAssetsCreationDialog([tempUri], configs);
      if (targetUris.length === 0) {
        this.deleteQuietly(tempPath);
        this.busying = false;
        this.toast('已取消保存');
        return;
      }

      // ---------- ⑤ 字节复制到相册目标 uri ----------
      const srcFile: fs.File = fs.openSync(tempPath, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(srcFile.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(srcFile.fd, buffer);
      fs.closeSync(srcFile.fd);

      const destFile: fs.File = fs.openSync(targetUris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(destFile.fd, buffer);
      fs.closeSync(destFile.fd);

      this.deleteQuietly(tempPath);
      this.busying = false;
      this.toast('已保存到相册');
    } catch (err) {
      const error = err as BusinessError;
      this.deleteQuietly(tempPath);
      this.busying = false;
      this.toast('保存失败（' + String(error.code) + '），可以直接截屏');
    }
  }

  // ============================================================
  // 布局
  // ============================================================

  build() {
    Column({ space: 14 }) {
      // 卡片本体：按 720×960 比例自适应屏宽（Canvas 内部按 CARD_WIDTH 画再缩放）
      Column() {
        Canvas(this.ctx)
          .width('100%')
          .aspectRatio(CARD_WIDTH / CARD_HEIGHT)
          .onReady(() => {
            this.ready = true;
            this.draw();
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const next: number = parseFloat(newValue.width.toString());
            if (Math.abs(next - this.canvasWidth) > 0.5) {
              this.canvasWidth = next;
              this.draw();
            }
          })
      }
      .width('100%')
      .id(CARD_NODE_ID)
      .clip(true)
      .borderRadius(WASize.cardRadius)
      .shadow({ radius: 24, color: WAColor.shadow, offsetX: 0, offsetY: 12 })

      Text('长按图片也可以直接截图保存')
        .fontSize(WAFont.microSm)
        .fontColor(WAColor.ink3)
        .width('100%')
        .textAlign(TextAlign.Center)

      Row({ space: 10 }) {
        Button() {
          Text('关闭')
            .fontSize(WAFont.bodySm)
            .fontColor(WAColor.ink2)
        }
        .type(ButtonType.Capsule)
        .height(WASize.buttonHeight)
        .layoutWeight(1)
        .backgroundColor(WAColor.paper2)
        .onClick(() => {
          this.onClose();
        })

        Button() {
          Text(this.busying ? '正在保存…' : '保存到相册')
            .fontSize(WAFont.bodySm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.iconOnBrand)
        }
        .type(ButtonType.Capsule)
        .height(WASize.buttonHeight)
        .layoutWeight(1)
        .backgroundColor(WAColor.amber)
        .enabled(!this.busying)
        .opacity(this.busying ? 0.6 : 1)
        .onClick(() => {
          this.saveToAlbum();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding })
  }
}

function emptyStats(): TerritoryStats {
  const stats: TerritoryStats = {
    pointCount: 0,
    hull: [],
    hullPointCount: 0,
    areaM2: 0,
    areaKm2: 0,
    spanM: 0
  };
  return stats;
}

function emptyRank(): TerritoryRankResult {
  const rank: TerritoryRankResult = {
    rank: {
      key: 'commoner',
      order: 0,
      title: '白身',
      seal: '民',
      thresholdKm2: 0,
      minPoints: 0,
      color: '#9CA3AF',
      desc: '还没有自己的疆域'
    },
    progress: 0,
    toNextKm2: 0,
    areaKm2: 0,
    capped: false,
    pointsNeeded: 0
  };
  return rank;
}