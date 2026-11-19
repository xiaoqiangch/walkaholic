/**
 * 步迷 Walkaholic · HarmonyOS 逻辑层 — 步行定位质量过滤
 *
 * Rejects inaccurate and physically implausible fixes before they affect
 * navigation, arrival detection, or the locally stored walking trace.
 */

import { GeoPoint } from './types';
import { distance } from './geo';

export const MAX_WALKING_FIX_ACCURACY_METERS: number = 50;
const MAX_WALKING_SPEED_METERS_PER_SECOND: number = 8;
const MAX_CONTINUOUS_GAP_MS: number = 120000;
const MIN_MOVEMENT_METERS: number = 3;

export class WalkingFixFilter {
  private lastPoint: GeoPoint | undefined = undefined;
  private lastAt: number = 0;
  private jumpCandidate: GeoPoint | undefined = undefined;
  private jumpCandidateCount: number = 0;

  accept(point: GeoPoint, accuracyMeters: number, at: number): GeoPoint | undefined {
    if (!isFinite(point.latitude) || !isFinite(point.longitude) ||
      point.latitude < -90 || point.latitude > 90 ||
      point.longitude < -180 || point.longitude > 180 ||
      !isFinite(accuracyMeters) || accuracyMeters < 0 ||
      accuracyMeters > MAX_WALKING_FIX_ACCURACY_METERS ||
      !isFinite(at) || at < this.lastAt) {
      return undefined;
    }

    if (this.lastPoint === undefined || at - this.lastAt > MAX_CONTINUOUS_GAP_MS) {
      return this.commit(point, at);
    }

    const elapsedSeconds: number = Math.max(0.5, (at - this.lastAt) / 1000);
    const displacement: number = distance(this.lastPoint, point);
    const plausibleDistance: number = Math.max(
      20,
      elapsedSeconds * MAX_WALKING_SPEED_METERS_PER_SECOND + Math.min(accuracyMeters, 20)
    );

    if (displacement > plausibleDistance) {
      if (this.jumpCandidate !== undefined &&
        distance(this.jumpCandidate, point) <= Math.max(20, accuracyMeters)) {
        this.jumpCandidateCount += 1;
      } else {
        this.jumpCandidate = point;
        this.jumpCandidateCount = 1;
      }
      if (this.jumpCandidateCount < 2) {
        this.lastAt = at;
        return undefined;
      }
      this.clearJumpCandidate();
      return this.commit(point, at);
    }

    this.clearJumpCandidate();
    if (displacement < MIN_MOVEMENT_METERS) {
      this.lastAt = at;
      return undefined;
    }

    const alpha: number = Math.max(0.45, Math.min(0.8, 30 / (accuracyMeters + 10)));
    const smoothed: GeoPoint = {
      latitude: this.lastPoint.latitude + (point.latitude - this.lastPoint.latitude) * alpha,
      longitude: this.lastPoint.longitude + (point.longitude - this.lastPoint.longitude) * alpha
    };
    return this.commit(smoothed, at);
  }

  private commit(point: GeoPoint, at: number): GeoPoint {
    this.lastPoint = { latitude: point.latitude, longitude: point.longitude };
    this.lastAt = at;
    this.clearJumpCandidate();
    return { latitude: point.latitude, longitude: point.longitude };
  }

  private clearJumpCandidate(): void {
    this.jumpCandidate = undefined;
    this.jumpCandidateCount = 0;
  }
}
