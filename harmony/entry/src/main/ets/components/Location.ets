/**
 * 步迷 Walkaholic · HarmonyOS ArkUI — 首页定位 / 权限小工具
 *
 * 位置权限申请走 abilityAccessCtrl.requestPermissionsFromUser（module.json5 已声明
 * ohos.permission.LOCATION / APPROXIMATELY_LOCATION）。
 * 拿不到定位（拒绝 / 关闭 / 超时）时由调用方明确提示失败；**绝不降级到虚构地点**。
 *
 * ⚠️ 待 DevEco 验证：geoLocationManager 的 API 12 写法（getCurrentLocation / on('locationChange')）。
 */

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { sensor } from '@kit.SensorServiceKit';
import { GeoPoint } from '../core/types';
import { bearing, distance } from '../core/geo';
import { MAX_WALKING_FIX_ACCURACY_METERS, WalkingFixFilter } from '../core/location';

/** 兜底轮询间隔：1.5 秒（原来 5 秒，用户感觉「导航半天不动」） */
const POLL_INTERVAL_MS: number = 1500;
/** 4 秒内有过真实交付就跳过这次轮询 */
const POLL_SKIP_MS: number = 4000;
/** 界面最多允许冻结这么久（毫秒），超时强制推一次当前点 */
const STALE_UI_MS: number = 2500;

const LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

/**
 * 定位授权结果。
 *
 * `approximate` 为 true 就**算拿到了定位权限**：鸿蒙的授权弹窗分「精确 / 大致」两档，
 * 用户选「大致位置」时精确定位是「拒绝」状态 —— 以前这里要求两个都授予，
 * 于是选了大致的用户被当成「拒绝了定位」，抽盒、导航、拍照验证全线报「拿不到位置」。
 * 大致位置的误差通常是百米级到公里级，做 300–1600 米的盲盒偏粗，
 * 但「明确告诉用户精度不够」远比「说你拒绝了权限」正确。
 */
export interface LocationAccess {
  /** 大致位置是否可用（有它就够启动流程） */
  approximate: boolean;
  /** 精确位置是否可用（导航 / 拍照验证需要它才够准） */
  precise: boolean;
}

/** 申请定位权限并返回两档各自的授权结果 */
export async function requestLocationAccess(context: common.UIAbilityContext): Promise<LocationAccess> {
  const access: LocationAccess = { approximate: false, precise: false };
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, LOCATION_PERMISSIONS);
    if (result === undefined || result.authResults === undefined || result.authResults.length === 0) {
      return access;
    }
    // authResults 与请求数组顺序对应：
    //   [0] APPROXIMATELY_LOCATION，[1] LOCATION
    // 但系统不保证一定按这个顺序返回，所以按 permissions 字段反查更稳。
    const names: string[] = result.permissions === undefined ? [] : result.permissions;
    for (let i = 0; i < result.authResults.length; i++) {
      if (result.authResults[i] !== 0) {
        continue;
      }
      const name: string = i < names.length ? names[i] : LOCATION_PERMISSIONS[i];
      if (name === 'ohos.permission.LOCATION') {
        access.precise = true;
      } else {
        access.approximate = true;
      }
    }
  } catch (err) {
    const error = err as BusinessError;
    return access;
  }
  return access;
}

/**
 * 申请定位权限；拿到任意一档都返回 true。
 *
 * ⚠️ 不要在这里要求「精确」：用户选了「大致位置」也是合法的授权，
 * 由调用方按 `requestLocationAccess()` 的 precise 决定要不要更严的校验。
 */
export async function requestLocationPermission(context: common.UIAbilityContext): Promise<boolean> {
  const access: LocationAccess = await requestLocationAccess(context);
  return access.approximate || access.precise;
}

/**
 * 定位结果的完整信息（UI 需要知道「这个点有多准 / 是不是缓存的」）。
 */
export interface LocationFix {
  point: GeoPoint;
  /** 精度半径（米）；0 = 系统没给 */
  accuracyMeters: number;
  /** true = 来自系统缓存（getLastLocation），不是刚算出来的 */
  cached: boolean;
}

