import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import crypto from 'node:crypto';

import {
  UserAdminService,
  UserAdminError,
  hashPassword,
  SCRYPT_KEYLEN
} from '../server/users.mjs';

/**
 * 造一个与账号服务完全同构的临时库（表结构照抄 account/server/db.mjs 的 SCHEMA_SQL）。
 * 用真实 scrypt 哈希，验证重置密码后账号服务的校验路径也能通过。
 */
function makeAccountDb() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-users-'));
  fs.mkdirSync(path.join(dir, 'account'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'admin'), { recursive: true });
  const dbPath = path.join(dir, 'account', 'walkaholic-users.db');
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
  db.close();
  return { dir, dbPath };
}

function seedUsers(dbPath) {
  const db = new DatabaseSync(dbPath);
  const insert = db.prepare(
    'INSERT INTO users (id, username, pass_hash, pass_salt, created_at) VALUES (?, ?, ?, ?, ?)'
  );
  const hashed = hashPassword('secret123');
  insert.run('user-a', 'alice', hashed.hash, hashed.salt, 1000);
  insert.run('user-b', 'bob', hashed.hash, hashed.salt, 2000);
  insert.run('user-c', 'carol', hashed.hash, hashed.salt, 3000);
  db.prepare('INSERT INTO profiles (user_id, data, updated_at) VALUES (?, ?, ?)')
    .run('user-a', JSON.stringify({ xp: 42 }), 5000);
  db.prepare('INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)')
    .run('t1', 'user-a', 5000, 9999999999999);
  db.prepare('INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)')
    .run('t2', 'user-a', 5000, 9999999999999);
  db.prepare('INSERT INTO identities (provider, external_id, user_id, created_at) VALUES (?, ?, ?, ?)')
    .run('wechat', 'openid-a', 'user-a', 4000);
  db.prepare('INSERT INTO place_photos (user_id, place_id, data, updated_at) VALUES (?, ?, ?, ?)')
    .run('user-a', 'p1', 'data:image/jpeg;base64,AAAA', 5000);
  db.prepare(
    `INSERT INTO surprises (id, user_id, author_name, lat, lon, clues, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).run('s1', 'user-a', 'alice', 32.06, 118.77, '[]', 6000);
  db.close();
  return { hashed };
}

function openService(dbPath) {
  return new UserAdminService({ env: { WA_ACCOUNT_DB: dbPath }, now: () => 7000 });
}

test('list：按注册时间倒序，统计齐全，绝不返回密码字段', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  try {
    assert.equal(svc.available, true);
    const page = svc.list({});
    assert.equal(page.total, 3);
    assert.deepEqual(page.items.map((u) => u.id), ['user-c', 'user-b', 'user-a']);
    const alice = page.items.find((u) => u.id === 'user-a');
    assert.equal(alice.sessionCount, 2);
    assert.equal(alice.surpriseCount, 1);
    assert.equal(alice.photoCount, 1);
    assert.equal(alice.profileBytes, Buffer.byteLength(JSON.stringify({ xp: 42 })));
    assert.deepEqual(alice.providers, ['wechat']);
    assert.equal(alice.disabledAt, null);
    assert.equal(page.counts.all, 3);
    assert.equal(page.counts.active, 3);
    assert.equal(page.counts.disabled, 0);
    // 任何一条都不能带出哈希
    const serialized = JSON.stringify(page);
    assert.equal(/pass_hash|passHash|pass_salt|passSalt/.test(serialized), false);
  } finally { svc.close(); }
});

test('list：q 搜用户名/ID，filter 过滤停用状态', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  try {
    assert.equal(svc.list({ q: 'ali' }).total, 1);
    assert.equal(svc.list({ q: 'user-b' }).total, 1);
    assert.equal(svc.list({ q: '不存在的人' }).total, 0);

    svc.setDisabled('user-b', true, '刷分');
    const disabled = svc.list({ filter: 'disabled' });
    assert.equal(disabled.total, 1);
    assert.equal(disabled.items[0].id, 'user-b');
    assert.equal(disabled.items[0].disabledReason, '刷分');
    assert.equal(svc.list({ filter: 'active' }).total, 2);
    assert.equal(svc.list({}).counts.disabled, 1);

    assert.throws(() => svc.list({ filter: '乱写' }), (e) => e instanceof UserAdminError && e.code === 'BAD_REQUEST');
  } finally { svc.close(); }
});

test('setDisabled：停用保留会话（让账号服务稳定返回 403），恢复即时生效', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  const db = new DatabaseSync(dbPath);
  try {
    const result = svc.setDisabled('user-a', true, '违规');
    assert.ok(result.user.disabledAt);
    // 刻意保留会话：删了客户端只会看到 401「登录过期」，不知道是被停用
    assert.equal(result.user.sessionCount, 2);
    assert.equal(db.prepare('SELECT COUNT(*) AS c FROM sessions WHERE user_id = ?').get('user-a').c, 2);
    assert.equal(svc.setDisabled('user-c', true, '').sessionsCleared, 0);

    const restored = svc.setDisabled('user-a', false, '');
    assert.equal(restored.user.disabledAt, null);
    assert.equal(restored.user.disabledReason, '');
    assert.equal(svc.list({ filter: 'disabled' }).total, 1, '只剩 user-c 还是停用');
  } finally { db.close(); svc.close(); }
});

test('setDisabled：用户不存在 → 404', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  try {
    assert.throws(() => svc.setDisabled('nope', true, ''), (e) => e.code === 'NOT_FOUND');
  } finally { svc.close(); }
});

test('resetPassword：真的能通过账号服务的 scrypt 校验，且清掉旧会话', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  const db = new DatabaseSync(dbPath);
  try {
    const result = svc.resetPassword('user-a', 'newpass888');
    assert.equal(result.sessionsCleared, 2);
    assert.equal(result.user.sessionCount, 0);

    const row = db.prepare('SELECT pass_hash, pass_salt FROM users WHERE id = ?').get('user-a');
    // 用账号服务的校验算法复算：crypto.scryptSync(password, salt, 64) 与库里一致
    const actual = crypto.scryptSync('newpass888', Buffer.from(row.pass_salt, 'hex'), SCRYPT_KEYLEN);
    assert.equal(actual.toString('hex'), row.pass_hash);
    // 旧密码必须失效
    const old = crypto.scryptSync('secret123', Buffer.from(row.pass_salt, 'hex'), SCRYPT_KEYLEN);
    assert.notEqual(old.toString('hex'), row.pass_hash);
  } finally { db.close(); svc.close(); }
});

test('resetPassword：密码长度不合法直接拒绝，不改库', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  try {
    const before = svc.get('user-a');
    assert.throws(() => svc.resetPassword('user-a', '123'), (e) => e.code === 'BAD_REQUEST');
    assert.throws(() => svc.resetPassword('user-a', 'x'.repeat(129)), (e) => e.code === 'BAD_REQUEST');
    assert.throws(() => svc.resetPassword('user-a', 12345678), (e) => e.code === 'BAD_REQUEST');
    assert.deepEqual(svc.get('user-a'), before);
  } finally { svc.close(); }
});

test('remove：级联清理账号数据，惊喜保留给寻者', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  const db = new DatabaseSync(dbPath);
  try {
    const result = svc.remove('user-a');
    assert.equal(result.ok, true);
    assert.equal(result.username, 'alice');
    assert.equal(result.removed.users, 1);
    assert.equal(result.removed.sessions, 2);
    assert.equal(result.removed.identities, 1);
    assert.equal(result.removed.photos, 1);
    assert.equal(result.surprisesKept, 1);

    assert.equal(svc.find('user-a'), null);
    assert.equal(db.prepare('SELECT COUNT(*) AS c FROM identities WHERE user_id = ?').get('user-a').c, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS c FROM place_photos WHERE user_id = ?').get('user-a').c, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS c FROM surprises WHERE user_id = ?').get('user-a').c, 1);
    assert.equal(svc.list({}).total, 2);
  } finally { db.close(); svc.close(); }
});

test('remove：删掉后同名可以重新注册（不留 UNIQUE 残留）', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const svc = openService(dbPath);
  const db = new DatabaseSync(dbPath);
  try {
    svc.remove('user-b');
    const hashed = hashPassword('secret123');
    db.prepare('INSERT INTO users (id, username, pass_hash, pass_salt, created_at) VALUES (?, ?, ?, ?, ?)')
      .run('user-b2', 'bob', hashed.hash, hashed.salt, 9000);
    assert.equal(svc.list({}).total, 3);
  } finally { db.close(); svc.close(); }
});

test('账号库不可用：available=false 且所有操作 503，不新建成空库', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-users-miss-'));
  const dbPath = path.join(dir, 'account', 'nope.db');
  const svc = new UserAdminService({ dbPath });
  try {
    assert.equal(svc.available, false);
    assert.match(svc.status().error, /账号库不存在/);
    assert.throws(() => svc.list({}), (e) => e.code === 'USERS_UNAVAILABLE' && e.status === 503);
    assert.equal(fs.existsSync(dbPath), false, '不能顺手建一个空库骗人');
  } finally {
    svc.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('库存在但不是账号库（没有 users 表）→ 明确报错', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-users-wrong-'));
  const dbPath = path.join(dir, 'other.db');
  const db = new DatabaseSync(dbPath);
  db.exec('CREATE TABLE something (id TEXT)');
  db.close();
  const svc = new UserAdminService({ dbPath });
  try {
    assert.equal(svc.available, false);
    assert.match(svc.status().error, /没有 users 表/);
  } finally {
    svc.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('老库没有 user_admin 表时自动补建（增量，不动既有数据）', () => {
  const { dbPath } = makeAccountDb();
  seedUsers(dbPath);
  const probe = new DatabaseSync(dbPath);
  assert.equal(
    probe.prepare("SELECT COUNT(*) AS c FROM sqlite_master WHERE name = 'user_admin'").get().c,
    0
  );
  probe.close();

  const svc = openService(dbPath);
  try {
    assert.equal(svc.available, true);
    assert.equal(svc.list({}).total, 3);
    const check = new DatabaseSync(dbPath);
    assert.equal(
      check.prepare("SELECT COUNT(*) AS c FROM sqlite_master WHERE name = 'user_admin'").get().c,
      1
    );
    check.close();
  } finally { svc.close(); }
});
