import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { register, request, startTestServer, withCookie } from './helpers.mjs';

/** 直接往账号库里写封禁状态（模拟后台 /admin 的操作） */
function disableUser(dataDir, username) {
  const root = dataDir;
  const dbPath = path.join(root, 'walkaholic-users.db');
  const db = new DatabaseSync(dbPath);
  try {
    const row = db.prepare('SELECT id FROM users WHERE username = ?').get(username);
    assert.ok(row, '用户应该存在：' + username);
    db.prepare(
      `INSERT INTO user_admin (user_id, disabled_at, disabled_reason, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(user_id) DO UPDATE SET disabled_at = excluded.disabled_at`
    ).run(row.id, Date.now(), '测试停用', Date.now());
    return row.id;
  } finally {
    db.close();
  }
}

test('账号服务启动时建了 user_admin 表（后台靠它读写封禁状态）', async () => {
  const server = await startTestServer();
  try {
    const db = new DatabaseSync(path.join(server.dataDir, 'walkaholic-users.db'));
    const table = db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='user_admin'"
    ).get();
    db.close();
    assert.ok(table, '有 user_admin 表，后台才能在不改 schema 的前提下封禁用户');
  } finally {
    await server.close();
  }
});

test('停用账号：已有会话立即失效（401），不能继续读资料', async () => {
  const server = await startTestServer();
  try {
    const registered = await register(server.base, 'blocked1', 'secret123');
    const cookie = withCookie(registered.cookie);
    await request(server.base, 'PUT', '/api/me/profile', { profile: { xp: 1 } }, cookie);

    const meBefore = await request(server.base, 'GET', '/api/auth/me', undefined, cookie);
    assert.equal(meBefore.status, 200);

    disableUser(server.dataDir, 'blocked1');

    const meAfter = await request(server.base, 'GET', '/api/auth/me', undefined, cookie);
    assert.equal(meAfter.status, 403);
    assert.equal(meAfter.json.code, 'ACCOUNT_DISABLED');

    // 写资料也要拦住
    const write = await request(server.base, 'PUT', '/api/me/profile', { profile: { xp: 2 } }, cookie);
    assert.equal(write.status, 403);
  } finally {
    await server.close();
  }
});

test('停用账号：密码登录被拒（403 ACCOUNT_DISABLED），恢复后能再登录', async () => {
  const server = await startTestServer();
  try {
    await register(server.base, 'blocked2', 'secret123');

    const login = await request(server.base, 'POST', '/api/auth/login', {
      username: 'blocked2',
      password: 'secret123'
    });
    assert.equal(login.status, 200);

    const userId = disableUser(server.dataDir, 'blocked2');
    const blocked = await request(server.base, 'POST', '/api/auth/login', {
      username: 'blocked2',
      password: 'secret123'
    });
    assert.equal(blocked.status, 403);
    assert.equal(blocked.json.code, 'ACCOUNT_DISABLED');
    assert.equal(blocked.setCookies.length, 0, '不能给停用账号发新 Cookie');

    // 恢复后立刻能登录（后台恢复用户，不需要重启服务）
    const db = new DatabaseSync(path.join(server.dataDir, 'walkaholic-users.db'));
    db.prepare('UPDATE user_admin SET disabled_at = NULL WHERE user_id = ?').run(userId);
    db.close();

    const again = await request(server.base, 'POST', '/api/auth/login', {
      username: 'blocked2',
      password: 'secret123'
    });
    assert.equal(again.status, 200);
    assert.ok(again.setCookies[0].includes('wa_uid='));
  } finally {
    await server.close();
  }
});

test('停用账号：注册同名仍被占用（停用不是删除）', async () => {
  const server = await startTestServer();
  try {
    await register(server.base, 'blocked3', 'secret123');
    disableUser(server.dataDir, 'blocked3');
    const dup = await register(server.base, 'blocked3', 'another123');
    assert.equal(dup.result.status, 409);
    assert.equal(dup.result.json.code, 'USERNAME_TAKEN');
  } finally {
    await server.close();
  }
});

test('删号级联：identities / place_photos / user_admin 一起清掉', async () => {
  const server = await startTestServer();
  try {
    const registered = await register(server.base, 'delcascade', 'secret123');
    const cookie = withCookie(registered.cookie);
    const userId = registered.result.json.user.id;

    await request(server.base, 'POST', '/api/photos', {
      placeId: 'p1',
      dataUrl: 'data:image/jpeg;base64,AAAA'
    }, cookie);
    const removed = await request(server.base, 'DELETE', '/api/me', { password: 'secret123' }, cookie);
    assert.equal(removed.status, 200);

    const db = new DatabaseSync(path.join(server.dataDir, 'walkaholic-users.db'));
    try {
      for (const [table, column] of [
        ['users', 'id'],
        ['profiles', 'user_id'],
        ['sessions', 'user_id'],
        ['identities', 'user_id'],
        ['place_photos', 'user_id'],
        ['user_admin', 'user_id']
      ]) {
        const row = db.prepare(`SELECT COUNT(*) AS c FROM ${table} WHERE ${column} = ?`).get(userId);
        assert.equal(row.c, 0, table + ' 里不该留下这个用户的行');
      }
    } finally {
      db.close();
    }
  } finally {
    await server.close();
  }
});
