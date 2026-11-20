/**
 * 步谜 · 探索基金（金币经济 + 防作弊）
 *
 * ============ 设计目标 ============
 * 1. 新用户有启动资金（100 金币），能立刻参与，不被"零资产"劝退
 * 2. 埋盒 → 被找到，**双方**都获得收益（供给侧激励，解决"没人埋"的冷启动）
 * 3. 找到 → 有收益，但**边际递减**（防止刷单一高价值点）
 * 4. 埋 → 有押金，被找到后返还并加成（防止乱埋垃圾点）
 * 5. 所有收益都有**日上限**（防刷）
 *
 * ============ 防作弊（按威胁排序）============
 * A. 自埋自找（Sybil 最小形态）
 *    → 服务端强制：不能找自己埋的（已有）+ 同设备/同IP 互找不给币
 * B. 刷单（两个人反复互相埋找）
 *    → 同一对用户之间，**每天**结算上限 2 次；超出的找人不给币（但记录 found）
 * C. 近距离垃圾点（原地埋、同一地点反复埋）
 *    → 埋点之间最小间距 50m；同一用户 24h 内埋点上限 5 个
 * D. 时间作弊（瞬间完成）
 *    → 埋下到被找到需要 ≥ 60 秒（否则视为刷，不给币）
 * E. 分身刷号（同 IP 大量注册）
 *    → 同 IP 24h 注册上限 3 个；同 IP 用户之间互找不给币
 * F. 收益上限
 *    → 单用户日收益上限 300 币；单次找到收益上限 60 币
 *
 * ============ 经济参数 ============
 * 初始资金      100 金币
 * 埋盒押金      10 金币（埋时扣，被找到后退还 + 奖励）
 * 埋盒奖励      15 金币（被人找到时给埋的人）
 * 寻宝奖励      20 金币（找到别人的，基础值）
 *   距离加成    +0 ~ +15（走得更远更有价值，但需真实位移）
 *   首次加成    +10（该地点第一次被人找到）
 * 找不到退还    押金全额退还（惊喜过期/下架）
 */
import { createHash } from 'node:crypto';

export const ECONOMY = {
  INITIAL_COINS: 100,

  // ---- 关键设计决策（来自多账号模拟审计）----
  // 最初设计是「埋时扣押金 10，被找到才返还」。
  // 模拟 7 天后发现：只埋不找的人 100 → 0（押金全沉没），
  // 而只找不埋的人 100 → 2010。供给侧负期望 = 没人愿意埋 = 市场崩塌。
  // 所以改成：**埋盒零成本**（DEPOSIT = 0），用「被找到时的高额奖励」激励供给。
  BURY_DEPOSIT: 0,
  BURY_REWARD: 45,

  // 寻宝收益：基础 + 距离加成 + 首寻加成，单次封顶
  FIND_BASE_REWARD: 15,
  FIND_MAX_DISTANCE_BONUS: 15,
  FIND_FIRST_TIME_BONUS: 10,
  FIND_MAX_REWARD: 40,

  // 边际递减：同一天找得越多，单次收益越低（延长可玩时间，防一次刷满）
  // [累计已找次数, 收益系数]
  DIMINISH_STEPS: [
    { after: 0, factor: 1.0 },    // 第 1–3 次
    { after: 3, factor: 0.7 },    // 第 4–6 次
    { after: 6, factor: 0.4 },    // 第 7–10 次
    { after: 10, factor: 0.2 }    // 第 11 次起
  ],

  // 埋主侧递减：被找到得越多，单次奖励越低。
  // 比寻宝侧更陡（5 次后就压到 0.15），因为埋一次可以被多个人找。
  AUTHOR_DIMINISH_STEPS: [
    { after: 0, factor: 1.0 },    // 当天第 1 次被找到
    { after: 1, factor: 0.75 },   // 第 2 次
    { after: 2, factor: 0.5 },    // 第 3 次
    { after: 3, factor: 0.3 },    // 第 4 次
    { after: 4, factor: 0.15 }    // 第 5 次起
  ],

  DAILY_EARN_CAP: 300,
  DAILY_BURY_LIMIT: 5,
  MIN_BURY_SPACING_METERS: 50,
  MIN_FOUND_DELAY_MS: 60 * 1000,

  DAILY_PAIR_SETTLE_LIMIT: 2,
  DAILY_REGISTER_PER_IP: 3
};

export class EconomyError extends Error {
  constructor(message, code, status) {
    super(message);
    this.name = 'EconomyError';
    this.code = code || 'ECONOMY_ERROR';
    this.status = status || 400;
  }
}

/* ============================================================
   1. 收益计算（纯函数，可单测）
   ============================================================ */

