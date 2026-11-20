import test from 'node:test';
import assert from 'node:assert/strict';
import T from '../territory.js';

test('凸包：正方形四点 → 4 顶点，面积约等于边长平方', () => {
  // 纬度 32° 附近，0.02° 纬度 ≈ 2.2km；0.022° 经度 ≈ 2.07km
  const pts = [
    { lat: 32.050, lon: 118.760 },
    { lat: 32.050, lon: 118.782 },
    { lat: 32.072, lon: 118.782 },
    { lat: 32.072, lon: 118.760 }
  ];
  const t = T.territoryOf(pts);
  assert.equal(t.pointCount, 4);
  assert.equal(t.hullPointCount, 4);
  assert.ok(t.areaKm2 > 4 && t.areaKm2 < 6, `面积应在 4~6 km²，实际 ${t.areaKm2}`);
  assert.ok(t.spanM > 2800 && t.spanM < 3200, `跨度应约 3km，实际 ${t.spanM}`);
});

test('凸包：内部点被剔除（5 点 → 4 个凸包顶点）', () => {
  const pts = [
    { lat: 32.050, lon: 118.760 },
    { lat: 32.050, lon: 118.782 },
    { lat: 32.072, lon: 118.782 },
    { lat: 32.072, lon: 118.760 },
    { lat: 32.061, lon: 118.771 } // 正中间的点
  ];
  const t = T.territoryOf(pts);
  assert.equal(t.pointCount, 5, '输入 5 个点');
  assert.equal(t.hullPointCount, 4, '凸包只保留 4 个顶点');
});

test('凸包：共线点不产生面积', () => {
  const t = T.territoryOf([
    { lat: 32.05, lon: 118.76 },
    { lat: 32.06, lon: 118.77 },
    { lat: 32.07, lon: 118.78 }
  ]);
  assert.equal(t.areaKm2, 0, '三点共线面积为 0');
});

test('点数不足 3 → 无疆域', () => {
  for (const n of [0, 1, 2]) {
    const pts = Array.from({ length: n }, (_, i) => ({ lat: 32.05 + i * 0.001, lon: 118.76 }));
    const t = T.territoryOf(pts);
    assert.equal(t.areaKm2, 0);
    assert.equal(t.hullPointCount, 0);
  }
});

test('非法坐标被过滤', () => {
  const t = T.territoryOf([
    { lat: 32.05, lon: 118.76 },
    { lat: 32.07, lon: 118.78 },
    { lat: 32.05, lon: 118.78 },
    { lat: NaN, lon: 118.77 },
    { lat: 100, lon: 200 }
  ]);
  assert.equal(t.pointCount, 3, '只剩 3 个合法点');
});

test('爵位：面积门槛逐级递增，且不乱序', () => {
  const ranks = T.RANKS;
  for (let i = 1; i < ranks.length; i += 1) {
    assert.ok(ranks[i].thresholdKm2 > ranks[i - 1].thresholdKm2,
      `${ranks[i].title} 门槛应大于 ${ranks[i - 1].title}`);
  }
  // 五等爵 + 扩展：公侯伯子男都在
  const titles = ranks.map(r => r.title);
  for (const t of ['士', '男爵', '子爵', '伯爵', '侯爵', '公爵']) {
    assert.ok(titles.includes(t), `应包含 ${t}`);
  }
});

test('爵位判定：边界值正确落档', () => {
  assert.equal(T.rankFor(0).rank.title, '白身');
  assert.equal(T.rankFor(0.04).rank.title, '白身');
  assert.equal(T.rankFor(0.05).rank.title, '士');
  assert.equal(T.rankFor(0.3).rank.title, '男爵');
  assert.equal(T.rankFor(1.2).rank.title, '子爵');
  assert.equal(T.rankFor(4).rank.title, '伯爵');
  assert.equal(T.rankFor(12).rank.title, '侯爵');
  assert.equal(T.rankFor(30).rank.title, '公爵');
  assert.equal(T.rankFor(80).rank.title, '王');
  assert.equal(T.rankFor(9999).rank.title, '王', '封顶');
});

test('爵位进度：0 起点与满进度', () => {
  const atStart = T.rankFor(0.05); // 刚进士
  assert.ok(atStart.progress >= 0 && atStart.progress < 0.05);
  const nearNext = T.rankFor(0.29); // 接近男爵
  assert.ok(nearNext.progress > 0.8);
  assert.equal(nearNext.next.title, '男爵');
  const max = T.rankFor(100);
  assert.equal(max.next, null, '最高爵位没有下一级');
  assert.equal(max.progress, 1);
});

test('面积格式化', () => {
  assert.equal(T.formatArea(0), '0 m²');
  assert.equal(T.formatArea(0.005), '5000 m²');
  assert.equal(T.formatArea(0.5), '0.50 km²');
  assert.equal(T.formatArea(6), '6.0 km²');
  assert.equal(T.formatArea(150), '150 km²');
});
