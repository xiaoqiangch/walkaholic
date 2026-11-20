/**
 * 步迷 Walkaholic · HarmonyOS 逻辑层 — 照片 GPS 读取（EXIF 解析）
 *
 * 唯一规格：docs/territory.md §四「探索验证：拍照 + EXIF GPS」；
 * Web 参考实现：prototype/web/exif.js（逻辑逐行照抄，文案逐字一致）。
 *
 * ============ 为什么不用手机 GPS ============
 * `geoLocationManager` / 浏览器 geolocation / CLLocationManager 都能被伪造
 * （开发者工具、模拟定位、越狱插件），而且用户坐在家里也能"到达"。
 * 改成：**到了附近，拍一张照片，照片本身带 GPS**，用照片 EXIF 里的坐标验证。
 * EXIF 是相机在拍照瞬间写进去的，比 App 自己拿的定位更难伪造。
 *
 * ============ 为什么自己解析，不用 getImageProperty ============
 * 鸿蒙的 `image.ImageSource.getImageProperty('GPSLatitude')` 在部分机型上：
 *   - 只返回字符串（形如 "31,13,49.44"），度分秒格式不统一，还要自己拼方向
 *   - 有的机型直接返回空 / 抛异常
 *   - 返回的数值精度与字节序处理取决于 ROM
 * 所以这里直接拿图片字节自己解析 JPEG APP1 段 —— 与 Web 端**完全同一套代码**，
 * 行为可预测、可单测、不受机型影响。
 *
 * ============ 必须处理的现实问题 ============
 * 1. 很多手机默认**关闭**相机的"位置信息"开关 → 照片里没有 GPS
 * 2. 社交软件转发/压缩过的照片会**剥掉** EXIF
 * 3. 截图没有 EXIF
 * 4. 部分设备（含某些 Android/鸿蒙机型）的 EXIF 是 BigEndian（`MM`），必须两种都支持
 * 5. PNG 本身不存 EXIF
 *
 * 拿不到 GPS 时必须**明确告诉用户去开哪个开关**，而不是静默判失败。
 *
 * 纯函数、零 `@ohos.*` 依赖（base64 字符串由 UI 层用 `util.Base64Helper` 解好后传进来），
 * 因此可在 Node 里直接测。
 */

import { GeoPoint } from './types';

// ============================================================
// 失败原因（docs §四「失败原因 → 用户提示」表）
// ============================================================

export type PhotoGpsFailure =
  | 'noExif'
  | 'noGpsTag'
  | 'incompleteGps'
  | 'invalidGps'
  | 'notImage'
  | 'brokenExif'
  | 'pngNoExif'
  | 'tooFar'
  | 'noData'
  /** Web 端还有一个 UNREADABLE_GPS：坐标能定位到标签但值读不出来 */
  | 'unreadableGps';

export interface PhotoGpsResult {
  ok: boolean;
  lat?: number;
  lon?: number;
  reason?: PhotoGpsFailure;
  /** 给开发者看的细节（不直接展示给用户） */
  detail?: string;
  /** 可选：GPSTimeStamp / GPSDateStamp 拼接出的拍摄时间 */
  dateStamp?: string;
}

/** 拍照验证的判定半径（米）：目的地多大范围内拍照算"来过" */
export const PHOTO_RADIUS_METERS: number = 120;

// ============================================================
// 1. 二进制读取工具（对应 Web 的 DataViewReader）
// ============================================================

