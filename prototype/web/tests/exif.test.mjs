/** 照片 GPS（EXIF）解析 + 到达验证 */
import test from 'node:test';
import assert from 'node:assert/strict';
import E from '../exif.js';

/* ---------- 构造测试用 JPEG ---------- */

function buildExif({ lat, lon, bigEndian = false, withGpsTag = true }) {
  const le = !bigEndian;
  const w16 = (v) => { const b = Buffer.alloc(2); le ? b.writeUInt16LE(v) : b.writeUInt16BE(v); return b; };
  const w32 = (v) => { const b = Buffer.alloc(4); le ? b.writeUInt32LE(v) : b.writeUInt32BE(v); return b; };
  const dms = (value) => {
    const abs = Math.abs(value);
    const deg = Math.floor(abs);
    const minF = (abs - deg) * 60;
    const min = Math.floor(minF);
    const sec = (minF - min) * 60;
    return Buffer.concat([w32(deg), w32(1), w32(min), w32(1), w32(Math.round(sec * 10000)), w32(10000)]);
  };
  const latBuf = dms(lat), lonBuf = dms(lon);
  const latRef = Buffer.from([lat >= 0 ? 0x4E : 0x53, 0, 0, 0]);
  const lonRef = Buffer.from([lon >= 0 ? 0x45 : 0x57, 0, 0, 0]);

  const TIFF_HDR = 8;
  const IFD0_SIZE = 2 + 12 * 1 + 4;
  const GPS_IFD_OFF = TIFF_HDR + IFD0_SIZE;
  const GPS_IFD_SIZE = 2 + 12 * 4 + 4;
  const DATA_OFF = GPS_IFD_OFF + GPS_IFD_SIZE;
  const offsets = {
    latRef: DATA_OFF, lat: DATA_OFF + 4,
    lonRef: DATA_OFF + 28, lon: DATA_OFF + 32
  };

  const parts = [];
  parts.push(Buffer.from(le ? 'II' : 'MM', 'ascii'));
  parts.push(w16(42));
  parts.push(w32(TIFF_HDR));
  parts.push(w16(1));
  parts.push(w16(0x8825)); parts.push(w16(4)); parts.push(w32(1)); parts.push(w32(GPS_IFD_OFF));
  parts.push(w32(0));

  if (!withGpsTag) {
    // 真实场景：相机的 EXIF 里 IFD0 完全没有 GPSInfo 指针
    return Buffer.concat([
      Buffer.from([0xFF, 0xD8]),
      (() => {
        const tiffNoGps = Buffer.concat([
          Buffer.from(le ? 'II' : 'MM', 'ascii'), w16(42), w32(8),
          w16(0),   // IFD0 条目数 = 0（没有 GPSInfo 指针）
          w32(0)
        ]);
        const body = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), tiffNoGps]);
        const len = Buffer.alloc(2); len.writeUInt16BE(body.length + 2);
        return Buffer.concat([Buffer.from([0xFF, 0xE1]), len, body]);
      })(),
      Buffer.from([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
    ]);
  }
  {
    parts.push(w16(4));
    parts.push(w16(0x0001)); parts.push(w16(2)); parts.push(w32(2)); parts.push(latRef);
    parts.push(w16(0x0002)); parts.push(w16(5)); parts.push(w32(3)); parts.push(w32(offsets.lat));
    parts.push(w16(0x0003)); parts.push(w16(2)); parts.push(w32(2)); parts.push(lonRef);
    parts.push(w16(0x0004)); parts.push(w16(5)); parts.push(w32(3)); parts.push(w32(offsets.lon));
    parts.push(w32(0));
    parts.push(latRef); parts.push(latBuf);
    parts.push(lonRef); parts.push(lonBuf);
  }

  const tiff = Buffer.concat(parts);
  const app1Body = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), tiff]);
  const app1Len = Buffer.alloc(2);
  app1Len.writeUInt16BE(app1Body.length + 2);
  const app1 = Buffer.concat([Buffer.from([0xFF, 0xE1]), app1Len, app1Body]);
  return Buffer.concat([
    Buffer.from([0xFF, 0xD8]), app1,
    Buffer.from([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
  ]);
}

function toArrayBuffer(buf) {
  return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
}

/* ---------- 解析 ---------- */

test('EXIF：小端（Intel）GPS 正确解析', () => {
  const r = E.readGpsFromBuffer(toArrayBuffer(buildExif({ lat: 32.05975, lon: 118.77135 })));
  assert.equal(r.ok, true, r.detail);
  assert.ok(Math.abs(r.lat - 32.05975) < 0.0001, `lat=${r.lat}`);
  assert.ok(Math.abs(r.lon - 118.77135) < 0.0001, `lon=${r.lon}`);
});

test('EXIF：大端（Motorola）GPS 正确解析', () => {
  const r = E.readGpsFromBuffer(toArrayBuffer(buildExif({ lat: 39.9042, lon: 116.4074, bigEndian: true })));
  assert.equal(r.ok, true, r.detail);
  assert.ok(Math.abs(r.lat - 39.9042) < 0.0001);
  assert.ok(Math.abs(r.lon - 116.4074) < 0.0001);
});

test('EXIF：南纬 + 西经（负数）正确解析', () => {
  const r = E.readGpsFromBuffer(toArrayBuffer(buildExif({ lat: -33.8688, lon: -151.2093 })));
  assert.equal(r.ok, true, r.detail);
  assert.ok(r.lat < 0, '南半球应为负');
  assert.ok(r.lon < 0, '西经应为负');
  assert.ok(Math.abs(r.lat + 33.8688) < 0.0001);
  assert.ok(Math.abs(r.lon + 151.2093) < 0.0001);
});

test('EXIF：有 EXIF 但无 GPS 标签 → NO_GPS_TAG（提示去开相机定位）', () => {
  const r = E.readGpsFromBuffer(toArrayBuffer(buildExif({ lat: 32, lon: 118, withGpsTag: false })));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'NO_GPS_TAG');
  assert.ok(E.REASON_HOWTO[r.reason].includes('位置信息'), '应告诉用户去开启位置信息');
});

