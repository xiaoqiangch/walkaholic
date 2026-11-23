/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 揭晓 Reveal（design-system §5.4）
 *
 * 视觉基准：prototype/web/app.js revealOpenHTML / revealCardHTML + screenshots/showcase.png
 * 两段：
 * 1. 开盒（1.2s，深色 ink 舞台：盒子抖动 → 盒盖弹飞 + 暖光 + 纸屑）→「这次，城市选了这个地方。」
 * 2. 卡片（稀有度 + 编号 + 类别 emoji + 地点名 + 区域/类别/地址 + 为什么是这里 + 小任务 + 收进图鉴/分享）
 *
 * 保密：只有本页（到达后）才展示 currentPlace.name / address / category。
 *
 * ## 到达验证（docs/territory.md §四）
 * 「来了」不能只信手机 GPS（可伪造）。真实地点要求：
 * **在目的地 120 米内拍一张照片，照片 EXIF 自带 GPS**，系统读照片坐标比对。
 * - 成功 → 记录 photoGps / photoDistance 到卡片（疆域计算优先用它）
 * - 失败 → 按 reason 给出精准指引（去哪个设置开什么开关 / 走近多少米）
 * - **演示地点无坐标 → 跳过验证**（不因为「没有坐标」判用户失败）
 */

import { common } from '@kit.AbilityKit';
import { getStore } from '../core/store';
import { AppSnapshot, CollectResult, KeyValueStore } from '../core/contract';
import { Achievement, FeedPost, GeoPoint, Place, QuestPhase } from '../core/types';
import { HttpClient } from '../core/http';
import { AccountConfig, isLoggedIn, readAccountConfig } from '../core/account';
import { uploadCheckInPhoto } from '../core/surpriseRemote';
import {
  PickedPhoto,
  photoDataURL,
  pickAndAdoptPhoto,
  readPhotoAsBase64,
  takeAndAdoptPhoto,
  toImageUri
} from '../components/PhotoPick';
import {
  PhotoArrivalCheck,
  PhotoGpsFailure,
  PhotoGpsPoint,
  PHOTO_RADIUS_METERS,
  checkPhotoArrival,
  photoFailHowto,
  photoFailSteps,
  photoFailText
} from '../core/photo-gps';
import {
  WaHairline,
  WaMicroLabel,
  WaRarityBadge,
  WaToastBar
} from '../components/Common';
import { emptyPlace, emptySnapshot, readSnapshot } from '../components/StoreBridge';
import {
  WAColor,
  WAFont,
  WASize,
  areaWord
} from '../theme/Theme';
import { clockHHMM } from '../components/Format';
import { categorySymbol } from '../components/WaSymbol';
import {
  LocationFix,
  getLocationFix,
  requestLocationPermission
} from '../components/Location';

/** 拍照兜底定位的超时（毫秒）：太短拿不到点，太长用户会以为卡住 */
const PHOTO_LOCATION_TIMEOUT_MS: number = 4000;

const PARTICLE_INDEXES: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

@Component
export struct RevealView {
  @Prop winWidth: number = 400;
  @Prop winHeight: number = 800;
  /** 从导航页 10 米到达对话框点击「立即拍照打卡」进入时，直接展开卡片并自动拉起相机打卡 */
  @Prop autoCheckIn: boolean = false;

  /** 收录完成 → 回图鉴（Index 切 tab） */
  onGoCards: () => void = () => {
  };
  /**
   * 关闭揭晓（回上一屏）。
   *
   * 之前这个回调根本不存在，关闭按钮又只在「已收录」后才渲染 ——
   * 于是「没通过拍照验证 / 不想收录」的用户被关在一个全屏层里出不去。
   * 现在关闭按钮**永远在**：已收录 → 去图鉴；未收录 → 直接关掉这一层。
   */
  onClose: () => void = () => {
  };
  onChanged: () => void = () => {
  };

  @State private snapshot: AppSnapshot = emptySnapshot();
  @State private showCard: boolean = false;
  @State private boxShake: number = 0;
  @State private lidUp: boolean = false;
  @State private lightOn: boolean = false;
  @State private particlesOut: boolean = false;
  @State private particlesFade: boolean = false;
  @State private hasCollected: boolean = false;
  @State private hasShared: boolean = false;
  @State private collecting: boolean = false;
  @State private taskDone: boolean = false;
  @State private toastText: string = '';
  @State private toastIcon: string = 'star_fill';
  @State private achievementText: string = '';

  /** 平台能力（拍到 / 选到的照片要落本机并尽力上传账号） */
  http: HttpClient | undefined = undefined;
  kv: KeyValueStore | undefined = undefined;

  /** 到达实拍：本地优先（离线也有），登录后上传账号（按地点存、可重拍覆盖） */
  @State private checkInUri: string = '';
  @State private checkInRemotePath: string = '';
  @State private uploadingPhoto: boolean = false;
  /** 正在取定位 / 等待拍照（这一步最长要几秒，必须让用户看到在做事情） */
  @State private locating: boolean = false;
  /** 到达验证通过（照片带 GPS 且距离达标；演示地点也置 true） */
  @State private verifiedArrival: boolean = false;
  /** 验证失败：标题 */
  @State private verifyFailTitle: string = '';
  /** 验证失败：操作指引 */
  @State private verifyFailHowto: string = '';
  @State private verifyFailSteps: string[] = [];
  /** 验证失败原因（用于区分「去改设置」和「走近一点」） */
  @State private verifyFailReason: string = '';
  /** 验证凭据来源：photo = 照片 EXIF，device = 拍照瞬间的设备定位 */
  @State private verifySource: string = '';
  /** 已验证的坐标与距离（收录后再补挂凭证时复用，不重算） */
  private verifiedGps: PhotoGpsPoint | undefined = undefined;
  private verifiedDistance: number = 0;

  private stageTimers: number[] = [];
  private toastTimer: number = -1;

  aboutToAppear(): void {
    this.load();
    this.playOpening();
  }