class BytesReader {
  private bytes: Uint8Array;
  readonly len: number;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.len = bytes.length;
  }

  /** 无符号 8 位；越界抛错（与 Web 的 'EXIF 越界' 同语义） */
  u8(off: number): number {
    if (off < 0 || off + 1 > this.len) throw new Error('EXIF 越界');
    return this.bytes[off];
  }

  /** 无符号 16 位；little=true 小端 */
  u16(off: number, little: boolean): number {
    if (off < 0 || off + 2 > this.len) throw new Error('EXIF 越界');
    const a: number = this.bytes[off];
    const b: number = this.bytes[off + 1];
    return little ? (a | (b << 8)) : ((a << 8) | b);
  }

  /** 无符号 32 位（用乘加避免 `<<24` 溢出成负数） */
  u32(off: number, little: boolean): number {
    if (off < 0 || off + 4 > this.len) throw new Error('EXIF 越界');
    const b0: number = this.bytes[off];
    const b1: number = this.bytes[off + 1];
    const b2: number = this.bytes[off + 2];
    const b3: number = this.bytes[off + 3];
    if (little) {
      return (b0 | (b1 << 8) | (b2 << 16)) + b3 * 16777216;
    }
    return b0 * 16777216 + (b3 | (b2 << 8) | (b1 << 16));
  }

  /** 从 off 起取 len 个字节当 Latin-1 字符串 */
  str(off: number, len: number): string {
    let out: string = '';
    for (let i = 0; i < len && off + i < this.len; i += 1) {
      out += String.fromCharCode(this.u8(off + i));
    }
    return out;
  }
}

// ============================================================
// 2. 找 JPEG 的 APP1（EXIF）段
// ============================================================

interface ExifSegment {
  /** 「Exif\0\0」签名起始位置 */
  start: number;
  /** 段结束位置 */
  end: number;
}

function findExifSegment(reader: BytesReader): ExifSegment | undefined {
  if (reader.len < 4) return undefined;
  // JPEG SOI：FF D8
  if (reader.u8(0) !== 0xFF || reader.u8(1) !== 0xD8) return undefined;

  let off: number = 2;
  while (off + 4 <= reader.len) {
    if (reader.u8(off) !== 0xFF) {
      off += 1;
      continue;
    }
    const marker: number = reader.u8(off + 1);
    // 填充字节
    if (marker === 0xFF) {
      off += 1;
      continue;
    }
    // 无长度的标记
    if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      off += 2;
      continue;
    }
    // SOS：图片数据开始，之后不会再有 EXIF
    if (marker === 0xDA) return undefined;

    const segLen: number = reader.u16(off + 2, false);
    if (segLen < 2) return undefined;

    // APP1 (0xE1) 且内容是 "Exif\0\0"
    if (marker === 0xE1 && off + 10 <= reader.len) {
      const sig: string = reader.str(off + 4, 4);
      if (sig === 'Exif') {
        // start 指向 "Exif" 四个字母的起点；tiffBase 会再 +6 跳过 "Exif\0\0"
        const segment: ExifSegment = { start: off + 4, end: off + 2 + segLen };
        return segment;
      }
    }
    off += 2 + segLen;
  }
  return undefined;
}

// ============================================================
// 3. TIFF / IFD 解析
// ============================================================

/** TIFF 数据类型 → 每元素字节数（与 Web 的 TYPE_SIZES 一致） */
const TYPE_SIZES: Record<string, number> = {
  '1': 1, '2': 1, '3': 2, '4': 4, '5': 8, '7': 1, '9': 4, '10': 8
};

interface IfdEntry {
  type: number;
  count: number;
  /** 值所在偏移（inline 时是条目内偏移，否则是 TIFF 内绝对偏移） */
  valueOff: number;
  inline: boolean;
}

interface IfdResult {
  /** tag → 条目（只收集 wanted 里的 tag） */
  entries: Record<string, IfdEntry>;
}

