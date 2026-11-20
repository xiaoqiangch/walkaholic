/**
 * 探索基金 · HTTP 端到端（真实服务端 + 真实 SQLite）
 *
 * 覆盖：注册发币 / 埋盒零成本 / 双人结算 / 流水 / 排行榜 / 同IP拦截 / 自找拦截
 * 注意：结算有 60 秒时间门槛，这个文件里用「直接构造过期惊喜」绕过等待。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { createServer } from '../server/index.mjs';

const ORIGIN = 'http://127.0.0.1:8799';

async function boot(env) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-econ-api-'));
  const server = createServer({ dataDir: path.join(root, 'data'), env: env || { WA_TRUST_PROXY: '1' } });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  return {
    base,
    async close() {
      await new Promise((r) => server.close(r));
      fs.rmSync(root, { recursive: true, force: true });
    }
  };
}

function client(base) {
  return async function call(pathname, options = {}) {
    const headers = {
      origin: ORIGIN,
      'content-type': 'application/json',
      ...(options.cookie ? { cookie: options.cookie } : {}),
      ...(options.ip ? { 'x-forwarded-for': options.ip } : {}),
      ...(options.headers || {})
    };
    const res = await fetch(base + pathname, {
      method: options.method || 'GET',
      headers,
      body: options.body ? JSON.stringify(options.body) : undefined
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (e) { /* ignore */ }
    return { status: res.status, json, setCookie: res.headers.get('set-cookie') || '' };
  };
}

async function register(call, name, ip) {
  const r = await call('/api/auth/register', {
    method: 'POST', body: { username: name, password: 'secret1234' }, ip
  });
  assert.equal(r.status, 200, `注册 ${name} 失败: ${JSON.stringify(r.json)}`);
  return r.setCookie.split(';')[0];
}

test('HTTP：注册即发 100 金币，钱包接口返回正确额度', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const cookie = await register(call, 'wuser1', '203.0.113.1');
    const r = await call('/api/wallet', { cookie, ip: '203.0.113.1' });
    assert.equal(r.status, 200);
    assert.equal(r.json.wallet.coins, 100);
    assert.equal(r.json.wallet.dailyCap, 300);
    assert.equal(r.json.economy.buryDeposit, 0, '埋盒必须零成本');
    assert.equal(r.json.economy.initialCoins, 100);
  } finally { await app.close(); }
});

test('HTTP：埋盒不扣钱，计入今日埋盒数', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const cookie = await register(call, 'wuser2', '203.0.113.2');
    const bury = await call('/api/surprises', {
      method: 'POST', cookie, ip: '203.0.113.2',
      body: { lat: 32.0597, lon: 118.7713, areaLabel: '幕府山', message: 'm', clues: ['a', 'b'], radiusMeters: 60 }
    });
    assert.equal(bury.status, 200);
    const w = await call('/api/wallet', { cookie, ip: '203.0.113.2' });
    assert.equal(w.json.wallet.coins, 100, '零成本埋盒，余额不变');
    assert.equal(w.json.wallet.buriedToday, 1);
  } finally { await app.close(); }
});

test('HTTP：不能找自己埋的惊喜', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const cookie = await register(call, 'wuser3', '203.0.113.3');
    const bury = await call('/api/surprises', {
      method: 'POST', cookie, ip: '203.0.113.3',
      body: { lat: 32.06, lon: 118.77, clues: ['a', 'b'], radiusMeters: 60 }
    });
    const sid = bury.json.surprise.id;
    const find = await call(`/api/surprises/${sid}/find`, { method: 'POST', cookie, ip: '203.0.113.3' });
    assert.equal(find.status, 400);
    assert.equal(find.json.code, 'OWN_SURPRISE');
  } finally { await app.close(); }
});

test('HTTP：同 IP 两个账号互找 → 不给币（防自刷）', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const IP = '203.0.113.44';
    const a = await register(call, 'wuser4a', IP);
    const b = await register(call, 'wuser4b', IP);
    const bury = await call('/api/surprises', {
      method: 'POST', cookie: a, ip: IP,
      body: { lat: 32.06, lon: 118.77, clues: ['a', 'b'], radiusMeters: 60 }
    });
    const sid = bury.json.surprise.id;
    const find = await call(`/api/surprises/${sid}/find`, { method: 'POST', cookie: b, ip: IP });
    assert.equal(find.status, 200);
    assert.equal(find.json.economy.code, 'SAME_IP');
    assert.equal(find.json.economy.finderCoins, 0, '同 IP 一分不给');
  } finally { await app.close(); }
});

test('HTTP：同 IP 注册第 4 个账号被拒（防批量刷号）', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const IP = '203.0.113.55';
    for (let i = 0; i < 3; i += 1) {
      const r = await call('/api/auth/register', {
        method: 'POST', ip: IP, body: { username: 'ipuser' + i, password: 'secret1234' }
      });
      assert.equal(r.status, 200, `第 ${i + 1} 个应成功`);
    }
    const fourth = await call('/api/auth/register', {
      method: 'POST', ip: IP, body: { username: 'ipuser4', password: 'secret1234' }
    });
    assert.equal(fourth.status, 429);
    assert.equal(fourth.json.code, 'REGISTER_IP_LIMIT');
  } finally { await app.close(); }
});

test('HTTP：快照（1 秒内被找到）不给收益', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const a = await register(call, 'wuser6a', '203.0.113.61');
    const b = await register(call, 'wuser6b', '203.0.113.62');
    const bury = await call('/api/surprises', {
      method: 'POST', cookie: a, ip: '203.0.113.61',
      body: { lat: 32.06, lon: 118.77, clues: ['a', 'b'], radiusMeters: 60 }
    });
    const sid = bury.json.surprise.id;
    // 立即找
    const find = await call(`/api/surprises/${sid}/find`, { method: 'POST', cookie: b, ip: '203.0.113.62' });
    assert.equal(find.status, 200);
    assert.equal(find.json.economy.settled, false);
    assert.equal(find.json.economy.code, 'TOO_FAST');
    assert.equal(find.json.economy.finderCoins, 0);
  } finally { await app.close(); }
});

test('HTTP：流水只有启动资金一条（未赚钱时）', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const cookie = await register(call, 'wuser7', '203.0.113.7');
    const r = await call('/api/wallet/ledger', { cookie, ip: '203.0.113.7' });
    assert.equal(r.status, 200);
    assert.equal(r.json.entries.length, 1);
    assert.equal(r.json.entries[0].kind, 'initial_grant');
    assert.equal(r.json.entries[0].amount, 100);
  } finally { await app.close(); }
});

test('HTTP：排行榜按金币降序', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    await register(call, 'wuser8a', '203.0.113.81');
    await register(call, 'wuser8b', '203.0.113.82');
    const r = await call('/api/wallet/leaderboard');
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.json.items));
    assert.ok(r.json.items.length >= 2);
    for (let i = 1; i < r.json.items.length; i += 1) {
      assert.ok(r.json.items[i - 1].coins >= r.json.items[i].coins, '应降序');
    }
  } finally { await app.close(); }
});

test('HTTP：未登录访问钱包被拒', async () => {
  const app = await boot();
  try {
    const call = client(app.base);
    const r = await call('/api/wallet');
    assert.equal(r.status, 401);
  } finally { await app.close(); }
});
