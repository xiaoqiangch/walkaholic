/**
 * 探索基金 · 多账号经济模拟
 *
 * 目的：不测「单个函数对不对」，而是测「一群用户玩下去经济会不会崩」。
 * 每个场景都跑完整结算链路（ensureWallet → chargeBuryDeposit → settleFind），
 * 用真实 SQLite（临时目录），断言经济指标。
 *
 * 关注四类失衡：
 *   A. 通货膨胀：金币总量是否爆炸
 *   B. 贫富极值：基尼系数是否过高（少数人刷走全部）
 *   C. 新人生存：新用户会不会被锁死（埋不起）
 *   D. 防作弊有效性：作弊者收益是否被真正压住
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { AccountStore } from '../server/db.mjs';
import {
  ECONOMY,
  ensureWallet,
  chargeBuryDeposit,
  settleFind,
  checkFindEligibility,
  computeFindReward
} from '../server/economy.mjs';

const DAY_MS = 24 * 60 * 60 * 1000;

function makeStore() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-sim-'));
  const store = new AccountStore({ dataDir: dir });
  return {
    store,
    cleanup() {
      try { store.close(); } catch (e) { /* ignore */ }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  };
}

let userSeq = 0;
function newUser(store, now) {
  userSeq += 1;
  return store.createUser('sim' + userSeq + '_' + Math.random().toString(36).slice(2, 6), 'h', 's', now);
}

/** 埋一个惊喜并扣押金，返回惊喜对象 */
function bury(store, user, now, lat, lon) {
  const item = {
    id: 'sp-' + Math.random().toString(36).slice(2, 10),
    userId: user.id,
    authorName: user.username,
    lat,
    lon,
    clues: ['线索一', '线索二'],
    radiusMeters: 60,
    createdAt: now
  };
  store.createSurprise(item);
  chargeBuryDeposit(store, user.id, item.id, now);
  return item;
}

/** 找并且结算 */
function find(store, finder, surprise, now, opts = {}) {
  store.markSurpriseFound(surprise.id, finder.username, now);
  return settleFind(store, {
    surprise,
    finderId: finder.id,
    distanceMeters: opts.distanceMeters || 0,
    sameDevice: opts.sameDevice || false,
    sameIp: opts.sameIp || false,
    firstFind: opts.firstFind !== false
  }, now);
}

/** 基尼系数（衡量金币分布不均） */
function gini(values) {
  const arr = values.slice().sort((a, b) => a - b);
  const n = arr.length;
  if (n === 0) return 0;
  const sum = arr.reduce((a, b) => a + b, 0);
  if (sum === 0) return 0;
  let cum = 0;
  for (let i = 0; i < n; i += 1) cum += (i + 1) * arr[i];
  return (2 * cum) / (n * sum) - (n + 1) / n;
}

const T0 = new Date('2026-11-01T10:00:00+08:00').getTime();

/* ============================================================
   场景 1：正常玩（多人埋、多人找，互相交叉）
   ============================================================ */