function readIfd(
  reader: BytesReader,
  tiffBase: number,
  ifdOffset: number,
  little: boolean,
  wantedTags: string[]
): IfdResult {
  const entries: Record<string, IfdEntry> = {};
  const countOff: number = tiffBase + ifdOffset;
  const count: number = reader.u16(countOff, little);
  // 防御性上限：正常照片 IFD 条目远小于 512
  if (count > 512) {
    const empty: IfdResult = { entries: entries };
    return empty;
  }

  for (let i = 0; i < count; i += 1) {
    const e: number = countOff + 2 + i * 12;
    if (e + 12 > reader.len) break;
    const tag: number = reader.u16(e, little);
    const type: number = reader.u16(e + 2, little);
    const num: number = reader.u32(e + 4, little);
    const sizePer: number = TYPE_SIZES[String(type)] === undefined ? 0 : TYPE_SIZES[String(type)];
    const size: number = sizePer * num;

    const tagKey: string = String(tag);
    let wanted: boolean = false;
    for (let w = 0; w < wantedTags.length; w += 1) {
      if (wantedTags[w] === tagKey) {
        wanted = true;
        break;
      }
    }
    if (!wanted) continue;

    if (size <= 4) {
      const inlineEntry: IfdEntry = {
        type: type,
        count: num,
        valueOff: e + 8,
        inline: true
      };
      entries[tagKey] = inlineEntry;
    } else {
      const vo: number = reader.u32(e + 8, little);
      const offEntry: IfdEntry = {
        type: type,
        count: num,
        valueOff: tiffBase + vo,
        inline: false
      };
      entries[tagKey] = offEntry;
    }
  }

  const result: IfdResult = { entries: entries };
  return result;
}

/** 读 rational（type 5）：两个 u32 组成分数 */
function readRational(reader: BytesReader, baseOff: number, index: number, little: boolean): number {
  const off: number = baseOff + index * 8;
  const num: number = reader.u32(off, little);
  const den: number = reader.u32(off + 4, little);
  if (den === 0) return 0;
  return num / den;
}

/** 把 GPS 的「度分秒」转成十进制度；读不出返回 undefined */
function dmsToDecimal(dmsEntry: IfdEntry | undefined, reader: BytesReader, little: boolean): number | undefined {
  if (dmsEntry === undefined) return undefined;
  const base: number = dmsEntry.valueOff;
  const deg: number = readRational(reader, base, 0, little);
  const min: number = readRational(reader, base, 1, little);
  const sec: number = readRational(reader, base, 2, little);
  if (!isFinite(deg) || deg > 180) return undefined;
  const value: number = deg + min / 60 + sec / 3600;
  if (!isFinite(value)) return undefined;
  return value;
}

/**
 * 读 ASCII 值（如 "N" / "E" / 日期）。
 *
 * 注意：ASCII 是逐字节的，与字节序无关 —— 所以不需要 `little` 参数。
 * （Web 版同样不传，曾误以为要传；这里显式说明免得后人"补上"）
 */
function readAscii(reader: BytesReader, entry: IfdEntry | undefined): string {
  if (entry === undefined) return '';
  let out: string = '';
  if (entry.inline) {
    const limit: number = entry.count < 4 ? entry.count : 4;
    for (let i = 0; i < limit; i += 1) {
      const c: number = reader.u8(entry.valueOff + i);
      if (c === 0) break;
      out += String.fromCharCode(c);
    }
  } else {
    const limit: number = entry.count < 16 ? entry.count : 16;
    out = reader.str(entry.valueOff, limit);
  }
  return out.replace(/\u0000+$/g, '').trim();
}

// ============================================================
// 4. 主入口：从图片字节里读 GPS
// ============================================================

/** GPS IFD 里我们要的 tag（与 Web 的 GPS_TAGS 一致） */
const GPS_TAGS: string[] = ['1', '2', '3', '4', '5', '6', '7', '29'];

/** IFD0 里我们只要 GPSInfoIFDPointer（0x8825） */
const IFD0_TAGS: string[] = ['34853'];

const TAG_GPS_LAT_REF: string = '1';
const TAG_GPS_LAT: string = '2';
const TAG_GPS_LON_REF: string = '3';
const TAG_GPS_LON: string = '4';
const TAG_GPS_DATE: string = '29';

/**
 * 从图片字节解析 GPS 坐标（核心实现，纯函数）。
 *
 * @param bytes 原始图片字节（JPEG / PNG / 其他）
 */