/** 一次单点定位的原始请求（不做任何兜底）；失败时抛出，由调用方决定怎么退 */
function requestCurrentLocation(timeoutMs: number, precise: boolean): Promise<geoLocationManager.Location> {
  return new Promise<geoLocationManager.Location>(
    (resolve: (value: geoLocationManager.Location) => void, reject: (reason: Error) => void) => {
      try {
        const request: geoLocationManager.CurrentLocationRequest = {
          priority: precise
            ? geoLocationManager.LocationRequestPriority.ACCURACY
            : geoLocationManager.LocationRequestPriority.FIRST_FIX,
          scenario: geoLocationManager.LocationRequestScenario.UNSET,
          // 不要设 50 —— maxAccuracy 不是「过滤」，而是告诉系统
          // 「精度达不到就别返回」，室内/大致位置授权下会直接 3301200 失败。
          // 精度判断交给调用方（WalkingFixFilter 仍然拦 50m 以上的点做导航）。
          maxAccuracy: precise ? 100 : 200,
          timeoutMs: timeoutMs
        };
        geoLocationManager.getCurrentLocation(request)
          .then((location: geoLocationManager.Location) => {
            resolve(location);
          })
          .catch((err: BusinessError) => {
            const error = err as BusinessError;
            reject(new Error(error === undefined || error.code === undefined
              ? 'location_failed'
              : 'location_failed_' + String(error.code)));
          });
      } catch (err) {
        reject(new Error('location_exception'));
      }
    });
}

/** 读系统缓存的上一个定位点（同步、不等待）；没有就返回 undefined */
function readCachedLocation(): geoLocationManager.Location | undefined {
  try {
    const last: geoLocationManager.Location = geoLocationManager.getLastLocation();
    if (last === undefined || last === null) {
      return undefined;
    }
    if (!isFinite(last.latitude) || !isFinite(last.longitude)) {
      return undefined;
    }
    return last;
  } catch (err) {
    const error = err as BusinessError;
    return undefined;
  }
}

/**
 * 三级取点（**不通就往下一级，绝不虚构坐标**）：
 *   1. 快速首次定位（FIRST_FIX，通常 1–2 秒）
 *   2. 精度优先再试一次（室内 / 高楼间 FIRST_FIX 经常超时）
 *   3. 系统缓存的最后一个点（可能是几分钟前的，但对「120 米够不够近」仍可用）
 *
 * 为什么要有第 3 级：鸿蒙 CameraPicker 按隐私规格**永远不给照片写 GPS**，
 * App 内拍照这条路径的到达验证完全依赖这个点。以前只做第 1 级、4 秒超时，
 * 于是「相机路径永远提示没有位置信息」—— 其实是取点失败，不是照片没 GPS。
 */
export async function getLocationFix(timeoutMs: number): Promise<LocationFix> {
  if (!geoLocationManager.isLocationEnabled()) {
    throw new Error('location_disabled');
  }

  try {
    const fresh: geoLocationManager.Location = await requestCurrentLocation(timeoutMs, false);
    const fix: LocationFix = {
      point: { latitude: fresh.latitude, longitude: fresh.longitude },
      accuracyMeters: isFinite(fresh.accuracy) ? fresh.accuracy : 0,
      cached: false
    };
    return fix;
  } catch (err) {
    // 落到第二级
  }

  try {
    const precise: geoLocationManager.Location =
      await requestCurrentLocation(Math.max(timeoutMs, 6000), true);
    const fix: LocationFix = {
      point: { latitude: precise.latitude, longitude: precise.longitude },
      accuracyMeters: isFinite(precise.accuracy) ? precise.accuracy : 0,
      cached: false
    };
    return fix;
  } catch (err) {
    // 落到第三级
  }

  const cached: geoLocationManager.Location | undefined = readCachedLocation();
  if (cached !== undefined) {
    const fix: LocationFix = {
      point: { latitude: cached.latitude, longitude: cached.longitude },
      accuracyMeters: isFinite(cached.accuracy) ? cached.accuracy : 0,
      cached: true
    };
    return fix;
  }
  throw new Error('location_unavailable');
}

