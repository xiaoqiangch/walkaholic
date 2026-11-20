/* 步谜 · 照片 GPS 读取（EXIF 解析）
 *
 * ============ 为什么需要这个 ============
 * 「探索过一个地点」不能只看手机 GPS —— 那可以伪造、也可以坐在家里用开发者工具改。
 * 改成：**到了附近，拍一张照片，照片本身带 GPS**，系统读照片里的坐标来验证。
 * 照片 EXIF 是相机/系统在拍照瞬间写进去的，比浏览器的 geolocation 更难伪造。
 *
 * ============ 必须处理的现实问题 ============
 * 1. 很多手机默认**关闭**相机的"位置信息"开关 → 照片里没有 GPS
 * 2. 社交软件转发/压缩过的照片会**剥掉** EXIF
 * 3. 截图没有 EXIF
 * 4. iOS Safari 的 allow-files 可能让图片在 canvas 处理后丢失 EXIF（我们要在压缩前读）
 * 5. 部分设备的 EXIF 用 BigEndian（Motorola 序），必须两种都支持
 *
 * 拿不到 GPS 时必须**明确告诉用户去开**，而不是静默判失败。
 */
(function (root) {
  'use strict';

  /* ============================================================
     1. 二进制读取工具
     ============================================================ */
  function DataViewReader(buffer) {
    this.view = new DataView(buffer);
    this.len = buffer.byteLength;
  }
  DataViewReader.prototype.u8 = function (off) {
    if (off + 1 > this.len) throw new Error('EXIF 越界');
    return this.view.getUint8(off);
  };
  DataViewReader.prototype.u16 = function (off, little) {
    if (off + 2 > this.len) throw new Error('EXIF 越界');
    return this.view.getUint16(off, little);
  };
  DataViewReader.prototype.u32 = function (off, little) {
    if (off + 4 > this.len) throw new Error('EXIF 越界');
    return this.view.getUint32(off, little);
  };
  DataViewReader.prototype.u16s = function (off, little) {
    if (off + 2 > this.len) throw new Error('EXIF 越界');
    return this.view.getInt16(off, little);
  };
  DataViewReader.prototype.u32s = function (off, little) {
    if (off + 4 > this.len) throw new Error('EXIF 越界');
    return this.view.getInt32(off, little);
  };
  DataViewReader.prototype.str = function (off, len) {
    var out = '';
    for (var i = 0; i < len && off + i < this.len; i += 1) out += String.fromCharCode(this.u8(off + i));
    return out;
  };

  /* ============================================================
     2. 找到 JPEG 的 APP1（EXIF）段
     ============================================================ */
  function findExifSegment(reader) {
    if (reader.len < 4) return null;
    // JPEG SOI
    if (reader.u8(0) !== 0xFF || reader.u8(1) !== 0xD8) return null;
    var off = 2;
    while (off + 4 <= reader.len) {
      if (reader.u8(off) !== 0xFF) { off += 1; continue; }
      var marker = reader.u8(off + 1);
      // 填充字节
      if (marker === 0xFF) { off += 1; continue; }
      // 无长度的标记
      if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) { off += 2; continue; }
      // SOS：图片数据开始，之后不会再有 EXIF
      if (marker === 0xDA) return null;
      var segLen = reader.u16(off + 2, false);
      if (segLen < 2) return null;
      // APP1 (0xE1) 且内容是 "Exif\0\0"
      if (marker === 0xE1 && off + 10 <= reader.len) {
        var sig = reader.str(off + 4, 4);
        if (sig === 'Exif') return { start: off + 4, end: off + 2 + segLen };
      }
      off += 2 + segLen;
    }
    return null;
  }

  /* ============================================================
     3. TIFF / IFD 解析
     ============================================================ */
  var TYPE_SIZES = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8 };

  function readIfd(reader, tiffBase, ifdOffset, little, wanted) {
    var entries = {};
    var countOff = tiffBase + ifdOffset;
    var count = reader.u16(countOff, little);
    if (count > 512) return entries;   // 防御性上限
    for (var i = 0; i < count; i += 1) {
      var e = countOff + 2 + i * 12;
      if (e + 12 > reader.len) break;
      var tag = reader.u16(e, little);
      var type = reader.u16(e + 2, little);
      var num = reader.u32(e + 4, little);
      var size = (TYPE_SIZES[type] || 0) * num;
      if (!wanted || wanted[tag] === undefined) continue;
      if (size <= 4) {
        entries[tag] = { type: type, count: num, valueOff: e + 8, inline: true };
      } else {
        var vo = reader.u32(e + 8, little);
        entries[tag] = { type: type, count: num, valueOff: tiffBase + vo, inline: false };
      }
    }
    return entries;
  }

  /** 读 rational（type 5）：两个 u32 组成分数 */
  function readRational(reader, baseOff, index, little) {
    var off = baseOff + index * 8;
    var num = reader.u32(off, little);
    var den = reader.u32(off + 4, little);
    if (den === 0) return 0;
    return num / den;
  }

  /** 把 GPS 的「度分秒 + 方向」转成十进制度 */
  function dmsToDecimal(dmsEntry, reader, little) {
    if (!dmsEntry) return null;
    var base = dmsEntry.valueOff;
    var deg = readRational(reader, base, 0, little);
    var min = readRational(reader, base, 1, little);
    var sec = readRational(reader, base, 2, little);
    if (!isFinite(deg) || deg > 180) return null;
    var value = deg + min / 60 + sec / 3600;
    if (!isFinite(value)) return null;
    return value;
  }

  /** 读 ASCII 值（如 "N" / "E"） */
  function readAscii(reader, entry, little) {
    if (!entry) return '';
    var out = '';
    if (entry.inline) {
      for (var i = 0; i < entry.count && i < 4; i += 1) {
        var c = reader.u8(entry.valueOff + i);
        if (c === 0) break;
        out += String.fromCharCode(c);
      }
    } else {
      out = reader.str(entry.valueOff, Math.min(entry.count, 16));
      out = out.replace(/\0+$/, '');
    }
    return out.trim();
  }

  /* ============================================================
     4. 主入口：从图片二进制里读 GPS
     ============================================================ */
  var GPS_TAGS = {
    0x0001: true, // GPSLatitudeRef
    0x0002: true, // GPSLatitude
    0x0003: true, // GPSLongitudeRef
    0x0004: true, // GPSLongitude
    0x0005: true, // GPSAltitudeRef
    0x0006: true, // GPSAltitude
    0x0007: true, // GPSTimeStamp
    0x001D: true  // GPSDateStamp
  };
  var IFD0_TAGS = { 0x8825: true };  // GPSInfoIFDPointer

  /**
   * 解析图片缓冲区里的 GPS
   * @param {ArrayBuffer} buffer
   * @returns {{ ok:boolean, lat?:number, lon?:number, reason?:string, detail?:string }}
   *   ok=false 时 reason 说明为什么拿不到（用于给用户精准提示）
   */
  function readGpsFromBuffer(buffer) {
    if (!buffer || buffer.byteLength < 20) {
      return { ok: false, reason: 'NOT_IMAGE', detail: '文件太小，不是有效图片' };
    }
    var reader;
    try { reader = new DataViewReader(buffer); } catch (e) {
      return { ok: false, reason: 'NOT_IMAGE', detail: '无法读取文件' };
    }

    // PNG：本来就不存 EXIF
    var b0 = reader.u8(0), b1 = reader.u8(1);
    if (b0 === 0x89 && b1 === 0x50) {
      return { ok: false, reason: 'PNG_NO_EXIF', detail: 'PNG 格式不保存位置信息，请用相机拍的照片' };
    }
    // HEIC/HEIF：ISO BMFF 容器，EXIF 在 meta box 里，本解析器不支持。
    // 必须**明确告诉用户是格式问题**，否则用户会以为是相机没开定位。
    if (buffer.byteLength >= 12) {
      try {
        var brand = reader.str(4, 4);
        if (brand === 'ftyp') {
          var sub = reader.str(8, 4);
          if (/^(heic|heix|hevc|hevx|heim|heis|hevm|hevs|mif1|msf1|avif)$/i.test(sub)) {
            return {
              ok: false,
              reason: 'HEIC_UNSUPPORTED',
              detail: '这是 HEIF/' + sub.toUpperCase() + ' 格式的照片，当前读不到里面的位置信息'
            };
          }
        }
      } catch (e) { /* 不是 ISO BMFF，继续走 JPEG 流程 */ }
    }

    var seg;
    try { seg = findExifSegment(reader); } catch (e) {
      return { ok: false, reason: 'BROKEN_EXIF', detail: '照片结构异常' };
    }
    if (!seg) {
      return {
        ok: false,
        reason: 'NO_EXIF',
        detail: '这张照片没有位置信息（可能是截图、社交软件转发的图，或相机未开启"位置信息"）'
      };
    }

    // TIFF 头：'II'（小端）或 'MM'（大端）
    var tiffBase = seg.start + 6;   // 跳过 "Exif\0\0"
    if (tiffBase + 8 > reader.len) {
      return { ok: false, reason: 'BROKEN_EXIF', detail: 'EXIF 数据不完整' };
    }
    var bo = reader.str(tiffBase, 2);
    var little;
    if (bo === 'II') little = true;
    else if (bo === 'MM') little = false;
    else return { ok: false, reason: 'BROKEN_EXIF', detail: 'EXIF 字节序标识异常' };

    var magic = reader.u16(tiffBase + 2, little);
    if (magic !== 42) return { ok: false, reason: 'BROKEN_EXIF', detail: '不是标准 TIFF 结构' };

    var ifd0Off;
    try {
      ifd0Off = reader.u32(tiffBase + 4, little);
      var ifd0 = readIfd(reader, tiffBase, ifd0Off, little, IFD0_TAGS);
      if (ifd0[0x8825] === undefined) {
        return {
          ok: false,
          reason: 'NO_GPS_TAG',
          detail: '照片里有相机信息，但没有位置信息 —— 相机设置里的"位置信息/地点标记"没打开'
        };
      }
      var gpsIfdOff = reader.u32(ifd0[0x8825].valueOff, little);
      var gps = readIfd(reader, tiffBase, gpsIfdOff, little, GPS_TAGS);
      if (gps[0x0002] === undefined || gps[0x0004] === undefined) {
        return {
          ok: false,
          reason: 'INCOMPLETE_GPS',
          detail: '照片写了位置字段但坐标不完整（可能被编辑过）'
        };
      }
      var latRef = readAscii(reader, gps[0x0001], little).toUpperCase();
      var lonRef = readAscii(reader, gps[0x0003], little).toUpperCase();
      var lat = dmsToDecimal(gps[0x0002], reader, little);
      var lon = dmsToDecimal(gps[0x0004], reader, little);
      if (lat === null || lon === null) {
        return { ok: false, reason: 'UNREADABLE_GPS', detail: '位置数据读不出来' };
      }
      if (latRef === 'S') lat = -lat;
      if (lonRef === 'W') lon = -lon;
      if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
        return { ok: false, reason: 'INVALID_GPS', detail: '坐标超出有效范围' };
      }
      var out = { ok: true, lat: lat, lon: lon };
      // 附带拍摄时间（可选，用于判断是否"刚刚拍的"）
      if (gps[0x001D] !== undefined) out.dateStamp = readAscii(reader, gps[0x001D], little);
      return out;
    } catch (e) {
      return { ok: false, reason: 'BROKEN_EXIF', detail: 'EXIF 解析失败：' + (e && e.message ? e.message : '未知错误') };
    }
  }

  /* ============================================================
     5. 距离校验
     ============================================================ */
  var EARTH_R = 6371008.8;

  function haversineMeters(aLat, aLon, bLat, bLon) {
    var toRad = Math.PI / 180;
    var dLat = (bLat - aLat) * toRad;
    var dLon = (bLon - aLon) * toRad;
    var sLat = Math.sin(dLat / 2);
    var sLon = Math.sin(dLon / 2);
    var h = sLat * sLat + Math.cos(aLat * toRad) * Math.cos(bLat * toRad) * sLon * sLon;
    return 2 * EARTH_R * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  /** 拍照验证的判定半径（米）：目的地多大范围内拍照算"来过" */
  var PHOTO_RADIUS_METERS = 120;

  /**
   * 用照片 GPS 验证是否到达目标地点
   * @param {{lat:number,lon:number}} target 目的地坐标
   * @param {{lat:number,lon:number}} photoGps 照片里的 GPS
   * @param {number} [radius] 允许半径（默认 120m）
   */
  function verifyPhotoAt(target, photoGps, radius) {
    var r = typeof radius === 'number' && radius > 0 ? radius : PHOTO_RADIUS_METERS;
    if (!target || !photoGps) {
      return { ok: false, reason: 'NO_DATA', distanceMeters: null };
    }
    var d = haversineMeters(target.lat, target.lon, photoGps.lat, photoGps.lon);
    if (d <= r) {
      return { ok: true, distanceMeters: d, radiusMeters: r };
    }
    return {
      ok: false,
      reason: 'TOO_FAR',
      distanceMeters: d,
      radiusMeters: r,
      detail: '照片拍摄点离目的地 ' + Math.round(d) + ' 米，超出 ' + r + ' 米范围'
    };
  }

  var api = {
    readGpsFromBuffer: readGpsFromBuffer,
    verifyPhotoAt: verifyPhotoAt,
    haversineMeters: haversineMeters,
    PHOTO_RADIUS_METERS: PHOTO_RADIUS_METERS,
    /** 各种失败原因 → 给用户看的话（UI 直接用） */
    REASON_TEXT: {
      NO_EXIF: '这张照片没有位置信息',
      NO_GPS_TAG: '相机没有开启「位置信息」',
      INCOMPLETE_GPS: '照片的位置数据不完整',
      UNREADABLE_GPS: '照片的位置数据读不出来',
      INVALID_GPS: '照片坐标不合法',
      PNG_NO_EXIF: 'PNG 照片不保存位置信息',
      HEIC_UNSUPPORTED: '这是 HEIF 格式的照片',
      BROKEN_EXIF: '照片信息损坏',
      NOT_IMAGE: '这不是有效的照片文件',
      TOO_FAR: '拍摄地点离目的地太远',
      NO_DATA: '缺少坐标数据'
    },
    /** 各种失败原因 → 具体怎么操作（UI 直接展示） */
    REASON_HOWTO: {
      NO_EXIF: '请用手机自带相机 App 拍一张新照片（不要用截图，也不要转发微信里的图）',
      NO_GPS_TAG: '请到 手机设置 → 相机/相机 App → 打开「位置信息」或「地点标记」，然后重新拍一张',
      INCOMPLETE_GPS: '这张图的位置信息被改过或不完整，请重新用相机拍一张',
      UNREADABLE_GPS: '请重新用相机拍一张',
      INVALID_GPS: '请重新用相机拍一张',
      PNG_NO_EXIF: '请用相机拍 JPEG 照片，不要用截图或 PNG',
      HEIC_UNSUPPORTED: '请到 相机设置 → 格式 → 选择「兼容性最佳 / JPEG」，或换一张 JPEG 照片重拍。' +
        '（iPhone 默认用 HEIF 格式，鸿蒙部分机型也可能如此）',
      BROKEN_EXIF: '请重新用相机拍一张',
      NOT_IMAGE: '请选择一张照片',
      TOO_FAR: '走近一点再拍一张',
      NO_DATA: '请重新拍一张'
    }
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.BW_EXIF = api;
})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