export function parseExifGps(bytes: Uint8Array): PhotoGpsResult {
  if (bytes === undefined || bytes.length < 20) {
    return { ok: false, reason: 'notImage', detail: '文件太小，不是有效图片' };
  }

  let reader: BytesReader;
  try {
    reader = new BytesReader(bytes);
  } catch (err) {
    return { ok: false, reason: 'notImage', detail: '无法读取文件' };
  }

  // PNG/HEIC 暂不支持（PNG 本来就不存 EXIF；HEIC 需要额外解析）
  if (reader.u8(0) === 0x89 && reader.u8(1) === 0x50) {
    return {
      ok: false,
      reason: 'pngNoExif',
      detail: 'PNG 格式不保存位置信息，请用相机拍的照片'
    };
  }

  let segment: ExifSegment | undefined = undefined;
  try {
    segment = findExifSegment(reader);
  } catch (err) {
    return { ok: false, reason: 'brokenExif', detail: '照片结构异常' };
  }
  if (segment === undefined) {
    return {
      ok: false,
      reason: 'noExif',
      detail: '这张照片没有位置信息（可能是截图、社交软件转发的图，或相机未开启"位置信息"）'
    };
  }

  // TIFF 头：'II'（小端）或 'MM'（大端）
  const tiffBase: number = segment.start + 6;   // 跳过 "Exif\0\0"
  if (tiffBase + 8 > reader.len) {
    return { ok: false, reason: 'brokenExif', detail: 'EXIF 数据不完整' };
  }

  const byteOrder: string = reader.str(tiffBase, 2);
  let little: boolean = true;
  if (byteOrder === 'II') {
    little = true;
  } else if (byteOrder === 'MM') {
    little = false;
  } else {
    return { ok: false, reason: 'brokenExif', detail: 'EXIF 字节序标识异常' };
  }

  const magic: number = reader.u16(tiffBase + 2, little);
  if (magic !== 42) {
    return { ok: false, reason: 'brokenExif', detail: '不是标准 TIFF 结构' };
  }

  try {
    const ifd0Off: number = reader.u32(tiffBase + 4, little);
    const ifd0: IfdResult = readIfd(reader, tiffBase, ifd0Off, little, IFD0_TAGS);
    const gpsPointer: IfdEntry | undefined = ifd0.entries['34853'];
    if (gpsPointer === undefined) {
      return {
        ok: false,
        reason: 'noGpsTag',
        detail: '照片里有相机信息，但没有位置信息 —— 相机设置里的"位置信息/地点标记"没打开'
      };
    }

    const gpsIfdOff: number = reader.u32(gpsPointer.valueOff, little);
    const gps: IfdResult = readIfd(reader, tiffBase, gpsIfdOff, little, GPS_TAGS);
    if (gps.entries[TAG_GPS_LAT] === undefined || gps.entries[TAG_GPS_LON] === undefined) {
      return {
        ok: false,
        reason: 'incompleteGps',
        detail: '照片写了位置字段但坐标不完整（可能被编辑过）'
      };
    }

    const latRef: string = readAscii(reader, gps.entries[TAG_GPS_LAT_REF]).toUpperCase();
    const lonRef: string = readAscii(reader, gps.entries[TAG_GPS_LON_REF]).toUpperCase();
    let lat: number | undefined = dmsToDecimal(gps.entries[TAG_GPS_LAT], reader, little);
    let lon: number | undefined = dmsToDecimal(gps.entries[TAG_GPS_LON], reader, little);
    if (lat === undefined || lon === undefined) {
      return { ok: false, reason: 'unreadableGps', detail: '位置数据读不出来' };
    }

    // 南纬 / 西经 + 负号
    if (latRef === 'S') lat = -lat;
    if (lonRef === 'W') lon = -lon;

    if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
      return { ok: false, reason: 'invalidGps', detail: '坐标超出有效范围' };
    }

    const result: PhotoGpsResult = { ok: true, lat: lat, lon: lon };
    // 附带拍摄日期（可选，用于判断是否"刚刚拍的"）
    const dateEntry: IfdEntry | undefined = gps.entries[TAG_GPS_DATE];
    if (dateEntry !== undefined) {
      const stamp: string = readAscii(reader, dateEntry);
      if (stamp.length > 0) result.dateStamp = stamp;
    }
    return result;
  } catch (err) {
    let message: string = '未知错误';
    if (err instanceof Error) message = err.message;
    return { ok: false, reason: 'brokenExif', detail: 'EXIF 解析失败：' + message };
  }
}

