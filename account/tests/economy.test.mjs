/** 探索基金：纯函数单测（收益计算 / 封顶 / 防作弊判定） */
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ECONOMY,
  diminishingFactor,
  computeFindReward,
  capDailyEarnings,
  distanceWeight,
  deviceSignature,
  checkFindEligibility,
  checkBuryEligibility,
  dayKey
} from '../server/economy.mjs';

test('参数：埋盒零成本（供给侧不能有负期望，这是模拟审计得出的结论）', () => {
  assert.equal(ECONOMY.INITIAL_COINS, 100);
  // 押金必须为 0：否则只埋不找的人会破产，没人愿意埋 → 市场崩塌
  assert.equal(ECONOMY.BURY_DEPOSIT, 0, '埋盒必须零成本');
  // 埋主奖励应 > 寻宝单次收益上限，因为供给比需求更稀缺
  assert.ok(ECONOMY.BURY_REWARD >= ECONOMY.FIND_MAX_REWARD,
    `埋主奖励(${ECONOMY.BURY_REWARD}) 应 ≥ 单次寻宝上限(${ECONOMY.FIND_MAX_REWARD})`);
  assert.ok(ECONOMY.FIND_MAX_REWARD < ECONOMY.DAILY_EARN_CAP, '单次收益必须小于日上限');
});

test('边际递减：找得越多单次收益越低', () => {
  const factors = [0, 1, 3, 6, 10, 20].map((n) => diminishingFactor(n));
  for (let i = 1; i < factors.length; i += 1) {
    assert.ok(factors[i] <= factors[i - 1], '系数应单调不增');
  }
  assert.equal(factors[0], 1.0, '前几次满额');
  assert.ok(factors[factors.length - 1] < 0.3, '找很多次后收益应显著降低');
});

test('收益：基础 + 距离 + 首寻，且有上限', () => {
  const near = computeFindReward({ distanceMeters: 50, firstFind: false, elapsedMs: 300000 });
  assert.equal(near.finderCoins, ECONOMY.FIND_BASE_REWARD, '近距离无加成');

  const far = computeFindReward({ distanceMeters: 2000, firstFind: false, elapsedMs: 300000 });
  assert.equal(far.finderCoins, ECONOMY.FIND_BASE_REWARD + ECONOMY.FIND_MAX_DISTANCE_BONUS);

  const first = computeFindReward({ distanceMeters: 2000, firstFind: true, elapsedMs: 300000 });
  // 理论上限 = 基础 + 满距离 + 首寻
  const theoreticalMax = ECONOMY.FIND_BASE_REWARD + ECONOMY.FIND_MAX_DISTANCE_BONUS + ECONOMY.FIND_FIRST_TIME_BONUS;
  assert.equal(first.finderCoins, theoreticalMax, '全部加成叠加');
  assert.ok(first.finderCoins <= ECONOMY.FIND_MAX_REWARD, '不超过单次硬上限');
});

test('收益：距离加成单调不降', () => {
  let last = -1;
  for (const d of [0, 99, 100, 400, 900, 1900, 2500, 99999]) {
    const r = computeFindReward({ distanceMeters: d, firstFind: false, elapsedMs: 300000 });
    assert.ok(r.finderCoins >= last, `距离 ${d} 的收益不应低于更近距离`);
    last = r.finderCoins;
  }
});

test('收益：速度作弊（过快完成）一分不给', () => {
  const cheat = computeFindReward({ distanceMeters: 2000, firstFind: true, elapsedMs: 1000 });
  assert.equal(cheat.finderCoins, 0);
  assert.equal(cheat.authorCoins, 0);
  assert.ok(cheat.breakdown.some((b) => b.includes('过快')));
});

test('收益：埋主拿押金返还 + 奖励', () => {
  const r = computeFindReward({ distanceMeters: 500, firstFind: true, elapsedMs: 300000 });
  assert.equal(r.authorCoins, ECONOMY.BURY_DEPOSIT + ECONOMY.BURY_REWARD);
});

