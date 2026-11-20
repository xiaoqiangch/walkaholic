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

/* ---------- 点数门槛（防「四个角」刷面积）---------- */

test('点数门槛：每个爵位都有 minPoints，且单调不降', () => {
  let last = -1;
  for (const r of T.RANKS) {
    assert.equal(typeof r.minPoints, 'number', `${r.title} 必须有 minPoints`);
    assert.ok(r.minPoints >= last, `${r.title} 的 minPoints 不应比上一档低`);
    last = r.minPoints;
  }
  assert.equal(T.RANKS[0].minPoints, 0, '白身无门槛');
  assert.equal(T.RANKS[T.RANKS.length - 1].minPoints, 21, '王门槛 21 点');
});

test('点数门槛：4 个点围 1163 km² 只能拿「士」，不是「王」', () => {
  const r = T.rankFor(1163, 4);
  assert.equal(r.rank.title, '士');
  assert.equal(r.capped, true, '应标记为被点数卡住');
  assert.equal(r.blockedBy.title, '王', '本可到王');
  assert.equal(r.pointsNeeded, 17, '还需 17 个点');
});

test('点数门槛：点数足够时按面积正常授予', () => {
  assert.equal(T.rankFor(1163, 21).rank.title, '王');
  assert.equal(T.rankFor(1163, 30).rank.title, '王');
  assert.equal(T.rankFor(1163, 22).capped, false);
});

test('点数门槛：各档边界值精确', () => {
  // 男爵：面积 0.3，需 5 点
  assert.equal(T.rankFor(0.3, 4).rank.title, '士', '4 点拿不到男爵');
  assert.equal(T.rankFor(0.3, 5).rank.title, '男爵');
  // 侯爵：面积 12，需 12 点
  assert.equal(T.rankFor(12, 11).rank.title, '伯爵');
  assert.equal(T.rankFor(12, 12).rank.title, '侯爵');
  // 公爵：面积 30，需 15 点
  assert.equal(T.rankFor(30, 14).rank.title, '侯爵');
  assert.equal(T.rankFor(30, 15).rank.title, '公爵');
  // 王：面积 80，需 21 点
  assert.equal(T.rankFor(80, 20).rank.title, '公爵');
  assert.equal(T.rankFor(80, 21).rank.title, '王');
});

test('点数门槛：不传点数时保持旧行为（只看面积）', () => {
  assert.equal(T.rankFor(1163).rank.title, '王');
  assert.equal(T.rankFor(1163).capped, false);
});

test('点数门槛：真正的小疆域不受影响（诚实玩家不会被误伤）', () => {
  // 1.5 km² / 8 点 → 子爵（需 7）
  assert.equal(T.rankFor(1.5, 8).rank.title, '子爵');
  // 5 km² / 10 点 → 伯爵（需 9）
  assert.equal(T.rankFor(5, 10).rank.title, '伯爵');
  // 13 km² / 13 点 → 侯爵（需 12）
  assert.equal(T.rankFor(13, 13).rank.title, '侯爵');
});

test('点数门槛：被卡住时 next 就是被卡的那一档（UI 要提示还差几个点）', () => {
  const r = T.rankFor(40, 4);
  assert.equal(r.capped, true);
  assert.equal(r.next.title, r.blockedBy.title);
  assert.equal(r.pointsNeeded, r.blockedBy.minPoints - 4);
});

test('点数门槛：打角攻击在不同半径下全部被降级', () => {
  // 用真实坐标模拟「四个角」
  const corners = (radiusDeg) => [
    { lat: 32.06 + radiusDeg, lon: 118.77 + radiusDeg },
    { lat: 32.06 + radiusDeg, lon: 118.77 - radiusDeg },
    { lat: 32.06 - radiusDeg, lon: 118.77 + radiusDeg },
    { lat: 32.06 - radiusDeg, lon: 118.77 - radiusDeg }
  ];
  for (const deg of [0.02, 0.05, 0.15, 0.3]) {
    const pts = corners(deg);
    const stats = T.territoryOf(pts);
    const byArea = T.rankFor(stats.areaKm2);
    const gated = T.rankFor(stats.areaKm2, stats.pointCount);
    assert.ok(stats.areaKm2 > 0, `半径 ${deg}° 应有面积`);
    assert.ok(gated.rank.order < byArea.rank.order,
      `半径 ${deg}°（${stats.areaKm2.toFixed(0)} km² / 4 点）应被降级：${byArea.rank.title} → ${gated.rank.title}`);
  }
});

test('点数门槛：达标的诚实玩家（20 点围 20 km²）正常拿侯爵', () => {
  // 围一个约 20 km² 的方，内部填 20 个点
  const pts = [];
  const side = 0.045; // ≈ 5km 边长的方
  for (let i = 0; i < 20; i += 1) {
    const t = i / 20;
    pts.push({ lat: 32.06 + (t - 0.5) * side, lon: 118.77 + (t - 0.5) * side });
  }
  // 加点让它成为有面积的形状
  pts.push({ lat: 32.06 + side / 2, lon: 118.77 - side / 2 });
  pts.push({ lat: 32.06 - side / 2, lon: 118.77 + side / 2 });
  pts.push({ lat: 32.06 - side / 2, lon: 118.77 - side / 2 });
  pts.push({ lat: 32.06 + side / 2, lon: 118.77 + side / 2 });
  const stats = T.territoryOf(pts);
  const r = T.rankFor(stats.areaKm2, stats.pointCount);
  assert.ok(stats.areaKm2 > 10, `面积应 >10 km²，实际 ${stats.areaKm2.toFixed(1)}`);
  assert.equal(r.capped, false, '点数够就不该被卡');
});