// ============================================================
// 5. base64 → 字节 → GPS（UI 层用 util.Base64Helper 先把文件读成 base64）
// ============================================================

/** 标准 base64 字符 → 6 位值；非法字符返回 -1 */
function base64Value(code: number): number {
  if (code >= 65 && code <= 90) return code - 65;          // A-Z
  if (code >= 97 && code <= 122) return code - 97 + 26;    // a-z
  if (code >= 48 && code <= 57) return code - 48 + 52;     // 0-9
  if (code === 43) return 62;                              // +
  if (code === 47) return 63;                              // /
  return -1;
}

/**
 * 标准 base64 → Uint8Array。
 *
 * 为什么自己解而不是在 core 里 import `@ohos.util`：
 * core/ 必须保持纯 TS 才能在 Node 里单测。UI 层可以直接把
 * `util.Base64Helper.encodeToStringSync()` 的结果传进来（或传原始字节，用 parseExifGps）。
 * 这里实现一份等价解码，保证两条路进去结果一致。
 */
export function base64ToBytes(base64: string): Uint8Array {
  let text: string = base64;
  // 去掉 data URL 前缀（`data:image/jpeg;base64,`）与换行
  const comma: number = text.indexOf(',');
  if (text.indexOf('data:') === 0 && comma >= 0) {
    text = text.substring(comma + 1);
  }
  text = text.replace(/[\s\r\n]+/g, '');

  const out: number[] = [];
  let buffer: number = 0;
  let bits: number = 0;
  for (let i = 0; i < text.length; i += 1) {
    const ch: number = text.charCodeAt(i);
    if (ch === 61) break;   // '=' 结束
    const value: number = base64Value(ch);
    if (value < 0) continue; // 跳过非法字符（容错）
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xFF);
    }
  }
  return new Uint8Array(out);
}

/**
 * 从 base64 图片解析 GPS（UI 主入口）。
 *
 * @param base64 图片的 base64（可带 `data:image/jpeg;base64,` 前缀）
 */
export function parseExifGpsFromBase64(base64: string): PhotoGpsResult {
  if (base64 === undefined || base64 === null || base64.length < 24) {
    return { ok: false, reason: 'noData', detail: '没有读到图片数据' };
  }
  let bytes: Uint8Array;
  try {
    bytes = base64ToBytes(base64);
  } catch (err) {
    return { ok: false, reason: 'notImage', detail: 'base64 解码失败' };
  }
  if (bytes.length === 0) {
    return { ok: false, reason: 'noData', detail: '图片数据为空' };
  }
  return parseExifGps(bytes);
}

// ============================================================
// 6. 距离校验
// ============================================================

const EARTH_R: number = 6371008.8;

/** 两个坐标的球面距离（米） */
export function haversineMeters(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const toRad: number = Math.PI / 180;
  const dLat: number = (bLat - aLat) * toRad;
  const dLon: number = (bLon - aLon) * toRad;
  const sLat: number = Math.sin(dLat / 2);
  const sLon: number = Math.sin(dLon / 2);
  const h: number = sLat * sLat + Math.cos(aLat * toRad) * Math.cos(bLat * toRad) * sLon * sLon;
  return 2 * EARTH_R * Math.asin(Math.min(1, Math.sqrt(h)));
}

export interface PhotoVerifyResult {
  ok: boolean;
  distanceMeters?: number;
  radiusMeters?: number;
  reason?: PhotoGpsFailure;
  detail?: string;
}