  aboutToDisappear(): void {
    for (let i = 0; i < this.stageTimers.length; i++) {
      clearTimeout(this.stageTimers[i]);
    }
    this.stageTimers = [];
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private load(): void {
    this.snapshot = readSnapshot(this.snapshot);
    // 这张卡是否已经收过：关掉揭晓再进来时必须还原成「去看看图鉴」，
    // 否则按钮又变回「收进图鉴」，点下去只会得到一句「已经在图鉴里了」。
    const placeID: string = this.currentPlaceID();
    if (placeID.length > 0 && !this.hasCollected) {
      for (let i = 0; i < this.snapshot.profile.cards.length; i += 1) {
        if (this.snapshot.profile.cards[i].placeID === placeID) {
          this.hasCollected = true;
          break;
        }
      }
    }
    this.loadExistingCheckInPhoto();
  }

  // ============================================================
  // 到达实拍
  // ============================================================

  private currentPlaceID(): string {
    const place: Place | undefined = this.snapshot.currentPlace;
    return place === undefined ? '' : place.id;
  }

  /** 已经有照片（本机或账号）就显示出来 */
  private loadExistingCheckInPhoto(): void {
    const placeID: string = this.currentPlaceID();
    if (placeID.length === 0 || this.checkInUri.length > 0) return;
    try {
      const photo = getStore().cardPhoto(placeID);
      if (photo === undefined) return;
      if (photo.local !== undefined && photo.local.length > 0) this.checkInUri = photo.local;
      if (photo.remote !== undefined) this.checkInRemotePath = photo.remote;
    } catch (err) {
      // 没有照片就是没有
    }
    this.restoreVerifiedFromCard(placeID);
  }

  /**
   * 从已落盘的卡片恢复「已验证」状态。
   *
   * 场景：用户拍完照、验证通过，关掉揭晓页没收录，再进来 ——
   * 照片还在（沙箱），但 verifiedArrival 是组件内状态，重建后归 false。
   * 不恢复的话，用户会被要求「再拍一张」才能收录，尽管凭证早就存好了。
   */
  private restoreVerifiedFromCard(placeID: string): void {
    if (this.verifiedArrival) return;
    try {
      const gps = getStore().cardPhotoGps(placeID);
      if (gps === undefined) return;
      this.verifiedArrival = true;
      this.verifySource = 'photo';
      this.verifiedGps = {
        lat: gps.location.latitude,
        lon: gps.location.longitude
      };
      this.verifiedDistance = gps.distanceMeters;
      this.clearVerifyFail();
    } catch (err) {
      // 没有凭证就是没有
    }
  }

  private uploadStatusText(): string {
    if (this.uploadingPhoto) return '上传中…';
    if (this.checkInRemotePath.length > 0) return '已上传 · 换机可找回';
    if (this.kv === undefined) return '仅存本机';
    const config: AccountConfig = readAccountConfig(this.kv);
    return isLoggedIn(config) ? '仅存本机（稍后可再上传）' : '仅存本机 · 登录后可同步';
  }

  // ============================================================
  // 到达验证（docs/territory.md §四）
  // ============================================================

  /**
   * 目的地真实坐标；undefined = 演示地点 / 没有坐标 → 跳过验证。
   */
  private targetCoordinate(): GeoPoint | undefined {
    const place: Place | undefined = this.place();
    if (place === undefined) return undefined;
    const coordinate: GeoPoint | undefined = place.coordinate;
    if (coordinate === undefined) return undefined;
    if (!isFinite(coordinate.latitude) || !isFinite(coordinate.longitude)) return undefined;
    return coordinate;
  }

  /** 这个地点是否要求拍照验证（只有真实地点要求） */
  private requiresPhotoVerification(): boolean {
    return this.targetCoordinate() !== undefined;
  }

  private clearVerifyFail(): void {
    this.verifyFailTitle = '';
    this.verifyFailHowto = '';
    this.verifyFailSteps = [];
    this.verifyFailReason = '';
  }

  /**
   * 拍完照片 → 读 EXIF GPS → 验证是否在目的地 120 米内。
   *
   * 为什么必须**在原图上读**：canvas 重编码 / 社交软件转发都会丢 EXIF。
   * 这里读的是 picker 给的原图（落沙箱时逐字节复制，EXIF 完整保留）。
   *
   * `fallbackGps`：App 内拍照时拍照瞬间的设备定位。鸿蒙 CameraPicker 受隐私规格限制
   * **永远不写 GPS**（华为官方 FAQ faqs-camera-58），所以这条路径只能用设备定位兜底；
   * 相册选图走照片自己的 EXIF，更可信。
   */
  private verifyArrivalPhoto(uri: string, fallbackGps?: PhotoGpsPoint): void {
    const target: GeoPoint | undefined = this.targetCoordinate();
    if (target === undefined) {
      // 演示地点：跳过验证，照片只作纪念
      this.verifiedArrival = true;
      this.clearVerifyFail();
      return;
    }

    const base64: string = readPhotoAsBase64(uri);
    if (base64.length === 0) {
      this.verifiedArrival = false;
      this.verifyFailReason = 'notImage';
      this.verifyFailTitle = photoFailText('notImage');
      this.verifyFailHowto = photoFailHowto('notImage');
      this.verifyFailSteps = photoFailSteps('notImage');
      return;
    }

    const check: PhotoArrivalCheck = checkPhotoArrival(
      target, base64, PHOTO_RADIUS_METERS, fallbackGps
    );
    if (check.demoSkip) {
      this.verifiedArrival = true;
      this.clearVerifyFail();
      return;
    }
    if (check.ok) {
      this.verifiedArrival = true;
      this.verifySource = check.source;
      this.verifiedGps = check.photoGps;
      this.verifiedDistance = check.distanceMeters === undefined ? 0 : check.distanceMeters;
      this.clearVerifyFail();
      // 记录验证凭证（疆域计算优先用照片坐标，比手机 GPS 可信）
      const placeID: string = this.currentPlaceID();
      if (placeID.length > 0 && check.photoGps !== undefined) {
        try {
          getStore().attachCardPhotoGps(
            placeID,
            { latitude: check.photoGps.lat, longitude: check.photoGps.lon },
            this.verifiedDistance
          );
        } catch (err) {
          // 卡片还没收录时挂不上，收录后再补
        }
      }
      return;
    }

    this.verifiedArrival = false;
    this.verifiedGps = undefined;
    this.verifyFailReason = check.reason === undefined ? 'noData' : check.reason;
    this.verifyFailTitle = check.title;
    this.verifyFailHowto = check.howto;
    this.verifyFailSteps = photoFailSteps((check.reason !== undefined ? check.reason : 'notImage') as PhotoGpsFailure);
  }

  /** 收录后再补挂一次验证凭证（先拍后收录的顺序）：直接复用已验证的坐标，不重算 */
  private attachGpsIfVerified(placeID: string): void {
    if (!this.verifiedArrival || placeID.length === 0) return;
    const gps: PhotoGpsPoint | undefined = this.verifiedGps;
    if (gps === undefined) return;
    try {
      getStore().attachCardPhotoGps(
        placeID,
        { latitude: gps.lat, longitude: gps.lon },
        this.verifiedDistance
      );
    } catch (err) {
      // 忽略
    }
  }

  /** 拍一张 / 换一张：先落本机（离线也有），再尽力上传账号 */
  private async capturePhoto(fromCamera: boolean): Promise<void> {
    if (this.uploadingPhoto || this.locating) return;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

    // 相机路径需要「拍照那一刻的设备定位」兜底：鸿蒙 CameraPicker 按隐私规格
    // **永远不给照片写 GPS**（华为官方 FAQ faqs-camera-58），相册路径才有 EXIF。
    //
    // ⚠️ 这里必须先**申请定位权限**。以前直接调 getCurrentLocationOnce：
    // 本页从未申请过 LOCATION，系统直接抛 201（permission denied），
    // 兜底坐标永远是 undefined —— 于是相机路径 100% 落在「照片没有位置信息」，
    // 用户看到的就是「一直说没位置」，而真正的原因是根本没拿到定位。
    let deviceFix: LocationFix | undefined = undefined;
    if (fromCamera) {
      try {
        const granted: boolean = await requestLocationPermission(context);
        if (!granted) {
          this.verifyFailTitle = '没有定位权限，没法确认你到了哪';
          this.verifyFailHowto = '系统相机组件拍出来的照片本身不带坐标，只能靠拍照那一刻的定位。' +
            '请允许「步迷」使用定位，然后重拍。';
          this.verifyFailReason = 'denied';
          this.verifyFailSteps = [
            '点「重拍」',
            '系统询问定位权限时选「允许」',
            '如果之前拒绝过：设置 → 应用 → 步迷 → 权限 → 位置信息 → 允许'
          ];
          this.showToast('需要定位权限才能验证到达', 'info_circle');
          return;
        }
        this.locating = true;
        deviceFix = await getLocationFix(PHOTO_LOCATION_TIMEOUT_MS);
        this.locating = false;
      } catch (err) {
        this.locating = false;
        deviceFix = undefined;
      }
    }

    let picked: PickedPhoto | undefined = undefined;
    try {
      picked = fromCamera ? await takeAndAdoptPhoto(context) : await pickAndAdoptPhoto(context);
    } catch (err) {
      picked = undefined;
    }
    if (picked === undefined) return;

    this.checkInUri = picked.uri;
    this.checkInRemotePath = '';
    // 到达验证：照片 EXIF 优先；鸿蒙 CameraPicker 不写 GPS，相机路径用设备定位兜底
    let fallback: PhotoGpsPoint | undefined = undefined;
    if (deviceFix !== undefined) {
      const point: PhotoGpsPoint = {
        lat: deviceFix.point.latitude,
        lon: deviceFix.point.longitude
      };
      fallback = point;
    }
    if (fallback === undefined && fromCamera) {
      // 最后一道兜底：旅程刚走过的真实定位（10 分钟内）。
      // 这个点来自真实 GPS（导航用的就是它），不是虚构坐标；
      // 比「直接判失败、让用户站在目的地却收不了卡」合理得多。
      try {
        const recent: GeoPoint | undefined = getStore().freshOrigin(10 * 60 * 1000);
        if (recent !== undefined) {
          const point: PhotoGpsPoint = {
            lat: recent.latitude,
            lon: recent.longitude
          };
          fallback = point;
        }
      } catch (err) {
        // 没有就没有
      }
    }
    this.verifyArrivalPhoto(picked.uri, fallback);
    // 二次机会：照片里没有坐标（截图、聊天软件转发、相册压缩）时，
    // 再用「现在这一刻的设备定位」试一次。
    //
    // 为什么这样做：EXIF 丢失去用户完全不可控（转发一次就没了），
    // 只报「这张照片没有位置信息」等于把用户挡在门外，而他确实就站在目的地。
    // 兜底坐标来自真实 GPS，UI 会明确标注凭据来源，不冒充「照片坐标已验证」。
    if (!this.verifiedArrival && this.isMissingGpsReason(this.verifyFailReason)) {
      const second: PhotoGpsPoint | undefined = await this.tryDeviceFallback();
      if (second !== undefined) {
        this.verifyArrivalPhoto(picked.uri, second);
        if (this.verifiedArrival) {
          this.showToast('按你当前的位置验证通过', 'checkmark_circle');
        }
      }
    }
    // 相机路径拿不到坐标时的文案修正。
    //
    // CameraPicker 拍的照片**必然没有 EXIF GPS**（系统隐私规格），所以这张照片
    // 「没有位置信息」是正常现象，真正失败的是「没取到设备定位」。
    // 直接沿用相册路径的「这张照片没有位置信息」会把用户引去改相机设置 —— 改一百次也没用。
    if (fromCamera && !this.verifiedArrival) {
      const reason: string = this.verifyFailReason;
      if (reason === 'noExif' || reason === 'noGpsTag' ||
        reason === 'noData' || reason === 'incompleteGps' || reason === 'unreadableGps') {
        this.verifyFailTitle = '没拿到你的实时位置';
        this.verifyFailHowto = '这一步要用拍照那一刻的定位确认你在目的地 ' +
          String(PHOTO_RADIUS_METERS) + ' 米内。这张照片来自系统相机组件，本身不带坐标。';
        this.verifyFailReason = 'noFix';
        this.verifyFailSteps = [
          '确认手机顶部下拉的「位置信息 / 定位」开关是打开的',
          '在室外或窗边再试一次（室内、地下车库经常定不到位）',
          '回到这里点「重拍」，拍完看到「位置已验证」再收进图鉴',
          '实在定不到：改用「换一张」，从相册选一张在目的地拍的照片'
        ];
      }
    }
    const placeID: string = this.currentPlaceID();
    if (placeID.length > 0) {
      try {
        getStore().attachCardPhoto(placeID, picked.uri);
      } catch (err) {
        // 卡片还没收录时挂不上，等收录后再补
      }
    }
    this.onChanged();
    this.uploadCheckInPhotoIfPossible(picked.uri, placeID);
  }

  /** 这些失败原因说明「没读到坐标」，而不是「坐标太远」—— 值得用设备定位再试一次 */
  private isMissingGpsReason(reason: string): boolean {
    return reason === 'noExif' || reason === 'noGpsTag' || reason === 'noData' ||
      reason === 'incompleteGps' || reason === 'unreadableGps' ||
      reason === 'pngNoExif' || reason === 'notImage' || reason === 'brokenExif';
  }

  /**
   * 用当前设备定位兜底（真实 GPS，不虚构）。
   *
   * 先申请权限再取点；取不到返回 undefined，绝不编造坐标。
   */
  private async tryDeviceFallback(): Promise<PhotoGpsPoint | undefined> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      const granted: boolean = await requestLocationPermission(context);
      if (!granted) {
        return undefined;
      }
      if (!this.locating) {
        this.locating = true;
      }
      const fix: LocationFix = await getLocationFix(PHOTO_LOCATION_TIMEOUT_MS);
      this.locating = false;
      const point: PhotoGpsPoint = {
        lat: fix.point.latitude,
        lon: fix.point.longitude
      };
      return point;
    } catch (err) {
      this.locating = false;
      // 取不到就退回「刚刚导航用过的真实定位」（10 分钟内）
      try {
        const recent: GeoPoint | undefined = getStore().freshOrigin(10 * 60 * 1000);
        if (recent !== undefined) {
          const point: PhotoGpsPoint = {
            lat: recent.latitude,
            lon: recent.longitude
          };
          return point;
        }
      } catch (inner) {
        // 没有就没有
      }
      return undefined;
    }
  }

  private async uploadCheckInPhotoIfPossible(uri: string, placeID: string): Promise<void> {
    if (this.http === undefined || this.kv === undefined || placeID.length === 0) return;
    const config: AccountConfig = readAccountConfig(this.kv);
    if (!isLoggedIn(config)) return;
    const dataUrl: string = photoDataURL(uri);
    if (dataUrl.length === 0) return;
    this.uploadingPhoto = true;
    const path: string | undefined = await uploadCheckInPhoto(
      this.http, config, this.kv, placeID, dataUrl
    );
    this.uploadingPhoto = false;
    if (path === undefined) {
      this.showToast('照片已存本机，上传失败（网络或登录状态）', 'info_circle');
      return;
    }
    this.checkInRemotePath = path;
    try {
      getStore().attachCardPhoto(placeID, uri, path);
    } catch (err) {
      // 同上
    }
    this.showToast('照片已上传到账号', 'checkmark_circle');
    this.onChanged();
  }

  /**
   * 到达验证失败提示（docs §四：必须给出**具体的操作指引**，不能只说"失败"）。
   *
   * - `noGpsTag` → 去设置开相机的位置信息
   * - `tooFar` → 带实测距离，提示走近一点
   * - `noExif` → 别用截图/转发图
   */
  @Builder
  verifyFailBanner() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(WAFont.captionSm)
          .fontColor([WAColor.ember])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text(this.verifyFailTitle)
          .fontSize(WAFont.captionSm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ember)
          .maxLines(2)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.verifyFailSteps.length > 0) {
        Text('照下面这样做：')
          .fontSize(WAFont.microSm)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink2)
          .width('100%')
        ForEach(this.verifyFailSteps, (step: string, index: number) => {
          Row({ space: 6 }) {
            Text(String(index + 1))
              .fontSize(WAFont.microSm)
              .fontWeight(FontWeight.Bold)
              .fontColor(WAColor.ember)
              .textAlign(TextAlign.Center)
              .width(16)
              .height(16)
              .borderRadius(8)
              .backgroundColor('#1AFA2A2D')
            Text(step)
              .fontSize(WAFont.microSm)
              .fontColor(WAColor.ink2)
              .lineHeight(17)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (step: string, index: number) => String(index) + step)
      } else {
        Text(this.verifyFailHowto)
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink2)
          .lineHeight(17)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor('#1AFA2A2D')
    .borderRadius(WASize.cardRadiusSm)
    .border({ width: 1, color: '#33FA2A2D', radius: WASize.cardRadiusSm })
  }

  /** 验证通过的小标识（让用户知道这张照片算数，并说清凭据来源） */
  @Builder
  verifyPassBadge() {
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize(WAFont.microSm)
        .fontColor([WAColor.teal])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(this.verifyPassText())
        .fontSize(WAFont.microSm)
        .fontColor(WAColor.teal)
        .maxLines(2)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 验证通过文案。
   *
   * `photo` 是照片自己带的坐标（最可信）；`device` 是鸿蒙 App 内拍照时
   * 用拍照瞬间的设备定位兜底 —— 必须让用户知道差别，不能冒充「照片坐标已验证」。
   */
  private verifyPassText(): string {
    if (!this.requiresPhotoVerification()) {
      return '演示地点 · 照片只作纪念';
    }
    if (this.verifySource === 'device') {
      return '位置已验证 · 拍照时你在目的地 ' + String(PHOTO_RADIUS_METERS) + ' 米内（相机不写坐标，按拍照时的定位判定）';
    }
    return '位置已验证 · 照片就在目的地附近';
  }

  /** 「收进图鉴」是否被门禁拦住（真实地点 + 还没通过验证） */
  private collectBlocked(): boolean {
    if (this.hasCollected) {
      return false;
    }
    return this.requiresPhotoVerification() && !this.verifiedArrival;
  }

  /** 拦住了要说清下一步该干什么（一句话，放在按钮上方） */
  private collectBlockedText(): string {
    if (this.checkInUri.length === 0) {
      return '先拍一张现场照片，验证你在目的地 ' + String(PHOTO_RADIUS_METERS) + ' 米内';
    }
    if (this.verifyFailTitle.length > 0) {
      return this.verifyFailTitle + ' · 点上面的「重拍」再试';
    }
    return '这张照片还不能算「到了」 · 走近一点重拍';
  }

  /** 到达实拍区块（与 iOS RevealView.checkInPhotoSection 同语义） */
  @Builder
  checkInPhotoSection() {
    Column({ space: 6 }) {
      if (this.requiresPhotoVerification()) {
        Text('要到「到了」还得拍一张：照片里的位置要在 ' + String(PHOTO_RADIUS_METERS) +
          ' 米内，这样才算真的来过。')
          .fontSize(WAFont.microSm)
          .fontColor(WAColor.ink3)
          .lineHeight(16)
          .width('100%')
      }

      if (this.verifyFailTitle.length > 0) {
        this.verifyFailBanner()
      }

      if (this.checkInUri.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(toImageUri(this.checkInUri))
            .width('100%')
            .height(168)
            .objectFit(ImageFit.Cover)
            .borderRadius(WASize.cardRadiusSm)
            .border({ width: 1, color: WAColor.line, radius: WASize.cardRadiusSm })
            .alt($r('app.media.app_icon'))

          Text('你拍的')
            .fontSize(WAFont.micro)
            .fontWeight(FontWeight.Bold)
            .fontColor(WAColor.iconOnBrand)
            .padding({ left: 9, right: 9 })
            .height(22)
            .backgroundColor('#9E182431')
            .borderRadius(WASize.chipRadius)
            .margin(10)
        }
        .width('100%')

        if (this.verifiedArrival) {
          this.verifyPassBadge()
        }

        Row({ space: 10 }) {
          Text('重拍')
            .fontSize(WAFont.captionSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink2)
            .onClick(() => {
              this.capturePhoto(true);
            })
          Text('换一张')
            .fontSize(WAFont.captionSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink2)
            .onClick(() => {
              this.capturePhoto(false);
            })
          Blank()
          Text(this.uploadStatusText())
            .fontSize(WAFont.microSm)
            .fontColor(this.checkInRemotePath.length > 0 ? WAColor.teal : WAColor.ink3)
            .maxLines(1)
        }
        .width('100%')
      } else {
        Row({ space: 10 }) {
          Button() {
            Row({ space: 6 }) {
              SymbolGlyph($r(this.locating ? 'sys.symbol.clock' : 'sys.symbol.pin'))
                .fontSize(WAFont.caption)
                .fontColor([WAColor.ink])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              Text(this.locating ? '正在定位…' : '拍一张 · 记下这一刻')
                .fontSize(WAFont.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(WAColor.ink)
            }
          }
          .type(ButtonType.Normal)
          .height(44)
          .layoutWeight(1)
          .backgroundColor(WAColor.amberSoft)
          .borderRadius(WASize.cardRadiusSm)
          .border({
            width: 1,
            color: WAColor.amberBorder,
            radius: WASize.cardRadiusSm,
            style: BorderStyle.Dashed
          })
          .enabled(!this.locating)
          .onClick(() => {
            this.capturePhoto(true);
          })

          Button() {
            SymbolGlyph($r('sys.symbol.square_grid_2x2'))
              .fontSize(WAFont.titleSm)
              .fontColor([WAColor.ink2])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .type(ButtonType.Normal)
          .width(44)
          .height(44)
          .backgroundColor(WAColor.paper2)
          .borderRadius(WASize.cardRadiusSm)
          .border({ width: 1, color: WAColor.line, radius: WASize.cardRadiusSm })
          .onClick(() => {
            this.capturePhoto(false);
          })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private place(): Place | undefined {
    return this.snapshot.currentPlace;
  }

  private placeSafe(): Place {
    const place: Place | undefined = this.snapshot.currentPlace;
    return place === undefined ? emptyPlace() : place;
  }

  private isShort(): boolean {
    return this.winHeight < WASize.shortHeightBreakpoint;
  }

  private serialText(): string {
    const serial: string | undefined = this.snapshot.revealSerial;
    return 'No.' + (serial === undefined ? '----' : serial);
  }

  private placeMeta(place: Place): string {
    let meta: string = areaWord(place.area) + ' · ' + place.category;
    if (place.address !== undefined && place.address.length > 0) {
      meta = meta + ' · ' + place.address;
    }
    return meta;
  }

  /** 来源标签（parity.md §1：编辑精选 / 真实地标 / 演示） */
  private sourceLabel(place: Place): string {
    if (place.source === 'curated') return '编辑精选';
    if (place.source === 'amap') return '高德地图 · 真实地点';
    if (place.source === 'baidu') return '百度地图 · 真实地点';
    if (place.source === 'osm') return 'OpenStreetMap · 真实地点';
    if (place.source === 'wiki') return '维基百科 · 真实地标';
    return '仅存本机';
  }

  private hasPhoto(place: Place): boolean {
    return place.photoUrl !== undefined && place.photoUrl.length > 0;
  }

  private isCurated(place: Place): boolean {
    return place.source === 'curated';
  }

  // ============================================================
  // 开盒动画
  // ============================================================

  private playOpening(): void {
    if (this.autoCheckIn) {
      getStore().confirmReveal();
      this.load();
      this.showCard = true;
      if (!this.verifiedArrival && this.checkInUri.length === 0) {
        this.stageTimers.push(setTimeout(() => {
          this.capturePhoto(true);
        }, 120));
      }
      return;
    }

    // 已经揭晓过（用户关掉又回来）：不要再放一遍开盒动画，
    // 直接落到卡片 —— 同一张卡放两次盒子会让人以为又抽到了一次。
    const phase: QuestPhase | undefined = this.snapshot.session === undefined
      ? undefined
      : this.snapshot.session.phase;
    if (phase === QuestPhase.Revealed || phase === QuestPhase.Collected) {
      this.showCard = true;
      return;
    }

    // 盒子抖动 600ms（±6° 三次）
    animateTo({
      duration: 100,
      curve: Curve.EaseInOut,
      iterations: 6,
      playMode: PlayMode.Alternate
    }, () => {
      this.boxShake = 6;
    });

    // 盒盖弹开 + 暖光 + 纸屑
    this.stageTimers.push(setTimeout(() => {
      animateTo({ duration: 450, curve: Curve.Friction }, () => {
        this.lidUp = true;
        this.lightOn = true;
        this.particlesOut = true;
      });
    }, 700));

    // 纸屑淡出
    this.stageTimers.push(setTimeout(() => {
      animateTo({ duration: 520, curve: Curve.EaseOut }, () => {
        this.particlesFade = true;
      });
    }, 1050));

    // 1.2s 后切到卡片（先让 store 进入 revealed 态）
    this.stageTimers.push(setTimeout(() => {
      getStore().confirmReveal();
      this.load();
      animateTo({ duration: 520, curve: Curve.EaseOut }, () => {
        this.showCard = true;
      });
    }, 1200));
  }

  // ============================================================
  // Toast
  // ============================================================

  private showToast(text: string, icon: string): void {
    this.toastText = text;
    this.toastIcon = icon;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toastText = '';
      this.toastTimer = -1;
    }, 2600);
  }

  private showAchievement(achievement: Achievement): void {
    this.achievementText = '成就解锁 · ' + achievement.name;
    this.stageTimers.push(setTimeout(() => {
      this.achievementText = '';
    }, 3400));
  }

  // ============================================================
  // 交互
  // ============================================================

  /**
   * 关闭揭晓层。
   *
   * 已收录 → 去图鉴（用户期待看到刚收的卡）；未收录 → 直接退出这一层，
   * 旅程仍在 store 里，从首页「继续」还能回来，不会丢进度。
   */
  private closeStage(): void {
    if (this.hasCollected) {
      this.onGoCards();
      return;
    }
    this.onClose();
  }

  private collectCard(): void {
    if (this.collecting) {
      return;
    }
    if (this.hasCollected) {
      this.onGoCards();
      return;
    }

    // 真实地点：必须先在目的地 120 米内拍一张带 GPS 的照片（docs §四）
    if (this.requiresPhotoVerification() && !this.verifiedArrival) {
      if (this.checkInUri.length === 0) {
        this.verifyFailTitle = '先拍一张照片才能收进来';
        this.verifyFailHowto = '照片里的位置要和这里一致（' + String(PHOTO_RADIUS_METERS) +
          ' 米内），这样才算你真的来过。';
        this.verifyFailReason = 'needPhoto';
        this.verifyFailSteps = [
          '点上面的「拍一张 · 记下这一刻」',
          '允许定位（照片验证要用拍照那一刻的位置）',
          '拍完看到「位置已验证」再点收进图鉴'
        ];
        this.showToast('先拍一张带位置的现场照片', 'info_circle');
      } else {
        // 已经有照片但没通过验证：**必须给出可操作的提示**。
        // 以前这里直接 return —— 用户点了按钮毫无反应，也没有任何解释。
        if (this.verifyFailTitle.length === 0) {
          this.verifyFailTitle = '这张照片还不能算「到了」';
          this.verifyFailHowto = '照片里的位置要在目的地 ' + String(PHOTO_RADIUS_METERS) +
            ' 米内。走近一点重拍，或点上面的「重拍」再试一次。';
          this.verifyFailReason = 'needPhoto';
        }
        this.showToast(this.verifyFailTitle, 'info_circle');
      }
      return;
    }

    const result: CollectResult | undefined = getStore().collectCurrentPlace();
    if (result === undefined) {
      this.showToast('这张卡已经在图鉴里了。', 'checkmark_circle');
      this.hasCollected = true;
      this.onChanged();
      return;
    }

    this.hasCollected = true;
    // 到达实拍：如果先拍了照片、之后再收录，这里补挂到卡片上
    if (this.checkInUri.length > 0) {
      const placeID: string = result.card.placeID;
      try {
        getStore().attachCardPhoto(placeID, this.checkInUri,
          this.checkInRemotePath.length > 0 ? this.checkInRemotePath : undefined);
      } catch (err) {
        // 照片挂不上不影响收录
      }
      // 验证凭证（照片 EXIF 坐标 + 距离）
      this.attachGpsIfVerified(placeID);
    }
    this.load();
    this.onChanged();

    // 卡片缩小飞向 Tab 图鉴，飞完再落回原位
    animateTo({ duration: 520, curve: Curve.Friction }, () => {
      this.collecting = true;
    });
    this.stageTimers.push(setTimeout(() => {
      animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
        this.collecting = false;
      });
    }, 620));

    this.showToast('已收录 · 惊喜值 +' + result.xpGained, 'star_fill');

    // 成就 toast 延后 600ms
    if (result.newAchievements.length > 0) {
      this.stageTimers.push(setTimeout(() => {
        this.showAchievement(result.newAchievements[0]);
      }, 640));
    }
  }

  private shareToCircle(): void {
    if (this.collecting) {
      return;
    }
    const place: Place | undefined = this.place();
    if (place === undefined) {
      this.showToast('还没有可以分享的地点。', 'info_circle');
      return;
    }
    const post: FeedPost | undefined = getStore().share('走到了「' + place.name + '」。');
    if (post === undefined) {
      this.showToast('分享没成功，再试一次。', 'info_circle');
      return;
    }
    this.hasShared = true;
    this.onChanged();
    this.showToast('已发布到圈子', 'heart_fill');
  }

  private toggleTaskDone(): void {
    if (this.collecting) {
      return;
    }
    this.taskDone = !this.taskDone;
  }

  // ============================================================
  // 开盒舞台
  // ============================================================

  @Builder
  particlePiece(index: number) {
    Row()
      .width(5 + (index % 3) * 2)
      .height(7 + (index % 3) * 2)
      .backgroundColor(index % 2 === 0 ? WAColor.amber : WAColor.ember)
      .borderRadius(1.5)
      .rotate({ angle: index * 30 + (this.particlesOut ? 150 : 0) })
      .translate({
        x: this.particlesOut
          ? Math.cos(index / 12 * Math.PI * 2) * (100 + (index % 3) * 28)
          : Math.cos(index / 12 * Math.PI * 2) * 12,
        y: this.particlesOut
          ? Math.sin(index / 12 * Math.PI * 2) * (100 + (index % 3) * 28)
          : Math.sin(index / 12 * Math.PI * 2) * 12
      })
      .opacity(this.particlesFade ? 0 : (this.particlesOut ? 1 : 0))
  }

  @Builder
  openingStage() {
    Stack({ alignContent: Alignment.Center }) {
      // 深色舞台 + 暖光
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WAColor.stage)

      Circle()
        .width(300)
        .height(300)
        .fill(this.lightOn ? '#73E89B4C' : '#00E89B4C')
        .blur(46)
        .translate({ y: -this.winHeight * 0.08 })

      Column({ space: 26 }) {
        Stack({ alignContent: Alignment.Center }) {
          // 纸屑
          ForEach(PARTICLE_INDEXES, (index: number) => {
            this.particlePiece(index)
          }, (index: number) => String(index))

          // 盒盖
          Row()
            .width(156)
            .height(35)
            .backgroundColor(WAColor.kraftLid)
            .borderRadius(5)
            .border({ width: 1.8, color: '#E6171410', radius: 5 })
            .rotate({ angle: this.lidUp ? -26 : 0 })
            .translate({ x: this.lidUp ? 36 : 0, y: this.lidUp ? -148 : -38 })

          // 盒体
          Column() {
            Text('?')
              .fontSize(50)
              .fontWeight(FontWeight.Bold)
              .fontColor(WAColor.ink)
          }
          .width(140)
          .height(92)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(WAColor.kraftBody)
          .borderRadius(8)
          .border({ width: 1.8, color: '#E6171410', radius: 8 })
          .translate({ y: 26 })
        }
        .width(320)
        .height(246)
        .rotate({ angle: this.lidUp ? 0 : this.boxShake })

        Text('这次，城市选了这个地方。')
          .fontSize(WAFont.bodySm)
          .fontColor(this.lightOn ? WAColor.creamOnStage : WAColor.creamOnStageDim)
          .textAlign(TextAlign.Center)
          .padding({ left: 40, right: 40 })
      }
      .width('100%')
      .translate({ y: -30 })
    }
    .width('100%')
    .height('100%')
  }

  // ============================================================
  // 卡片舞台
  // ============================================================

  @Builder
  stageBar() {
    Row() {
      Text(clockHHMM())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(WAColor.creamOnStage)

      Blank()
      // 关闭按钮**必须永远在**（全屏覆盖层没有系统的下滑关闭，
      // 之前只在 hasCollected 时才渲染 → 未收录的用户被彻底关住）。
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(WAFont.caption)
          .fontColor([WAColor.creamOnStage])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }
      .width(32)
      .height(32)
      .backgroundColor(WAColor.stageCloseBorder)
      .borderRadius(16)
      .onClick(() => {
        this.closeStage();
      })
    }
    .width('100%')
    .height(46)
    .padding({ left: WASize.pagePadding, right: WASize.pagePadding })
  }

  /**
   * 小任务卡（紧凑版）。
   *
   * 之前的问题：`Text(place.task)` 上挂了 `layoutWeight(1)`，而它所在的 Row 没有固定高度 ——
   * layoutWeight 在「高度不受约束」的容器里会吃掉整块剩余空间，
   * 于是一句话的小任务被撑成半屏大空白框（真机截图里非常明显）。
   * 现在改成：Text 不参与权重分配，只按内容高度排，最多 3 行。
   */
  @Builder
  taskCard(place: Place) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.warning'))
            .fontSize(WAFont.micro)
            .fontColor([WAColor.gold])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          WaMicroLabel({ text: '小任务' })
        }

        Text(place.task)
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink)
          .lineHeight(20)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.taskDone ? '已完成' : '完成')
        .fontSize(WAFont.micro)
        .fontColor(this.taskDone ? WAColor.teal : WAColor.amberDeep)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor(this.taskDone ? WAColor.tealSoft : WAColor.amberSoft)
        .borderRadius(WASize.chipRadius)
        .onClick(() => {
          this.toggleTaskDone();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(WAColor.paper2)
    .borderRadius(WASize.cardRadiusSm)
    .border({ width: 1, color: WAColor.line, radius: WASize.cardRadiusSm })
  }

  @Builder
  revealCard(place: Place) {
    Column({ space: 0 }) {
      Row() {
        Text(this.serialText())
          .fontSize(WAFont.micro)
          .fontWeight(FontWeight.Medium)
          .fontColor(WAColor.ink3)
          .letterSpacing(1)
        Blank()
        WaRarityBadge({ rarity: place.rarity })
      }
      .width('100%')
      .padding({ bottom: 13 })

      // 实景照片（只有到达后才展示；photoUrl 在 walking 阶段被 mask 掉）
      if (this.hasPhoto(place)) {
        Column({ space: 4 }) {
          Image(place.photoUrl)
            .width('100%')
            .height(this.isShort() ? 132 : 168)
            .objectFit(ImageFit.Cover)
            .borderRadius(WASize.cardRadiusSm)
            .border({ width: 1, color: WAColor.line, radius: WASize.cardRadiusSm })
            .alt($r('app.media.app_icon'))

          if (place.photoCredit !== undefined && place.photoCredit.length > 0) {
            Text('图片：' + place.photoCredit)
              .fontSize(WAFont.microSm)
              .fontColor(WAColor.ink3)
              .width('100%')
              .textAlign(TextAlign.End)
          }
        }
        .width('100%')
        .padding({ bottom: 8 })
      }

      Column({ space: 7 }) {
        SymbolGlyph($r('sys.symbol.' + categorySymbol(place.category)))
          .fontSize(46)
          .fontColor([WAColor.amber])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text(place.name)
          .fontSize(WAFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(WAColor.ink)
          .textAlign(TextAlign.Center)
          .maxLines(2)
        Text(this.placeMeta(place))
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .textAlign(TextAlign.Center)
          .maxLines(2)

        // 来源标签：编辑精选 / 真实地标 / 演示
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.' + (this.isCurated(place) ? 'star_fill' : (place.source === 'catalog' ? 'info_circle' : 'pin'))))
            .fontSize(WAFont.micro)
            .fontColor([WAColor.ink3])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          Text(this.sourceLabel(place))
            .fontSize(WAFont.microSm)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isCurated(place) ? WAColor.amberDeep
              : (place.source === 'catalog' ? WAColor.ink3 : WAColor.teal))
        }
        .padding({ left: 9, right: 9, top: 3, bottom: 3 })
        .backgroundColor(this.isCurated(place) ? WAColor.amberSoft
          : (place.source === 'catalog' ? WAColor.paper2 : WAColor.tealSoft))
        .borderRadius(WASize.chipRadius)

        if (place.summary !== undefined && place.summary.length > 0) {
          Text(place.summary)
            .fontSize(WAFont.captionSm)
            .fontColor(WAColor.ink3)
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .lineHeight(19)
        }
      }
      .width('100%')
      .padding({ bottom: 11 })

      WaHairline()

      Column() {
        this.checkInPhotoSection()
      }
      .margin({ top: 12 })

      WaHairline()

      Column({ space: 6 }) {
        WaMicroLabel({ text: '为什么是这里：' })
        Text(place.why)
          .fontSize(WAFont.caption)
          .fontColor(WAColor.ink2)
          .lineHeight(21)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      WaHairline()

      Column() {
        this.taskCard(place)
      }
      .margin({ top: 12 })

      // 门禁提示就贴在按钮上方：
      // 照片验证区块在卡片上半部分，用户滚到底部点按钮时是看不到的，
      // 点了没反应会以为「程序卡死」。这里把「为什么还不能收」放在手指边上。
      if (this.collectBlocked()) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(WAFont.microSm)
            .fontColor([WAColor.ember])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          Text(this.collectBlockedText())
            .fontSize(WAFont.microSm)
            .fontColor(WAColor.ember)
            .lineHeight(17)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ top: 10 })
      }

      Row({ space: 8 }) {
        Button() {
          Text(this.hasCollected ? '去看看图鉴' : '收进图鉴')
            .fontSize(WAFont.bodySm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink)
            .maxLines(1)
        }
        .type(ButtonType.Capsule)
        .height(46)
        .layoutWeight(1)
        .backgroundColor(WAColor.amber)
        .shadow({ radius: 12, color: WAColor.shadow, offsetX: 0, offsetY: 6 })
        .onClick(() => {
          this.collectCard();
        })

        Button() {
          Text(this.hasShared ? '已分享' : '分享')
            .fontSize(WAFont.bodySm)
            .fontWeight(FontWeight.Medium)
            .fontColor(WAColor.ink2)
        }
        .type(ButtonType.Capsule)
        .height(46)
        .width(96)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: WAColor.line, radius: WASize.chipRadius })
        .enabled(!this.hasShared)
        .opacity(this.hasShared ? 0.5 : 1)
        .onClick(() => {
          this.shareToCircle();
        })
      }
      .width('100%')
      .margin({ top: 14 })

      if (this.hasCollected) {
        Text('它现在是你的了。')
          .fontSize(WAFont.micro)
          .fontColor(WAColor.ink3)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 9 })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 17, bottom: 18 })
    .backgroundColor(WAColor.paper)
    .borderRadius(WASize.cardRadius)
    .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 6 })
    .rotate({ angle: -1.2 })
    .scale({
      x: this.collecting ? 0.26 : 1,
      y: this.collecting ? 0.26 : 1
    })
    .opacity(this.collecting ? 0 : 1)
    .translate({ y: this.collecting ? 250 : 0 })
  }

  @Builder
  cardStage() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(WAColor.stage)

      Circle()
        .width(360)
        .height(360)
        .fill('#14E89C4C')
        .blur(60)
        .translate({ x: this.winWidth * 0.25, y: -80 })

      Column({ space: 0 }) {
        this.stageBar()

        Scroll() {
          Column({ space: 0 }) {
            this.revealCard(this.placeSafe())

            Text('这个地点，只为你亮一次。')
              .fontSize(WAFont.micro)
              .fontColor(WAColor.creamOnStageDim)
              .textAlign(TextAlign.Center)
              .width('100%')
              .margin({ top: 14 })
          }
          .width('100%')
          .constraintSize({ maxWidth: 460 })
          .padding({ left: 26, right: 26, top: 12, bottom: 30 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  emptyStage() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 10 }) {
        Text('今晚的盲盒还没准备好。')
          .fontSize(WAFont.body)
          .fontColor(WAColor.creamOnStage)
        Text('再走一会儿。')
          .fontSize(WAFont.caption)
          .fontColor(WAColor.creamOnStageDim)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      // 这里同样需要出口：地点数据缺失时这一屏也是全屏层，
      // 没有关闭按钮同样是「关不掉」的死路。
      Column({ space: 0 }) {
        this.stageBar()
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(WAColor.stage)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.showCard) {
        if (this.place() === undefined) {
          this.emptyStage()
        } else {
          this.cardStage()
        }
      } else {
        this.openingStage()
      }

      // 底部 toast 堆叠
      Column({ space: 8 }) {
        if (this.achievementText.length > 0) {
          WaToastBar({
            text: this.achievementText,
            iconName: 'star_fill',
            amber: true
          })
        }
        if (this.toastText.length > 0) {
          WaToastBar({
            text: this.toastText,
            iconName: this.toastIcon,
            amber: false
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: WASize.pagePadding, right: WASize.pagePadding, bottom: 40 })
      .justifyContent(FlexAlign.End)
      // 只让提示条本身可点，其余区域继续透传给下面的卡片 / 按钮。
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
  }
}