test('日上限：封顶计算正确且不为负', () => {
  assert.equal(capDailyEarnings(0, 40, 300), 40);
  assert.equal(capDailyEarnings(280, 40, 300), 20, '只补到上限');
  assert.equal(capDailyEarnings(300, 40, 300), 0, '已达上限不再给');
  assert.equal(capDailyEarnings(400, 40, 300), 0, '超上限也不为负');
  assert.equal(capDailyEarnings(0, -10, 300), 0, '负数归零');
});

test('距离权重分桶', () => {
  assert.equal(distanceWeight(50), 0);
  assert.equal(distanceWeight(300), 0.3);
  assert.equal(distanceWeight(800), 0.6);
  assert.equal(distanceWeight(1500), 0.85);
  assert.equal(distanceWeight(5000), 1);
});

test('设备指纹：同输入稳定、不同输入不同', () => {
  const a = deviceSignature('1.2.3.4', 'UA-A');
  const b = deviceSignature('1.2.3.4', 'UA-A');
  const c = deviceSignature('1.2.3.4', 'UA-B');
  assert.equal(a, b);
  assert.notEqual(a, c);
  assert.equal(a.length, 16);
});

/* ---------------- 防作弊 ---------------- */

test('防作弊：不能找自己埋的', () => {
  const r = checkFindEligibility({ viewerId: 'u1', authorId: 'u1', elapsedMs: 300000 });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'OWN_SURPRISE');
});

test('防作弊：同设备不给币', () => {
  const r = checkFindEligibility({ viewerId: 'u1', authorId: 'u2', sameDevice: true, elapsedMs: 300000 });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'SAME_DEVICE');
});

test('防作弊：同 IP 不给币', () => {
  const r = checkFindEligibility({ viewerId: 'u1', authorId: 'u2', sameIp: true, elapsedMs: 300000 });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'SAME_IP');
});

test('防作弊：一对用户每天最多结算 N 次（防互刷）', () => {
  const ok = checkFindEligibility({
    viewerId: 'u1', authorId: 'u2', elapsedMs: 300000, pairSettledToday: 1
  });
  assert.equal(ok.allowed, true);
  const blocked = checkFindEligibility({
    viewerId: 'u1', authorId: 'u2', elapsedMs: 300000,
    pairSettledToday: ECONOMY.DAILY_PAIR_SETTLE_LIMIT
  });
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.code, 'PAIR_LIMIT');
});

test('防作弊：日收益达上限后不再给', () => {
  const r = checkFindEligibility({
    viewerId: 'u1', authorId: 'u2', elapsedMs: 300000, viewerEarnedToday: ECONOMY.DAILY_EARN_CAP
  });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'DAILY_CAP');
});

test('防作弊：未登录', () => {
  const r = checkFindEligibility({ authorId: 'u2' });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'NO_AUTH');
});

test('埋盒：零成本，余额为 0 也能埋', () => {
  const r = checkBuryEligibility({ userId: 'u1', coins: 0 });
  assert.equal(r.allowed, true, '押金为 0 时余额 0 也应允许');
});

test('埋盒：每日上限', () => {
  const r = checkBuryEligibility({
    userId: 'u1', coins: 100, buriedToday: ECONOMY.DAILY_BURY_LIMIT
  });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'DAILY_BURY_LIMIT');
});

test('埋盒：同一用户埋点间距过近被拦', () => {
  const r = checkBuryEligibility({
    userId: 'u1', coins: 100, nearestExistingMeters: 10
  });
  assert.equal(r.allowed, false);
  assert.equal(r.code, 'TOO_CLOSE');
  const ok = checkBuryEligibility({ userId: 'u1', coins: 100, nearestExistingMeters: 200 });
  assert.equal(ok.allowed, true);
});

test('埋盒：没埋过时（nearest 为 null）允许', () => {
  const r = checkBuryEligibility({ userId: 'u1', coins: 100, nearestExistingMeters: null });
  assert.equal(r.allowed, true);
});

test('日键格式 YYYY-MM-DD', () => {
  const key = dayKey(new Date('2026-11-20T15:00:00+08:00').getTime());
  assert.match(key, /^\d{4}-\d{2}-\d{2}$/);
});