/** 单次定位（带超时）；失败时 reject，由调用方明确提示定位不可用。 */
export function getCurrentLocationOnce(timeoutMs: number): Promise<GeoPoint> {
  return getLocationFix(timeoutMs)
    .then((fix: LocationFix): GeoPoint => fix.point);
}

/**
 * 持续监听位置变化（旅程页用）。
 * 返回的句柄在组件 aboutToDisappear 里必须 stop()。
 */
/**
 * 罗盘：@ohos.sensor 的 ORIENTATION。
 * alpha 语义与 Android 方位角一致：0 = 正北，**顺时针递增**（东 = 90）。
 * 所以朝向（顺时针从北算）= alpha 本身，不要再做 360-alpha ——
 * 之前写成 360-alpha 会让「人向左转、地图向右转」，方向完全相反。
 * 地图「朝上」= 设备朝向，这样用户转身时地图跟着转。
 * ⚠️ 待 DevEco 验证：sensor.on(sensor.SensorId.ORIENTATION) 的 API 12 写法。
 */
export class CompassWatcher {
  private active: boolean = false;
  private heading: number = -1;
  /** 上次回报给 UI 的角度（用于死区判断，避免每 100ms 都抖动一次） */
  private emitted: number = -1;
  private listener: (data: sensor.OrientationResponse) => void;
  private onHeading: (heading: number) => void;

  constructor(onHeading: (heading: number) => void) {
    this.onHeading = onHeading;
    this.listener = (data: sensor.OrientationResponse) => {
      const alpha: number = data.alpha;
      if (typeof alpha !== 'number' || isNaN(alpha)) {
        return;
      }
      const raw: number = ((alpha % 360) + 360) % 360;
      if (this.heading < 0) {
        this.heading = raw;
        this.emitted = raw;
        this.onHeading(raw);
        return;
      }
      // 角度差归一化到 (-180, 180]
      const delta: number = ((raw - this.heading + 540) % 360) - 180;
      // 自适应平滑：
      //   小抖动（<2°）几乎不动 —— 手机放兜里/手微抖时地图不该一直晃；
      //   大转向（>60°）快速跟上 —— 用户真的转身时不能拖半秒。
      const magnitude: number = Math.abs(delta);
      let factor: number = 0.12;
      if (magnitude > 60) {
        factor = 0.65;
      } else if (magnitude > 20) {
        factor = 0.38;
      } else if (magnitude > 6) {
        factor = 0.22;
      }
      this.heading = (this.heading + delta * factor + 360) % 360;
      // 死区：与上次回报差 < 2° 就不打扰 UI（否则每帧都重算整张地图）
      const sinceEmit: number = Math.abs(((this.heading - this.emitted + 540) % 360) - 180);
      if (sinceEmit < 2) {
        return;
      }
      this.emitted = this.heading;
      this.onHeading(this.heading);
    };
  }

  start(): boolean {
    if (this.active) {
      return true;
    }
    try {
      sensor.on(sensor.SensorId.ORIENTATION, this.listener, { interval: 100000000 });
      this.active = true;
      return true;
    } catch (err) {
      this.active = false;
      return false;
    }
  }

  stop(): void {
    if (!this.active) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.ORIENTATION, this.listener);
    } catch (err) {
      /* ignore */
    }
    this.active = false;
  }
}

export class GeoWatcher {
  private active: boolean = false;
  private listener: (location: geoLocationManager.Location) => void;
  private request: geoLocationManager.LocationRequest;

  private onLocation: (point: GeoPoint, accuracyMeters: number) => void;
  private fixFilter: WalkingFixFilter = new WalkingFixFilter();