/** 当天已找到 N 次时的收益系数（边际递减） */
export function diminishingFactor(foundToday, steps) {
  const n = Math.max(0, Number(foundToday) || 0);
  const table = steps || ECONOMY.DIMINISH_STEPS;
  let factor = 1;
  for (const step of table) {
    if (n >= step.after) factor = step.factor;
  }
  return factor;
}

/**
 * 计算一次「被找到」的结算
 * @param {{ distanceMeters:number, firstFind:boolean, elapsedMs:number, foundToday?:number }} input
 * @returns {{ finderCoins:number, authorCoins:number, breakdown:string[] }}
 */
export function computeFindReward(input) {
  const breakdown = [];
  const distance = Number(input && input.distanceMeters) || 0;
  const firstFind = !!(input && input.firstFind);
  const elapsed = Number(input && input.elapsedMs) || 0;

  // 时间门槛不满足 → 一分不给（但调用方仍会记录 found，只是无收益）
  if (elapsed < ECONOMY.MIN_FOUND_DELAY_MS) {
    return { finderCoins: 0, authorCoins: 0, breakdown: ['过快完成，不计收益'] };
  }

  let finder = ECONOMY.FIND_BASE_REWARD;
  breakdown.push('基础 ' + ECONOMY.FIND_BASE_REWARD);

  // 距离加成：按实际行走距离线性给，满 2km 拿满
  const bonus = Math.round(
    Math.min(1, Math.max(0, distance / 2000)) * ECONOMY.FIND_MAX_DISTANCE_BONUS
  );
  if (bonus > 0) {
    finder += bonus;
    breakdown.push('距离 +' + bonus);
  }

  if (firstFind) {
    finder += ECONOMY.FIND_FIRST_TIME_BONUS;
    breakdown.push('首寻 +' + ECONOMY.FIND_FIRST_TIME_BONUS);
  }

  finder = Math.min(finder, ECONOMY.FIND_MAX_REWARD);

  // 边际递减（找得越多单次越少）
  const factor = diminishingFactor(input && input.foundToday, ECONOMY.DIMINISH_STEPS);
  if (factor < 1) {
    const before = finder;
    finder = Math.max(1, Math.round(finder * factor));
    breakdown.push('递减 ×' + factor + '（' + before + '→' + finder + '）');
  }

  // 埋主拿到押金返还 + 奖励。
  // 埋主侧也必须边际递减 —— 否则「1 主号 + N 小号」的农场攻击有利可图：
  // 小号去"找"主号埋的惊喜，主号每次稳拿满额奖励。
  // 实测（7 天）：不减时农场效率是诚实玩家的 2.56 倍。
  let author = ECONOMY.BURY_DEPOSIT + ECONOMY.BURY_REWARD;
  const authorFactor = diminishingFactor(
    input && input.authorFoundToday,
    ECONOMY.AUTHOR_DIMINISH_STEPS
  );
  if (authorFactor < 1) {
    const beforeAuthor = author;
    author = Math.max(1, Math.round(author * authorFactor));
    breakdown.push('埋主递减 ×' + authorFactor + '（' + beforeAuthor + '→' + author + '）');
  } else {
    breakdown.push('埋主 +' + author);
  }

  return { finderCoins: finder, authorCoins: author, breakdown };
}

/** 每日收益封顶（纯函数） */
export function capDailyEarnings(todayEarned, pendingCoins, cap) {
  const capValue = Number.isFinite(cap) ? cap : ECONOMY.DAILY_EARN_CAP;
  const already = Number(todayEarned) || 0;
  const want = Math.max(0, Number(pendingCoins) || 0);
  const room = Math.max(0, capValue - already);
  return Math.min(want, room);
}

/** 距离分桶 → 加成权重（给 UI 用，说明"走远有用"） */
export function distanceWeight(meters) {
  const m = Math.max(0, Number(meters) || 0);
  if (m < 100) return 0;
  if (m < 500) return 0.3;
  if (m < 1000) return 0.6;
  if (m < 2000) return 0.85;
  return 1;
}

/** 稳定的"设备指纹"哈希（同一 IP+UA 视为同设备，用于防自刷） */
export function deviceSignature(ip, userAgent) {
  return createHash('sha256')
    .update(String(ip || '') + '|' + String(userAgent || ''))
    .digest('hex')
    .slice(0, 16);
}

/* ============================================================
   2. 防作弊检查（纯函数，给定历史状态返回判定）
   ============================================================ */

/**
 * 判断这次寻宝是否可以给币
 * @returns {{ allowed:boolean, reason:string, code:string }}
 */