/**
 * 用照片 GPS 验证是否到达目标地点。
 *
 * - 距离 ≤ 半径（默认 120m）→ 通过
 * - 距离 > 半径 → tooFar（附实测距离，供 UI 显示「离目的地 N 米」）
 * - 缺数据 → noData
 */
export function verifyPhotoAt(
  target: GeoPoint,
  photo: { lat: number; lon: number },
  radiusMeters?: number
): PhotoVerifyResult {
  const radius: number = radiusMeters !== undefined && radiusMeters > 0
    ? radiusMeters
    : PHOTO_RADIUS_METERS;

  if (target === undefined || target === null || photo === undefined || photo === null) {
    return { ok: false, reason: 'noData', radiusMeters: radius };
  }
  if (!isFinite(target.latitude) || !isFinite(target.longitude) ||
    !isFinite(photo.lat) || !isFinite(photo.lon)) {
    return { ok: false, reason: 'noData', radiusMeters: radius };
  }

  const d: number = haversineMeters(target.latitude, target.longitude, photo.lat, photo.lon);
  if (d <= radius) {
    const pass: PhotoVerifyResult = {
      ok: true,
      distanceMeters: d,
      radiusMeters: radius
    };
    return pass;
  }
  const fail: PhotoVerifyResult = {
    ok: false,
    reason: 'tooFar',
    distanceMeters: d,
    radiusMeters: radius,
    detail: '照片拍摄点离目的地 ' + String(Math.round(d)) + ' 米，超出 ' + String(radius) + ' 米范围'
  };
  return fail;
}

// ============================================================
// 7. 失败文案（docs §四 表格，逐字一致）
// ============================================================

/**
 * 失败原因 → 一句话提示（UI 标题用）。
 *
 * 文案取自 docs/territory.md §四 的「提示」列 + prototype/web/exif.js 的 `REASON_TEXT`。
 */
export function photoFailText(reason: PhotoGpsFailure): string {
  if (reason === 'noExif') return '这张照片没有位置信息';
  if (reason === 'noGpsTag') return '相机没有开启「位置信息」';
  if (reason === 'incompleteGps') return '照片的位置数据不完整';
  if (reason === 'unreadableGps') return '照片的位置数据读不出来';
  if (reason === 'invalidGps') return '照片坐标不合法';
  if (reason === 'pngNoExif') return 'PNG 照片不保存位置信息';
  if (reason === 'brokenExif') return '照片信息损坏';
  if (reason === 'notImage') return '这不是有效的照片文件';
  if (reason === 'tooFar') return '拍摄地点离目的地太远';
  return '缺少坐标数据';   // noData
}

/**
 * 失败原因 → 具体怎么操作（UI 正文用）。
 *
 * **关键**：`noGpsTag`（相机没开位置信息）和 `noExif`（截图/转发图）是最常见的两种情况，
 * 必须给出**具体的操作路径**（去哪个设置页面开什么开关），不能只说"失败"。
 */
export function photoFailHowto(reason: PhotoGpsFailure): string {
  if (reason === 'noExif') {
    return '请用手机自带相机 App 拍一张新照片（不要用截图，也不要转发聊天软件里的图）';
  }
  if (reason === 'noGpsTag') {
    return '请到 设置 → 应用 → 相机 → 打开「记录位置信息」，然后重新拍一张';
  }
  if (reason === 'incompleteGps') return '这张图的位置信息被改过或不完整，请重新用相机拍一张';
  if (reason === 'unreadableGps') return '请重新用相机拍一张';
  if (reason === 'invalidGps') return '请重新用相机拍一张';
  if (reason === 'pngNoExif') return '请用相机拍 JPEG 照片，不要用截图或 PNG';
  if (reason === 'brokenExif') return '请重新用相机拍一张';
  if (reason === 'notImage') return '请选择一张照片';
  if (reason === 'tooFar') return '走近一点再拍一张';
  return '请重新拍一张';   // noData
}

/** 失败原因 → 是否值得直接引导用户去改设置（UI 可以高亮这类） */
export function photoFailNeedsSettings(reason: PhotoGpsFailure): boolean {
  return reason === 'noGpsTag' || reason === 'noExif';
}