  /** 最近一次「收到定位」的时间戳（ms）；用于判断订阅是否还活着 */
  private lastFixAt: number = 0;
  /** 最近一次「真正推给 UI」的时间戳（ms）；用于保证界面不会长时间冻结 */
  private lastDeliveredAt: number = 0;
  /** 由最近两次定位点推算出的移动方向（度，0=北）；负值表示无法判断 */
  private moveHeading: number = -1;
  /** 上一次用于算方向的定位点 */
  private prevPoint: GeoPoint | undefined = undefined;
  /** 兜底轮询定时器句柄，-1 表示未启动 */
  private pollTimer: number = -1;

  constructor(onLocation: (point: GeoPoint, accuracyMeters: number) => void) {
    this.onLocation = onLocation;
    this.request = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: 2,
      distanceInterval: 3
    };
    this.listener = (location: geoLocationManager.Location) => {
      this.deliverFix(location);
    };
  }

  start(): boolean {
    if (this.active) {
      return true;
    }
    try {
      geoLocationManager.on('locationChange', this.request, this.listener);
      this.active = true;
      this.startPollFallback();
      return true;
    } catch (err) {
      const error = err as BusinessError;
      this.active = false;
      return false;
    }
  }

  stop(): void {
    if (!this.active) {
      return;
    }
    try {
      geoLocationManager.off('locationChange', this.listener);
    } catch (err) {
      const error = err as BusinessError;
    }
    this.active = false;
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 当前移动方向（度）；负值表示暂时无法判断 */
  heading(): number {
    return this.moveHeading;
  }

  private deliverFix(location: geoLocationManager.Location): void {
    const accuracy: number = location.accuracy;
    if (!isFinite(accuracy) || accuracy > MAX_WALKING_FIX_ACCURACY_METERS) {
      return;
    }
    const now: number = Date.now();
    const point: GeoPoint = {
      latitude: location.latitude,
      longitude: location.longitude
    };
    const filtered: GeoPoint | undefined = this.fixFilter.accept(point, accuracy, now);
    if (filtered !== undefined) {
      this.markDelivered(filtered, accuracy, now);
      return;
    }
    // 过滤器把它丢了（位移 < 3m 的抖动）——但界面不能因此长时间不更新：
    // 超过 STALE_UI_MS 没有真正刷新，就把当前点直接推给 UI（不再等过滤器攒够位移）。
    if (now - this.lastDeliveredAt >= STALE_UI_MS) {
      this.markDelivered(point, accuracy, now);
    }
  }

  /** 真正交付一次定位：刷新时间戳 + 通知 UI */
  private markDelivered(point: GeoPoint, accuracyMeters: number, at: number): void {
    this.lastFixAt = at;
    this.lastDeliveredAt = at;
    this.updateMoveHeading(point);
    this.onLocation(point, accuracyMeters);
  }

  /** 用相邻两次定位点推算移动方向，写入 moveHeading */
  private updateMoveHeading(point: GeoPoint): void {
    if (this.prevPoint === undefined) {
      this.prevPoint = point;
      return;
    }
    const meters: number = distance(this.prevPoint, point);
    if (meters >= 8) {
      this.moveHeading = bearing(this.prevPoint, point);
      this.prevPoint = point;
    }
  }

  /** 兜底轮询：订阅式定位迟迟不来时，用单次定位补点 */
  private startPollFallback(): void {
    if (this.pollTimer !== -1) {
      return;
    }
    this.pollTimer = setInterval(() => {
      if (!this.active) {
        return;
      }
      // 已经有新鲜交付就不再打扰（4 秒内刷新过就跳过；原来是 8 秒，太慢）
      if (this.lastDeliveredAt > 0 && Date.now() - this.lastDeliveredAt < POLL_SKIP_MS) {
        return;
      }
      try {
        geoLocationManager.getCurrentLocation({
          priority: geoLocationManager.LocationRequestPriority.ACCURACY,
          scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
          maxAccuracy: MAX_WALKING_FIX_ACCURACY_METERS
        }, (err: BusinessError, location: geoLocationManager.Location) => {
          if (err) {
            return;
          }
          if (location === undefined || location === null) {
            return;
          }
          this.deliverFix(location);
        });
      } catch (err) {
        const error = err as BusinessError;
      }
    }, POLL_INTERVAL_MS);
  }
}
