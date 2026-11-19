import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { createServer } from '../server/index.mjs';
import { GeocodeError } from '../server/geocode.mjs';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-unified-'));
const dataDir = path.join(root, 'admin', 'data');
const accountDbPath = path.join(root, 'account', 'users.db');
fs.mkdirSync(dataDir, { recursive: true });
fs.mkdirSync(path.dirname(accountDbPath), { recursive: true });

const accountDb = new DatabaseSync(accountDbPath);
accountDb.exec(`
  CREATE TABLE surprises (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, author_name TEXT NOT NULL, author_emoji TEXT,
    lat REAL NOT NULL, lon REAL NOT NULL, area_label TEXT, message TEXT, clues TEXT NOT NULL,
    radius_meters REAL NOT NULL DEFAULT 60, photo_data TEXT, photo_hash TEXT,
    status TEXT NOT NULL DEFAULT 'waiting', finder_name TEXT, found_at INTEGER, created_at INTEGER NOT NULL
  );
`);
accountDb.prepare(`INSERT INTO surprises
  (id,user_id,author_name,author_emoji,lat,lon,area_label,message,clues,radius_meters,photo_data,status,created_at)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
  'surprise-new', 'private-user-id', 'Alice', '🐱', 32.06, 118.77, '鼓楼',
  '一条用户留言', '["线索一"]', 60, 'data:image/jpeg;base64,AAAA', 'waiting', 400
);
accountDb.prepare(`INSERT INTO surprises
  (id,user_id,author_name,author_emoji,lat,lon,area_label,message,clues,radius_meters,photo_data,status,created_at)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
  'surprise-found', 'private-user-id-2', 'Bob', '🦊', 32.07, 118.78, '玄武',
  '已找到', '[]', 60, null, 'found', 200
);
accountDb.close();

const server = createServer({
  dataDir,
  accountDbPath,
  authEnv: { WA_ADMIN_PASSWORD: 'unified-test-password' },
  geocodeAddress: async (address) => {
    if (address === '南京市鼓楼区金银街16号') return { lat: 32.0597, lon: 118.7713, provider: 'test' };
    throw new GeocodeError('地址解析失败：测试地址不可用');
  }
});
let base = '';
let cookie = '';

before(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = 'http://127.0.0.1:' + server.address().port;
  const login = await fetch(base + '/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: 'unified-test-password' })
  });
  cookie = login.headers.get('set-cookie').split(';')[0];
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });
});