export function checkFindEligibility(ctx) {
  const c = ctx || {};
  if (!c.viewerId) return { allowed: false, reason: '未登录', code: 'NO_AUTH' };
  if (c.viewerId === c.authorId) return { allowed: false, reason: '不能找自己埋的', code: 'OWN_SURPRISE' };
  if (c.sameDevice) return { allowed: false, reason: '同一设备不能互刷', code: 'SAME_DEVICE' };
  if (c.sameIp) return { allowed: false, reason: '同一网络不能互刷', code: 'SAME_IP' };
  if ((c.elapsedMs || 0) < ECONOMY.MIN_FOUND_DELAY_MS) {
    return { allowed: false, reason: '过快完成，不计收益', code: 'TOO_FAST' };
  }
  if ((c.pairSettledToday || 0) >= ECONOMY.DAILY_PAIR_SETTLE_LIMIT) {
    return { allowed: false, reason: '今天和这位步迷已经结算过 ' + ECONOMY.DAILY_PAIR_SETTLE_LIMIT + ' 次', code: 'PAIR_LIMIT' };
  }
  if ((c.viewerEarnedToday || 0) >= ECONOMY.DAILY_EARN_CAP) {
    return { allowed: false, reason: '今日收益已达上限', code: 'DAILY_CAP' };
  }
  return { allowed: true, reason: '', code: 'OK' };
}

/** 判断这次埋盒是否可以（防垃圾点） */
export function checkBuryEligibility(ctx) {
  const c = ctx || {};
  if (!c.userId) return { allowed: false, reason: '未登录', code: 'NO_AUTH' };
  // 押金为 0 时不检查余额（埋盒零成本，鼓励供给）
  if (ECONOMY.BURY_DEPOSIT > 0 && (c.coins || 0) < ECONOMY.BURY_DEPOSIT) {
    return { allowed: false, reason: '金币不足以支付押金（需 ' + ECONOMY.BURY_DEPOSIT + '）', code: 'NOT_ENOUGH_COINS' };
  }
  if ((c.buriedToday || 0) >= ECONOMY.DAILY_BURY_LIMIT) {
    return { allowed: false, reason: '今天埋得够多了，明天再来', code: 'DAILY_BURY_LIMIT' };
  }
  if (Number.isFinite(c.nearestExistingMeters) && c.nearestExistingMeters < ECONOMY.MIN_BURY_SPACING_METERS) {
    return {
      allowed: false,
      reason: '离你其他惊喜太近了（' + Math.round(c.nearestExistingMeters) + 'm），换个地方',
      code: 'TOO_CLOSE'
    };
  }
  return { allowed: true, reason: '', code: 'OK' };
}

/* ============================================================
   3. 服务层（操作 store，事务性发放）
   ============================================================ */

function dayKey(now) {
  const d = new Date(now);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return y + '-' + m + '-' + day;
}

/** 确保钱包存在并已发放启动资金（幂等） */
export function ensureWallet(store, userId, now) {
  const existing = store.db
    ? store.db.prepare('SELECT coins FROM wallets WHERE user_id = ?').get(userId)
    : null;
  if (existing) {
    return store.getWallet(userId, 0, now);
  }
  const wallet = store.getWallet(userId, ECONOMY.INITIAL_COINS, now);
  store.addLedgerEntry({
    id: 'ledger-initial-' + userId,
    userId,
    amount: ECONOMY.INITIAL_COINS,
    kind: 'initial_grant',
    refId: null,
    counterpartyId: null,
    day: dayKey(now),
    createdAt: now
  });
  return wallet;
}

/** 埋盒扣押金；不足则抛错 */
export function chargeBuryDeposit(store, userId, surpriseId, now) {
  const wallet = ensureWallet(store, userId, now);
  if (ECONOMY.BURY_DEPOSIT <= 0) {
    return wallet.coins;   // 零成本埋盒：不扣钱，也不记押金流水
  }
  if (wallet.coins < ECONOMY.BURY_DEPOSIT) {
    throw new EconomyError(
      '探索基金不足，无法支付埋盒押金（需 ' + ECONOMY.BURY_DEPOSIT + ' 金币）',
      'NOT_ENOUGH_COINS',
      400
    );
  }
  const balance = store.adjustWallet(userId, -ECONOMY.BURY_DEPOSIT, now);
  store.addLedgerEntry({
    id: 'ledger-bury-' + surpriseId,
    userId,
    amount: -ECONOMY.BURY_DEPOSIT,
    kind: 'bury_deposit',
    refId: surpriseId,
    counterpartyId: null,
    day: dayKey(now),
    createdAt: now
  });
  return balance;
}

/**
 * 结算一次「被找到」：给双方发币，并写审计记录
 * @returns {{ settled:boolean, finderCoins:number, authorCoins:number, breakdown:string[], code:string, reason:string }}
 */