test('EXIF：无 EXIF 段 → NO_EXIF', () => {
  // 构造一个 200 字节、无 APP1 的 JPEG
  const noExif = Buffer.concat([
    Buffer.from([0xFF, 0xD8]),
    Buffer.from([0xFF, 0xFE, 0x00, 0xB4]),
    Buffer.alloc(178),
    Buffer.from([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
  ]);
  const r = E.readGpsFromBuffer(toArrayBuffer(noExif));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'NO_EXIF');
});

test('EXIF：PNG → PNG_NO_EXIF（明确说明 PNG 不存位置）', () => {
  const png = Buffer.alloc(64);
  png[0] = 0x89; png[1] = 0x50; png[2] = 0x4E; png[3] = 0x47;
  const r = E.readGpsFromBuffer(toArrayBuffer(png));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'PNG_NO_EXIF');
});

test('EXIF：空/极小文件 → NOT_IMAGE', () => {
  assert.equal(E.readGpsFromBuffer(null).ok, false);
  assert.equal(E.readGpsFromBuffer(toArrayBuffer(Buffer.alloc(4))).reason, 'NOT_IMAGE');
});

test('EXIF：损坏的字节序标识 → BROKEN_EXIF', () => {
  const bad = buildExif({ lat: 32, lon: 118 });
  // 把 'II' 改成 'XX'
  const buf = Buffer.from(bad);
  const idx = buf.indexOf(Buffer.from('II'));
  if (idx >= 0) { buf[idx] = 0x58; buf[idx + 1] = 0x58; }
  const r = E.readGpsFromBuffer(toArrayBuffer(buf));
  assert.equal(r.ok, false);
  assert.ok(['BROKEN_EXIF', 'NO_EXIF'].includes(r.reason), `实际 ${r.reason}`);
});