test('统一列表跨类型过滤、排序、分页和总数准确', async () => {
  server.store.create({
    name: '地图抓取 POI 甲', lat: 32.05, lon: 118.75, category: 'park',
    source: 'osm', photoUrl: null, photoCredit: null, summary: '普通地点'
  });
  server.store.create({
    name: '地图抓取 POI 乙', lat: 32.051, lon: 118.751, category: 'park',
    source: 'wikipedia', photoUrl: 'https://example.test/photo.jpg',
    photoCredit: 'test', summary: '带图地点', status: 'review'
  });
  const request = async (url, auth = true) => fetch(base + url, {
    headers: auth ? { Cookie: cookie } : {}
  });

  const adminScript = await request('/admin/admin.js');
  assert.equal(adminScript.status, 200);
  assert.equal(adminScript.headers.get('cache-control'), 'no-store');
  assert.match(await adminScript.text(), /data-action="user-points"/);

  const first = await (await request('/api/admin/points?type=all&limit=2&offset=0')).json();
  const second = await (await request('/api/admin/points?type=all&limit=2&offset=2')).json();
  assert.ok(first.total !== undefined, JSON.stringify(first));
  assert.equal(first.total, 4);
  assert.equal(second.total, 4);
  assert.equal(first.items.length, 2);
  assert.equal(second.items.length, 2);
  assert.equal(new Set(first.items.concat(second.items).map((item) => item.type + ':' + item.id)).size, 4);
  const allItems = first.items.concat(second.items);
  assert.equal(allItems.filter((item) => item.type === 'user').length, 2);
  assert.equal(allItems.filter((item) => item.type === 'curated').length, 2);

  const users = await (await request('/api/admin/points?type=user&status=waiting&hasPhoto=1')).json();
  assert.equal(users.total, 1);
  assert.equal(users.items[0].source, 'user');
  assert.equal(users.items[0].type, 'user');
  assert.equal(users.items[0].hasPhoto, true);
  assert.equal(JSON.stringify(users).includes('private-user-id'), false);
  assert.equal(JSON.stringify(users).includes('photo_data'), false);
  assert.equal(JSON.stringify(users).includes('photo_hash'), false);
  assert.equal((await fetch(base + '/api/surprises/surprise-new/photo')).status, 401);
  const photo = await fetch(base + '/api/surprises/surprise-new/photo', {
    headers: { Cookie: cookie }
  });
  assert.equal(photo.status, 200);
  assert.equal(photo.headers.get('cache-control'), 'no-store');
  assert.equal(photo.headers.get('x-content-type-options'), 'nosniff');

  const curated = await (await request('/api/admin/points?type=curated&status=review&hasPhoto=1')).json();
  assert.equal(curated.total, 1);
  assert.equal(curated.items[0].source, 'wikipedia');
  assert.equal(curated.items[0].type, 'curated');
  assert.equal((await (await request('/api/admin/points?status=waiting&q=' +
    encodeURIComponent('用户留言'))).json()).total, 1);
  assert.equal((await (await request('/api/admin/points?limit=2&offset=100')).json()).items.length, 0);

  assert.equal((await request('/api/admin/points?type=nope')).status, 400);
  assert.equal((await request('/api/admin/points?limit=1.5')).status, 400);
  assert.equal((await request('/api/admin/points', false)).status, 401);

  const user = users.items[0];
  const analysis = await fetch(base + '/api/llm/analyze', {
    method: 'POST',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: [user.id] })
  });
  const analysisResult = await analysis.json();
  assert.equal(analysis.status, 200, JSON.stringify(analysisResult));
  assert.equal(analysisResult.items[0].id, user.id);
  assert.ok(analysisResult.items[0].safety.score >= 1);
  assert.equal(server.store.all().length, 2, '分析用户惊喜不能写入地图 POI 库');

  const hidden = await fetch(base + '/api/surprises/' + user.id, {
    method: 'PUT',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ status: 'hidden' })
  });
  assert.equal(hidden.status, 200);
  const found = await fetch(base + '/api/surprises/surprise-found', {
    method: 'PUT',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ status: 'hidden' })
  });
  assert.equal(found.status, 409);

  const removed = await fetch(base + '/api/surprises/' + user.id, {
    method: 'DELETE', headers: { Cookie: cookie }
  });
  assert.equal(removed.status, 200);
  assert.equal(server.store.all().length, 2, '删除用户惊喜不能误删 POI');
});

test('账号库不可用时保留地图 POI 并明确告警', async () => {
  const partialServer = createServer({
    dataDir: path.join(root, 'partial-admin'),
    accountDbPath: path.join(root, 'missing-account', 'users.db'),
    authEnv: { WA_ADMIN_PASSWORD: 'partial-test-password' }
  });
  partialServer.store.create({
    name: '可管理的地图点', lat: 32.05, lon: 118.75, category: 'park',
    source: 'osm', summary: '账号库缺失时仍可用'
  });

  await new Promise((resolve) => partialServer.listen(0, '127.0.0.1', resolve));
  try {
    const partialBase = 'http://127.0.0.1:' + partialServer.address().port;
    const login = await fetch(partialBase + '/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: 'partial-test-password' })
    });
    const partialCookie = login.headers.get('set-cookie').split(';')[0];
    const headers = { Cookie: partialCookie };
    const all = await fetch(partialBase + '/api/admin/points?type=all', { headers });
    const payload = await all.json();
    assert.equal(all.status, 200);
    assert.equal(payload.total, 1);
    assert.equal(payload.items[0].name, '可管理的地图点');
    assert.match(payload.warning, /账号库不存在/);

    const users = await fetch(partialBase + '/api/admin/points?type=user', { headers });
    assert.equal(users.status, 503);
  } finally {
    await new Promise((resolve) => partialServer.close(resolve));
  }
});

test('地址解析 API 受登录保护并返回错误而非默认坐标', async () => {
  const unauth = await fetch(base + '/api/geocode', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ address: '南京市鼓楼区金银街16号' })
  });
  assert.equal(unauth.status, 401);

  const ok = await fetch(base + '/api/geocode', {
    method: 'POST',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ address: '南京市鼓楼区金银街16号' })
  });
  assert.deepEqual(await ok.json(), { lat: 32.0597, lon: 118.7713, provider: 'test' });

  const failed = await fetch(base + '/api/geocode', {
    method: 'POST',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ address: '无结果' })
  });
  const payload = await failed.json();
  assert.equal(failed.status, 422);
  assert.match(payload.error, /地址解析失败/);
});
