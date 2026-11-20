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

/** 申请定位权限；已授权时也返回 true（系统不会重复弹窗）。 */
export async function requestLocationPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, LOCATION_PERMISSIONS);
    if (result === undefined || result.authResults === undefined || result.authResults.length === 0) {
      return false;
    }
    let granted: boolean = true;
    for (let i = 0; i < result.authResults.length; i++) {
      if (result.authResults[i] !== 0) {
        granted = false;
      }
    }
    return granted;
  } catch (err) {
    const error = err as BusinessError;
    return false;
  }
}

/** 单次定位（带超时）；失败时 reject，由调用方明确提示定位不可用。 */
export function getCurrentLocationOnce(timeoutMs: number): Promise<GeoPoint> {
  return new Promise<GeoPoint>((resolve: (value: GeoPoint) => void, reject: (reason: Error) => void) => {
    try {
      if (!geoLocationManager.isLocationEnabled()) {
        reject(new Error('location_disabled'));
        return;
      }
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        maxAccuracy: 100,
        timeoutMs: timeoutMs
      };
      geoLocationManager.getCurrentLocation(request)
        .then((location: geoLocationManager.Location) => {
          const point: GeoPoint = {
            latitude: location.latitude,
            longitude: location.longitude
          };
          resolve(point);
        })
        .catch((err: BusinessError) => {
          reject(new Error('location_failed'));
        });
    } catch (err) {
      reject(new Error('location_exception'));
    }
  });
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
