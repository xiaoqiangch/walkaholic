/**
 * 安全的附近点位展示投影。
 *
 * POI 保留地点及其真实数据源；用户惊喜只保留 NearHint，不复制坐标、线索或照片。
 */

import { NearHint } from './hints';
import { distance } from './geo';
import { GeoPoint, Place, PlaceType } from './types';

export interface NearbyPlaceProjection {
  id: string;
  type: PlaceType;
  /** POI 数据源或 userUpload；不与点位类型混用。 */
  source: string;
  distanceMeters?: number;
  place?: Place;
  hint?: NearHint;
}

/** 把地图 POI 与安全惊喜提示合并为一个按距离排序的列表。 */
export function projectNearbyPlaces(
  places: Place[],
  hints: NearHint[],
  origin?: GeoPoint
): NearbyPlaceProjection[] {
  const result: NearbyPlaceProjection[] = [];

  for (let i = 0; i < places.length; i += 1) {
    const place: Place = places[i];
    const item: NearbyPlaceProjection = {
      id: place.id,
      type: 'poi',
      source: place.source,
      place: place
    };
    if (origin !== undefined && place.coordinate !== undefined) {
      item.distanceMeters = distance(origin, place.coordinate);
    }
    result.push(item);
  }

  for (let i = 0; i < hints.length; i += 1) {
    const hint: NearHint = hints[i];
    const item: NearbyPlaceProjection = {
      id: hint.id,
      type: 'userSurprise',
      source: 'userUpload',
      hint: hint
    };
    if (hint.distanceMeters !== undefined) {
      item.distanceMeters = hint.distanceMeters;
    }
    result.push(item);
  }

  result.sort((first: NearbyPlaceProjection, second: NearbyPlaceProjection): number => {
    if (first.distanceMeters === undefined && second.distanceMeters === undefined) return 0;
    if (first.distanceMeters === undefined) return 1;
    if (second.distanceMeters === undefined) return -1;
    return first.distanceMeters - second.distanceMeters;
  });
  return result;
}