test('失败原因都有对应的用户提示文案', () => {
  for (const reason of ['NO_EXIF', 'NO_GPS_TAG', 'INCOMPLETE_GPS', 'UNREADABLE_GPS',
    'INVALID_GPS', 'PNG_NO_EXIF', 'BROKEN_EXIF', 'NOT_IMAGE', 'TOO_FAR', 'NO_DATA']) {
    assert.ok(E.REASON_TEXT[reason], `${reason} 缺少 REASON_TEXT`);
    assert.ok(E.REASON_HOWTO[reason], `${reason} 缺少 REASON_HOWTO`);
  }
});

/* ---------- 距离验证 ---------- */

test('距离：haversine 基本正确（南京到北京约 900km）', () => {
  const d = E.haversineMeters(32.0597, 118.7713, 39.9042, 116.4074);
  assert.ok(d > 890000 && d < 920000, `实际 ${Math.round(d)}m`);
});

test('距离：同一点为 0', () => {
  assert.ok(E.haversineMeters(32.06, 118.77, 32.06, 118.77) < 0.001);
});

test('到达验证：120m 内算到达', () => {
  const target = { lat: 32.0597, lon: 118.7713 };
  // 约 50m 外
  const near = { lat: 32.06015, lon: 118.7713 };
  const r = E.verifyPhotoAt(target, near);
  assert.equal(r.ok, true, `距离 ${Math.round(r.distanceMeters)}m`);
  assert.ok(r.distanceMeters < 120);
});

test('到达验证：超出 120m 不算', () => {
  const target = { lat: 32.0597, lon: 118.7713 };
  const far = { lat: 32.0627, lon: 118.7713 };  // 约 330m
  const r = E.verifyPhotoAt(target, far);
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'TOO_FAR');
  assert.ok(r.distanceMeters > 300);
});

test('到达验证：边界（正好 120m 附近）', () => {
  const target = { lat: 32.0597, lon: 118.7713 };
  // 120m ≈ 0.001085° 纬度
  const atEdge = { lat: 32.0597 + 0.00100, lon: 118.7713 };  // 约 111m
  assert.equal(E.verifyPhotoAt(target, atEdge).ok, true);
  const justOver = { lat: 32.0597 + 0.00120, lon: 118.7713 }; // 约 133m
  assert.equal(E.verifyPhotoAt(target, justOver).ok, false);
});

test('到达验证：自定义半径', () => {
  const target = { lat: 32.0597, lon: 118.7713 };
  const p = { lat: 32.0627, lon: 118.7713 };  // 约 330m
  assert.equal(E.verifyPhotoAt(target, p, 500).ok, true);
  assert.equal(E.verifyPhotoAt(target, p, 120).ok, false);
});

test('到达验证：缺数据', () => {
  assert.equal(E.verifyPhotoAt(null, { lat: 32, lon: 118 }).ok, false);
  assert.equal(E.verifyPhotoAt({ lat: 32, lon: 118 }, null).ok, false);
});

test('EXIF：HEIC/HEIF 明确识别为格式问题（不能误报「相机没开定位」）', () => {
  const brands = ['heic', 'heix', 'hevc', 'mif1', 'avif'];
  for (const brand of brands) {
    const b = Buffer.alloc(64);
    b.writeUInt32BE(24, 0);
    b.write('ftyp', 4, 'ascii');
    b.write(brand, 8, 'ascii');
    const r = E.readGpsFromBuffer(toArrayBuffer(b));
    assert.equal(r.ok, false);
    assert.equal(r.reason, 'HEIC_UNSUPPORTED', `${brand} 应识别为 HEIC`);
    assert.ok(E.REASON_TEXT[r.reason].includes('HEIF'), '标题应说明是 HEIF 格式');
    assert.ok(E.REASON_HOWTO[r.reason].includes('兼容性最佳') || E.REASON_HOWTO[r.reason].includes('JPEG'),
      '指引应告诉用户切到 JPEG 格式');
  }
});
