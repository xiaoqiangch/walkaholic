import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import crypto from 'node:crypto';

import { createServer } from '../server/index.mjs';

const tempDirs = [];
let server;
let base;
let cookie = '';
let accountDbPath = '';

function makeTempDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-users-api-'));
  tempDirs.push(dir);
  return dir;
}

/** 造一个最小可用的账号库（只建后台用得到的表） */
function makeAccountDb(dir) {
  const dbPath = path.join(dir, 'account', 'walkaholic-users.db');
  fs.mkdirSync(path.join(dir, 'account'), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE COLLATE NOCASE,
      pass_hash TEXT NOT NULL,
      pass_salt TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE profiles (user_id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE sessions (
      token TEXT PRIMARY KEY, user_id TEXT NOT NULL,
      created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
    );
    CREATE TABLE identities (
      provider TEXT NOT NULL, external_id TEXT NOT NULL, user_id TEXT NOT NULL,
      nickname TEXT, avatar TEXT, created_at INTEGER NOT NULL,
      PRIMARY KEY (provider, external_id)
    );
    CREATE TABLE place_photos (
      user_id TEXT NOT NULL, place_id TEXT NOT NULL, data TEXT NOT NULL,
      updated_at INTEGER NOT NULL, PRIMARY KEY (user_id, place_id)
    );
    CREATE TABLE surprises (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL, author_name TEXT NOT NULL, author_emoji TEXT,
      lat REAL NOT NULL, lon REAL NOT NULL, area_label TEXT, message TEXT, clues TEXT NOT NULL,
      radius_meters REAL NOT NULL DEFAULT 60, photo_data TEXT, photo_hash TEXT,
      status TEXT NOT NULL DEFAULT 'waiting', finder_name TEXT, found_at INTEGER, created_at INTEGER NOT NULL
    );
  `);
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync('secret123', salt, 64);
  const insert = db.prepare(
    'INSERT INTO users (id, username, pass_hash, pass_salt, created_at) VALUES (?, ?, ?, ?, ?)'
  );
  insert.run('user-1', 'alice', hash.toString('hex'), salt.toString('hex'), 1000);
  insert.run('user-2', 'bob', hash.toString('hex'), salt.toString('hex'), 2000);
  db.prepare('INSERT INTO profiles (user_id, data, updated_at) VALUES (?, ?, ?)')
    .run('user-1', '{"xp":7}', 3000);
  db.close();
  return dbPath;
}

before(async () => {
  const root = makeTempDir();
  const dataDir = path.join(root, 'admin-data');
  const publicDir = path.join(root, 'public');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(publicDir, { recursive: true });
  fs.writeFileSync(path.join(publicDir, 'index.html'), '<!doctype html><h1>admin</h1>');
  accountDbPath = makeAccountDb(root);

  server = createServer({
    dataDir,
    publicDir,
    exportPath: path.join(root, 'export', 'pois.json'),
    accountDbPath,
    llmEnv: {},
    authEnv: { WA_ADMIN_PASSWORD: 'test1234' }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = 'http://127.0.0.1:' + server.address().port;

  const login = await fetch(base + '/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: 'test1234' })
  });
  cookie = login.headers.getSetCookie()[0].split(';')[0];
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

async function api(method, pathname, body, options = {}) {
  const init = { method, headers: {} };
  if (options.auth !== false && cookie) init.headers.Cookie = cookie;
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const response = await fetch(base + pathname, { ...init, redirect: 'manual' });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) { json = null; }
  return { status: response.status, json, text };
}

test('用户列表：需要登录，返回统计但不返回密码哈希', async () => {
  const unauth = await api('GET', '/api/users', undefined, { auth: false });
  assert.equal(unauth.status, 401);

  const list = await api('GET', '/api/users');
  assert.equal(list.status, 200);
  assert.equal(list.json.total, 2);
  assert.equal(list.json.counts.all, 2);
  const alice = list.json.items.find((u) => u.id === 'user-1');
  assert.equal(alice.username, 'alice');
  assert.equal(alice.profileBytes, Buffer.byteLength('{"xp":7}'));
  assert.equal(alice.disabledAt, null);
  assert.equal(/passHash|pass_hash|passSalt/.test(list.text), false, '不能下发密码哈希');
});

test('用户列表：搜索与状态过滤', async () => {
  const search = await api('GET', '/api/users?q=bob');
  assert.equal(search.json.total, 1);
  assert.equal(search.json.items[0].id, 'user-2');

  const bad = await api('GET', '/api/users?filter=nonsense');
  assert.equal(bad.status, 400);
  assert.equal(bad.json.code, 'BAD_REQUEST');
});

test('停用 / 恢复：写入账号库并反映到列表', async () => {
  const disabled = await api('PUT', '/api/users/user-2/status', { disabled: true, reason: '刷分' });
  assert.equal(disabled.status, 200);
  assert.equal(disabled.json.user.disabledAt > 0, true);
  assert.equal(disabled.json.user.disabledReason, '刷分');

  const filtered = await api('GET', '/api/users?filter=disabled');
  assert.equal(filtered.json.total, 1);
  assert.equal(filtered.json.items[0].id, 'user-2');
  assert.equal(filtered.json.counts.disabled, 1);

  const missing = await api('PUT', '/api/users/user-2/status', {});
  assert.equal(missing.status, 400);

  const restored = await api('PUT', '/api/users/user-2/status', { disabled: false });
  assert.equal(restored.json.user.disabledAt, null);
  assert.equal((await api('GET', '/api/users?filter=disabled')).json.total, 0);
});

test('重置密码：校验长度，成功后旧密码失效', async () => {
  const tooShort = await api('PUT', '/api/users/user-2/password', { password: '123' });
  assert.equal(tooShort.status, 400);

  const ok = await api('PUT', '/api/users/user-2/password', { password: 'brandnew123' });
  assert.equal(ok.status, 200);

  const db = new DatabaseSync(accountDbPath);
  const row = db.prepare('SELECT pass_hash, pass_salt FROM users WHERE id = ?').get('user-2');
  db.close();
  const actual = crypto.scryptSync('brandnew123', Buffer.from(row.pass_salt, 'hex'), 64);
  assert.equal(actual.toString('hex'), row.pass_hash);
});

test('删除用户：级联清理，惊喜保留；不存在返回 404', async () => {
  const db = new DatabaseSync(accountDbPath);
  db.prepare(
    'INSERT INTO surprises (id, user_id, author_name, lat, lon, clues, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).run('s1', 'user-2', 'bob', 32.06, 118.77, '[]', 5000);
  db.close();

  const removed = await api('DELETE', '/api/users/user-2');
  assert.equal(removed.status, 200);
  assert.equal(removed.json.username, 'bob');
  assert.equal(removed.json.surprisesKept, 1);

  const list = await api('GET', '/api/users');
  assert.equal(list.json.total, 1);

  const again = await api('DELETE', '/api/users/user-2');
  assert.equal(again.status, 404);
  assert.equal(again.json.code, 'NOT_FOUND');

  const check = new DatabaseSync(accountDbPath);
  assert.equal(check.prepare('SELECT COUNT(*) AS c FROM surprises WHERE user_id = ?').get('user-2').c, 1);
  check.close();
});

test('账号库不可用：接口返回 503 且说明原因，不建空库', async () => {
  const root = makeTempDir();
  const dataDir = path.join(root, 'admin-data');
  const publicDir = path.join(root, 'public');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(publicDir, { recursive: true });
  fs.writeFileSync(path.join(publicDir, 'index.html'), 'x');
  const missingDb = path.join(root, 'account', 'nope.db');

  const other = createServer({
    dataDir,
    publicDir,
    exportPath: path.join(root, 'export', 'pois.json'),
    accountDbPath: missingDb,
    llmEnv: {},
    authEnv: { WA_ADMIN_PASSWORD: 'test1234' }
  });
  await new Promise((resolve) => other.listen(0, '127.0.0.1', resolve));
  const otherBase = 'http://127.0.0.1:' + other.address().port;
  try {
    const login = await fetch(otherBase + '/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: 'test1234' })
    });
    const otherCookie = login.headers.getSetCookie()[0].split(';')[0];

    const status = await fetch(otherBase + '/api/users/status', { headers: { Cookie: otherCookie } });
    const statusJson = await status.json();
    assert.equal(statusJson.available, false);
    assert.match(statusJson.error, /账号库不存在/);

    const list = await fetch(otherBase + '/api/users', { headers: { Cookie: otherCookie } });
    assert.equal(list.status, 503);
    assert.equal((await list.json()).code, 'USERS_UNAVAILABLE');
    assert.equal(fs.existsSync(missingDb), false, '不能顺手建空库');
  } finally {
    await new Promise((resolve) => other.close(resolve));
  }
});