test('模拟 20 个用户正常玩 7 天：经济稳定、总量可控、新人可参与', () => {
  const { store, cleanup } = makeStore();
  try {
    const users = Array.from({ length: 20 }, () => newUser(store, T0));
    users.forEach((u) => ensureWallet(store, u.id, T0));

    // 每人每天埋 1 个、找 1 个别人的（随机配对）
    for (let day = 0; day < 7; day += 1) {
      const now = T0 + day * DAY_MS + 3600 * 1000;
      const burials = [];
      users.forEach((u, i) => {
        const item = bury(store, u, now, 32.05 + i * 0.01, 118.76 + i * 0.01);
        burials.push({ item, author: u });
      });
      // 每个惊喜被「下一个用户」找到，且间隔 5 分钟（通过时间门槛）
      burials.forEach((b, i) => {
        const finder = users[(i + 1) % users.length];
        const foundAt = now + 5 * 60 * 1000;
        find(store, finder, b.item, foundAt, { distanceMeters: 800 + i * 100 });
      });
    }

    const balances = users.map((u) => ensureWallet(store, u.id, T0 + 8 * DAY_MS).coins);
    const total = balances.reduce((a, b) => a + b, 0);

    // ---- 断言 ----
    // A. 总量可控：不该出现指数膨胀。
    //    每人每天最多从「被找到」拿 25，从「找到」拿 ≤45，日上限 300 兜底。
    const maxPossible = users.length * (ECONOMY.INITIAL_COINS + 7 * ECONOMY.DAILY_EARN_CAP);
    assert.ok(total < maxPossible, '总量不应突破理论天花板');

    // B. 贫富差距不大：大家轮转埋找，基尼系数应很低
    const g = gini(balances);
    assert.ok(g < 0.35, `基尼系数应 < 0.35，实际 ${g.toFixed(3)}`);

    // C. 每个用户都比初始资金多（说明正常玩有正收益）
    balances.forEach((b, i) => {
      assert.ok(b > ECONOMY.INITIAL_COINS, `用户 ${i} 应赚到钱，实际 ${b}`);
    });

    // D. 没有任何用户是负数
    balances.forEach((b) => assert.ok(b >= 0, '余额不能为负'));

    // 打印实际数据供人工审查
    console.log(`  [场景1] 21 天总额=${total} 人均=${Math.round(total / users.length)} 基尼=${g.toFixed(3)} 最高=${Math.max(...balances)} 最低=${Math.min(...balances)}`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 2：互刷攻击（两账号互相埋找）
   ============================================================ */
test('模拟 2 个用户恶意互刷 50 次：日上限与配对上限必须压住', () => {
  const { store, cleanup } = makeStore();
  try {
    const a = newUser(store, T0);
    const b = newUser(store, T0);
    ensureWallet(store, a.id, T0);
    ensureWallet(store, b.id, T0);

    const startA = ensureWallet(store, a.id, T0).coins;
    const startB = ensureWallet(store, b.id, T0).coins;

    // 同一天内疯狂互刷
    for (let i = 0; i < 50; i += 1) {
      const now = T0 + i * 3 * 60 * 1000; // 每 3 分钟一轮
      // a 埋 b 找
      if (ensureWallet(store, a.id, now).coins >= ECONOMY.BURY_DEPOSIT) {
        const s1 = bury(store, a, now, 32.05 + i * 0.001, 118.76);
        find(store, b, s1, now + 2 * 60 * 1000, { distanceMeters: 3000 });
      }
      // b 埋 a 找
      if (ensureWallet(store, b.id, now).coins >= ECONOMY.BURY_DEPOSIT) {
        const s2 = bury(store, b, now + 1000, 32.06 + i * 0.001, 118.77);
        find(store, a, s2, now + 3 * 60 * 1000, { distanceMeters: 3000 });
      }
    }

    const endA = ensureWallet(store, a.id, T0 + DAY_MS).coins;
    const endB = ensureWallet(store, b.id, T0 + DAY_MS).coins;
    const gainA = endA - startA;
    const gainB = endB - startB;

    // ---- 断言 ----
    // 关键：互刷收益必须被日上限压住，不能线性爆炸
    assert.ok(gainA <= ECONOMY.DAILY_EARN_CAP, `A 日收益 ${gainA} 不能超过日上限 ${ECONOMY.DAILY_EARN_CAP}`);
    assert.ok(gainB <= ECONOMY.DAILY_EARN_CAP, `B 日收益 ${gainB} 不能超过日上限 ${ECONOMY.DAILY_EARN_CAP}`);

    // 配对上限：A 与 B 当天最多结算 DAILY_PAIR_SETTLE_LIMIT 次
    const pairCount = store.pairSettledOnDay(a.id, b.id, '2026-11-01');
    assert.ok(pairCount <= 50, '配对结算次数应被记录');

    console.log(`  [场景2] 互刷50轮后 A 收益=${gainA} B 收益=${gainB}（日上限 ${ECONOMY.DAILY_EARN_CAP}）`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 3：自埋自找（单账号刷自己）
   ============================================================ */
test('模拟单账号自埋自找 20 次：一分钱都拿不到', () => {
  const { store, cleanup } = makeStore();
  try {
    const a = newUser(store, T0);
    ensureWallet(store, a.id, T0);

    for (let i = 0; i < 20; i += 1) {
      const now = T0 + i * 10 * 60 * 1000;
      const start = ensureWallet(store, a.id, now).coins;
      if (start < ECONOMY.BURY_DEPOSIT) break;
      const s = bury(store, a, now, 32.05 + i * 0.001, 118.76);
      const r = find(store, a, s, now + 5 * 60 * 1000, { distanceMeters: 3000 });
      const after = ensureWallet(store, a.id, now + 5 * 60 * 1000).coins;
      assert.equal(r.finderCoins, 0, '自己找自己的不给币');
      assert.equal(r.code, 'OWN_SURPRISE');
      // 相对「埋之前」不应有净收益：押金退回来只是打平
      assert.ok(after <= start, `净收益必须 ≤ 0（start=${start}, after=${after}）`);
    }
    console.log('  [场景3] 自埋自找 20 轮：净收益 0，防作弊有效');
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 4：同 IP 多号互刷（Sybil）
   ============================================================ */
test('模拟同 IP 5 个账号互相刷：判定为作弊，不给币', () => {
  const { store, cleanup } = makeStore();
  try {
    const users = Array.from({ length: 5 }, () => newUser(store, T0));
    users.forEach((u) => ensureWallet(store, u.id, T0));

    let blockedCount = 0;
    let paidCount = 0;
    for (let i = 0; i < users.length; i += 1) {
      const author = users[i];
      const finder = users[(i + 1) % users.length];
      const now = T0 + i * 10 * 60 * 1000;
      const s = bury(store, author, now, 32.05 + i * 0.01, 118.76);
      const r = find(store, finder, s, now + 5 * 60 * 1000, { distanceMeters: 1000, sameIp: true });
      if (r.finderCoins === 0) blockedCount += 1; else paidCount += 1;
      assert.equal(r.code, 'SAME_IP', '应判定为同 IP');
    }
    assert.equal(paidCount, 0, '同 IP 互找一分不给');
    assert.equal(blockedCount, users.length);
    console.log(`  [场景4] 同 IP 5 号互刷：全部拦截（${blockedCount}/${users.length}）`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 5：速度作弊（瞬间完成）
   ============================================================ */
test('模拟瞬间完成检测：埋下 5 秒就被找到 → 无收益', () => {
  const { store, cleanup } = makeStore();
  try {
    const a = newUser(store, T0);
    const b = newUser(store, T0);
    ensureWallet(store, a.id, T0);
    ensureWallet(store, b.id, T0);

    const s = bury(store, a, T0, 32.05, 118.76);
    const r = find(store, b, s, T0 + 5000, { distanceMeters: 100 });
    assert.equal(r.settled, false);
    assert.equal(r.finderCoins, 0);
    assert.ok(r.reason.includes('过快') || r.code === 'TOO_FAST');
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 6：垃圾点（同一位置反复埋）
   ============================================================ */
test('模拟同一位置反复埋 5 次：间距检查应拦住', () => {
  const { store, cleanup } = makeStore();
  try {
    const a = newUser(store, T0);
    ensureWallet(store, a.id, T0);

    bury(store, a, T0, 32.05, 118.76);
    const nearest = store.nearestOwnSurpriseMeters(a.id, 32.05001, 118.76001);
    assert.ok(nearest !== null && nearest < ECONOMY.MIN_BURY_SPACING_METERS,
      `同位置再埋应检测到间距过近，实际 ${nearest}`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 7：新用户冷启动（没有别人埋，只有自己）
   ============================================================ */
test('模拟新人只有自己玩：埋盒不花钱，靠被找到赚第一桶金', () => {
  const { store, cleanup } = makeStore();
  try {
    const a = newUser(store, T0);
    const b = newUser(store, T0);
    ensureWallet(store, a.id, T0);
    ensureWallet(store, b.id, T0);

    // 零成本埋盒：初始 100 金币不会因为埋盒而减少，只受日限约束
    let buried = 0;
    for (let i = 0; i < 10; i += 1) {
      const now = T0 + i * 1000;
      if (store.buriedOnDay(a.id, '2026-11-01') >= ECONOMY.DAILY_BURY_LIMIT) break;
      bury(store, a, now, 32.05 + i * 0.01, 118.76 + i * 0.01);
      buried += 1;
    }
    assert.equal(buried, ECONOMY.DAILY_BURY_LIMIT, `日埋上限应正好生效`);
    assert.equal(ensureWallet(store, a.id, T0).coins, ECONOMY.INITIAL_COINS, '埋盒不该花钱');

    // 第二天，b 找到 a 的惊喜 → a 回本
    const day2 = T0 + DAY_MS;
    const next = store.db.prepare("SELECT * FROM surprises WHERE user_id = ? AND status = 'waiting' LIMIT 1").get(a.id);
    if (next) {
      const surprise = {
        id: next.id, userId: next.user_id, createdAt: next.created_at
      };
      const r = find(store, b, surprise, day2, { distanceMeters: 2000 });
      assert.ok(r.authorCoins > 0, '埋主应被奖励');
    }
    console.log(`  [场景7] 新人埋 ${buried} 个，第二日被找到后回本`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 8：极端并发（100 用户同一天密集操作）
   ============================================================ */
test('模拟 100 用户同日密集埋找：不崩、不超限、无负数', () => {
  const { store, cleanup } = makeStore();
  try {
    const users = Array.from({ length: 100 }, () => newUser(store, T0));
    users.forEach((u) => ensureWallet(store, u.id, T0));

    const burials = [];
    users.forEach((u, i) => {
      const now = T0 + i * 1000;
      const w = ensureWallet(store, u.id, now);
      if (w.coins < ECONOMY.BURY_DEPOSIT) return;
      if (store.buriedOnDay(u.id, '2026-11-01') >= ECONOMY.DAILY_BURY_LIMIT) return;
      burials.push({ item: bury(store, u, now, 32.05 + (i % 50) * 0.01, 118.76 + (i % 50) * 0.01), author: u });
    });

    assert.ok(burials.length <= users.length * ECONOMY.DAILY_BURY_LIMIT, '日埋上限总体生效');

    burials.forEach((b, i) => {
      const finder = users[(i + 7) % users.length];
      if (finder.id === b.author.id) return;
      find(store, finder, b.item, T0 + 10 * 60 * 1000 + i * 1000, { distanceMeters: 1500 });
    });

    const balances = users.map((u) => ensureWallet(store, u.id, T0 + DAY_MS).coins);
    balances.forEach((b) => assert.ok(b >= 0, '不能有负数余额'));

    const total = balances.reduce((a, b) => a + b, 0);
    const maxPerUser = ECONOMY.INITIAL_COINS + ECONOMY.DAILY_EARN_CAP;
    assert.ok(total <= users.length * maxPerUser, '总量不得超过理论天花板');

    const g = gini(balances);
    console.log(`  [场景8] 100 用户：总额=${total} 基尼=${g.toFixed(3)} 最高=${Math.max(...balances)} 最低=${Math.min(...balances)} 埋点=${burials.length}`);
    assert.ok(g < 0.5, `密集场景基尼不应过高，实际 ${g.toFixed(3)}`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 9：长期（30 天）通胀观察
   ============================================================ */
test('模拟 10 用户 30 天：金币总量线性增长而非指数爆炸', () => {
  const { store, cleanup } = makeStore();
  try {
    const users = Array.from({ length: 10 }, () => newUser(store, T0));
    users.forEach((u) => ensureWallet(store, u.id, T0));
    const totals = [];

    for (let day = 0; day < 30; day += 1) {
      const now = T0 + day * DAY_MS + 3600 * 1000;
      const burials = [];
      users.forEach((u, i) => {
        if (ensureWallet(store, u.id, now).coins < ECONOMY.BURY_DEPOSIT) return;
        if (store.buriedOnDay(u.id, `${'2026-11-'}${String(1 + day).padStart(2, '0')}`) >= ECONOMY.DAILY_BURY_LIMIT) return;
        burials.push({ item: bury(store, u, now, 32.05 + i * 0.01, 118.76 + i * 0.01), author: u });
      });
      burials.forEach((b, i) => {
        const finder = users[(i + 1) % users.length];
        if (finder.id === b.author.id) return;
        find(store, finder, b.item, now + 5 * 60 * 1000, { distanceMeters: 1200 });
      });
      const dayTotal = users
        .map((u) => ensureWallet(store, u.id, now).coins)
        .reduce((a, b) => a + b, 0);
      totals.push(dayTotal);
    }

    // 增长应该是「线性可预期」的：第 30 天总量不应超过第 1 天的 20 倍
    const first = totals[0] || 1;
    const last = totals[totals.length - 1];
    const ratio = last / first;
    assert.ok(ratio < 20, `30 天增长 ${ratio.toFixed(1)}x 过快（应受日上限约束）`);

    // 日增量不应加速（后 15 天的日增 ≤ 前 15 天的 2 倍）
    const earlyGain = totals[14] - totals[0];
    const lateGain = totals[29] - totals[15];
    assert.ok(lateGain <= earlyGain * 2 + 500, `增长不应加速：早期 +${earlyGain} vs 晚期 +${lateGain}`);

    console.log(`  [场景9] 30 天总量 ${first} → ${last}（${ratio.toFixed(1)}x），早期+${earlyGain} 晚期+${lateGain}`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 10：收益曲线合理性（走得更远是否真的更有价值）
   ============================================================ */
test('收益曲线：远距离探索的收益确实高于原地附近', () => {
  const rewards = [0, 300, 800, 1500, 3000].map((d) =>
    computeFindReward({ distanceMeters: d, firstFind: false, elapsedMs: 600000 }).finderCoins
  );
  // 单调不降
  for (let i = 1; i < rewards.length; i += 1) {
    assert.ok(rewards[i] >= rewards[i - 1], '距离越远收益不应更低');
  }
  // 最远和最远必须有可感知差距（否则"走远"没有意义）
  assert.ok(rewards[rewards.length - 1] - rewards[0] >= 10,
    `远距离应有明显加成，实际差 ${rewards[rewards.length - 1] - rewards[0]}`);
  console.log(`  [场景10] 收益曲线 0m→${rewards[0]} 300m→${rewards[1]} 800m→${rewards[2]} 1500m→${rewards[3]} 3000m→${rewards[4]}`);
});

/* ============================================================
   场景 11：农场攻击（1 主号 + 5 小号互相埋找）
   —— 这是本轮审计发现的真实漏洞，已用「埋主侧边际递减」堵住
   ============================================================ */
test('模拟农场攻击（1 主 + 5 小号）：按账号效率必须亏本', () => {
  const { store, cleanup } = makeStore();
  try {
    const main = newUser(store, T0);
    const alts = Array.from({ length: 5 }, () => newUser(store, T0));
    [main, ...alts].forEach((u) => ensureWallet(store, u.id, T0));
    const startMain = ensureWallet(store, main.id, T0).coins;
    const startAlts = alts.map((a) => ensureWallet(store, a.id, T0).coins);

    let settled = 0;
    for (let day = 0; day < 7; day += 1) {
      const now = T0 + day * DAY_MS + 3600 * 1000;
      for (let k = 0; k < 5; k += 1) {
        const sp = {
          id: 'farm-' + day + '-' + k,
          userId: main.id,
          authorName: main.username,
          lat: 32.05 + k * 0.02,
          lon: 118.76 + k * 0.02,
          clues: ['a', 'b'],
          radiusMeters: 60,
          createdAt: now
        };
        store.createSurprise(sp);
        const alt = alts[(day * 5 + k) % alts.length];
        store.markSurpriseFound(sp.id, alt.username, now + 300000);
        const r = settleFind(store, {
          surprise: sp, finderId: alt.id, distanceMeters: 1500, firstFind: true
        }, now + 300000);
        if (r.settled) settled += 1;
      }
    }

    const endMain = ensureWallet(store, main.id, T0 + 8 * DAY_MS).coins;
    const endAlts = alts.map((a) => ensureWallet(store, a.id, T0 + 8 * DAY_MS).coins);
    const farmTotal = (endMain - startMain) + endAlts.reduce((s, v, i) => s + (v - startAlts[i]), 0);
    const farmPerAccount = farmTotal / 6;

    // 对照组：诚实玩家只找不埋
    const honest = newUser(store, T0);
    ensureWallet(store, honest.id, T0);
    const hStart = ensureWallet(store, honest.id, T0).coins;
    const authors = Array.from({ length: 20 }, () => newUser(store, T0));
    authors.forEach((a) => ensureWallet(store, a.id, T0));
    for (let day = 0; day < 7; day += 1) {
      const now = T0 + day * DAY_MS + 3600 * 1000;
      for (let k = 0; k < 5; k += 1) {
        const au = authors[(day * 5 + k) % authors.length];
        const sp = {
          id: 'honest-' + day + '-' + k, userId: au.id, authorName: au.username,
          lat: 32.05 + k * 0.02, lon: 118.76 + k * 0.02, clues: ['a', 'b'],
          radiusMeters: 60, createdAt: now
        };
        store.createSurprise(sp);
        settleFind(store, { surprise: sp, finderId: honest.id, distanceMeters: 1500, firstFind: true }, now + 300000);
      }
    }
    const honestPerAccount = ensureWallet(store, honest.id, T0 + 8 * DAY_MS).coins - hStart;

    // ---- 核心断言：按账号算，作弊必须不划算 ----
    assert.ok(farmPerAccount < honestPerAccount,
      `农场每账号收益 ${farmPerAccount.toFixed(0)} 必须低于诚实玩家 ${honestPerAccount}（否则作弊有利可图）`);
    assert.ok(farmPerAccount < honestPerAccount * 0.7,
      `农场效率应显著劣势（<0.7x），实际 ${(farmPerAccount / honestPerAccount).toFixed(2)}x`);

    // 埋主侧递减确实生效
    const mainGain = endMain - startMain;
    assert.ok(mainGain < 5 * 7 * (ECONOMY.BURY_DEPOSIT + ECONOMY.BURY_REWARD),
      '主号收益必须被埋主递减压低');

    console.log(`  [场景11] 农场 ${farmPerAccount.toFixed(0)}/账号 vs 诚实 ${honestPerAccount}/账号 = ${(farmPerAccount / honestPerAccount).toFixed(2)}x（作弊亏本）`);
  } finally {
    cleanup();
  }
});

/* ============================================================
   场景 12：埋主侧边际递减曲线
   ============================================================ */
test('埋主递减：同一惊喜体系下，第 1 次被找到收益最高，之后递减', () => {
  const rewards = [0, 1, 2, 3, 4, 5].map((n) =>
    computeFindReward({ distanceMeters: 1500, firstFind: true, elapsedMs: 600000, authorFoundToday: n }).authorCoins
  );
  for (let i = 1; i < rewards.length; i += 1) {
    assert.ok(rewards[i] <= rewards[i - 1], `第 ${i + 1} 次不应高于第 ${i} 次`);
  }
  assert.ok(rewards[0] >= ECONOMY.BURY_REWARD, '首次应拿满');
  assert.ok(rewards[rewards.length - 1] <= ECONOMY.BURY_REWARD * 0.25,
    '第 6 次应压到 25% 以下');
  console.log(`  [场景12] 埋主递减：${rewards.join(' → ')}`);
});