export function settleFind(store, ctx, now) {
  const input = ctx || {};
  const surprise = input.surprise;
  if (!surprise) throw new EconomyError('缺少惊喜信息', 'BAD_INPUT', 400);

  const finderId = input.finderId;
  const authorId = surprise.userId;
  const elapsedMs = Math.max(0, now - Number(surprise.createdAt || now));

  ensureWallet(store, authorId, now);
  ensureWallet(store, finderId, now);

  const check = checkFindEligibility({
    viewerId: finderId,
    authorId,
    sameDevice: input.sameDevice,
    sameIp: input.sameIp,
    elapsedMs,
    pairSettledToday: store.pairSettledOnDay(finderId, authorId, dayKey(now)),
    viewerEarnedToday: store.earnedOnDay(finderId, dayKey(now))
  });

  if (!check.allowed) {
    store.addSettlement({
      surpriseId: surprise.id,
      finderId,
      authorId,
      finderCoins: 0,
      authorCoins: 0,
      elapsedMs,
      distanceMeters: input.distanceMeters || 0,
      blockedReason: check.code,
      createdAt: now
    });
    // 被拦下时：埋主仍应拿回押金（否则埋的人会白亏，不公平）
    const refund = ECONOMY.BURY_DEPOSIT;
    store.adjustWallet(authorId, refund, now);
    store.addLedgerEntry({
      id: 'ledger-refund-' + surprise.id,
      userId: authorId,
      amount: refund,
      kind: 'bury_refund',
      refId: surprise.id,
      counterpartyId: finderId,
      day: dayKey(now),
      createdAt: now
    });
    return {
      settled: false,
      finderCoins: 0,
      authorCoins: refund,
      breakdown: [check.reason, '埋主押金已退还'],
      code: check.code,
      reason: check.reason
    };
  }

  const foundToday = store.db
    ? Number(store.db.prepare(
      "SELECT COUNT(*) AS c FROM coin_ledger WHERE user_id = ? AND day = ? AND kind = 'find_reward'"
    ).get(finderId, dayKey(now))?.c || 0)
    : 0;
  const authorFoundToday = store.db
    ? Number(store.db.prepare(
      "SELECT COUNT(*) AS c FROM coin_ledger WHERE user_id = ? AND day = ? AND kind = 'bury_reward'"
    ).get(authorId, dayKey(now))?.c || 0)
    : 0;
  const reward = computeFindReward({
    distanceMeters: input.distanceMeters || 0,
    firstFind: input.firstFind !== false,
    elapsedMs,
    foundToday,
    authorFoundToday
  });

  // 日上限封顶
  const finderCoins = capDailyEarnings(
    store.earnedOnDay(finderId, dayKey(now)),
    reward.finderCoins,
    ECONOMY.DAILY_EARN_CAP
  );
  const authorCoins = capDailyEarnings(
    store.earnedOnDay(authorId, dayKey(now)),
    reward.authorCoins,
    ECONOMY.DAILY_EARN_CAP
  );

  if (finderCoins > 0) {
    store.adjustWallet(finderId, finderCoins, now);
    store.addLedgerEntry({
      id: 'ledger-find-' + surprise.id,
      userId: finderId,
      amount: finderCoins,
      kind: 'find_reward',
      refId: surprise.id,
      counterpartyId: authorId,
      day: dayKey(now),
      createdAt: now
    });
  }
  if (authorCoins > 0) {
    store.adjustWallet(authorId, authorCoins, now);
    store.addLedgerEntry({
      id: 'ledger-author-' + surprise.id,
      userId: authorId,
      amount: authorCoins,
      kind: 'bury_reward',
      refId: surprise.id,
      counterpartyId: finderId,
      day: dayKey(now),
      createdAt: now
    });
  }

  store.addSettlement({
    surpriseId: surprise.id,
    finderId,
    authorId,
    finderCoins,
    authorCoins,
    elapsedMs,
    distanceMeters: input.distanceMeters || 0,
    createdAt: now
  });

  return {
    settled: true,
    finderCoins,
    authorCoins,
    breakdown: reward.breakdown,
    code: 'OK',
    reason: ''
  };
}

/** 注册时检查同 IP 注册数（防批量刷号） */
export function checkRegisterIpAllowed(store, ip, now) {
  if (!ip) return { allowed: true };
  const since = now - 24 * 60 * 60 * 1000;
  const count = store.countRegistrationsFromIp(ip, since);
  if (count >= ECONOMY.DAILY_REGISTER_PER_IP) {
    return {
      allowed: false,
      reason: '同一网络今天注册的账号过多，请明天再试',
      code: 'REGISTER_IP_LIMIT'
    };
  }
  return { allowed: true };
}

export { dayKey };