/** 组合成 UI 可直接渲染的一段文案（标题 + 操作指引） */
export function photoFailFullText(reason: PhotoGpsFailure): string {
  return photoFailText(reason) + '。' + photoFailHowto(reason);
}

/** tooFar 场景的完整文案（带实测距离，docs B3 要求） */
export function tooFarCopy(distanceMeters: number, radiusMeters?: number): string {
  const radius: number = radiusMeters !== undefined && radiusMeters > 0
    ? radiusMeters
    : PHOTO_RADIUS_METERS;
  return '照片拍摄点离目的地 ' + String(Math.round(distanceMeters)) +
    ' 米，需要在 ' + String(Math.round(radius)) + ' 米内拍摄。走近一点再拍一张。';
}

// ============================================================
// 8. 统一入口：base64 照片 → 验证结果（UI 一行调用）
// ============================================================

export interface PhotoArrivalCheck {
  /** 是否通过（演示地点无坐标时也返回 true，但 demoSkip=true） */
  ok: boolean;
  /** 演示地点 / 目的地无坐标 → 跳过验证 */
  demoSkip: boolean;
  /** 照片里的坐标 */
  photoGps?: { lat: number; lon: number };
  /** 与目的地的实测距离（米） */
  distanceMeters?: number;
  /** 失败原因 */
  reason?: PhotoGpsFailure;
  /** UI 标题文案 */
  title: string;
  /** UI 正文文案 */
  howto: string;
}

/**
 * 到达验证：照片 base64 + 目的地坐标 → 结论 + 文案。
 *
 * @param target 目的地真实坐标；undefined = 演示地点（无坐标）→ 跳过验证
 * @param base64 照片 base64
 * @param radiusMeters 允许半径，默认 120m
 */
export function checkPhotoArrival(
  target: GeoPoint | undefined,
  base64: string,
  radiusMeters?: number
): PhotoArrivalCheck {
  // 演示地点无坐标：按规格跳过验证（绝不因为「没有坐标」而判用户失败）
  if (target === undefined || !isFinite(target.latitude) || !isFinite(target.longitude)) {
    const skipped: PhotoArrivalCheck = {
      ok: true,
      demoSkip: true,
      title: '演示地点 · 跳过位置验证',
      howto: '这个地点没有真实坐标，照片只作为纪念。'
    };
    return skipped;
  }

  const parsed: PhotoGpsResult = parseExifGpsFromBase64(base64);
  if (!parsed.ok || parsed.lat === undefined || parsed.lon === undefined) {
    const reason: PhotoGpsFailure = parsed.reason === undefined ? 'noData' : parsed.reason;
    const failed: PhotoArrivalCheck = {
      ok: false,
      demoSkip: false,
      reason: reason,
      title: photoFailText(reason),
      howto: photoFailHowto(reason)
    };
    return failed;
  }

  const photoGps: { lat: number; lon: number } = { lat: parsed.lat, lon: parsed.lon };
  const verified: PhotoVerifyResult = verifyPhotoAt(target, photoGps, radiusMeters);
  if (verified.ok) {
    const passed: PhotoArrivalCheck = {
      ok: true,
      demoSkip: false,
      photoGps: photoGps,
      distanceMeters: verified.distanceMeters,
      title: '位置验证通过',
      howto: '照片拍摄点距目的地 ' + String(Math.round(verified.distanceMeters === undefined ? 0 : verified.distanceMeters)) + ' 米'
    };
    return passed;
  }

  const distance: number = verified.distanceMeters === undefined ? 0 : verified.distanceMeters;
  const tooFar: PhotoArrivalCheck = {
    ok: false,
    demoSkip: false,
    photoGps: photoGps,
    distanceMeters: distance,
    reason: 'tooFar',
    title: photoFailText('tooFar'),
    howto: tooFarCopy(distance, radiusMeters)
  };
  return tooFar;
}