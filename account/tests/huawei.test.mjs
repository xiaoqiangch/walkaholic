/**
 * 华为账号登录（鸿蒙端原生登录）—— 用户明确反馈：
 * 「鸿蒙版本里面怎么会出现了什么 Apple ID 登录…你应该是用华为的 ID 进行登录」
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  resolveHuaweiConfig,
  publicHuaweiConfig,
  verifyHuaweiCode,
  decodeJwtPayload
} from '../server/huawei.mjs';

test('华为配置：未设环境变量时如实报缺哪些项', () => {
  const config = resolveHuaweiConfig({});
  assert.equal(config.enabled, false);
  assert.deepEqual(config.missing, ['HUAWEI_CLIENT_ID', 'HUAWEI_CLIENT_SECRET']);
});

test('华为配置：只设一半也要报缺，不能半可用', () => {
  const config = resolveHuaweiConfig({ HUAWEI_CLIENT_ID: 'abc' });
  assert.equal(config.enabled, false);
  assert.deepEqual(config.missing, ['HUAWEI_CLIENT_SECRET']);
});

test('华为配置：两项都设了才启用', () => {
  const config = resolveHuaweiConfig({ HUAWEI_CLIENT_ID: 'abc', HUAWEI_CLIENT_SECRET: 'xyz' });
  assert.equal(config.enabled, true);
  assert.deepEqual(config.missing, []);
});

test('华为配置：public 版本绝不下发 secret', () => {
  const pub = publicHuaweiConfig({ HUAWEI_CLIENT_ID: 'abc', HUAWEI_CLIENT_SECRET: 'SECRET_VALUE' });
  const serialized = JSON.stringify(pub);
  assert.equal(serialized.includes('SECRET_VALUE'), false, 'publicHuaweiConfig 泄漏了 client_secret');
  assert.equal(pub.clientId, 'abc');
  assert.equal(pub.enabled, true);
});

test('华为配置：未启用时也不下发 clientId', () => {
  const pub = publicHuaweiConfig({ HUAWEI_CLIENT_ID: 'abc' });
  assert.equal(pub.enabled, false);
  assert.equal(pub.clientId, '');
});

test('JWT payload 解码：标准 base64url', () => {
  const payload = { sub: 'huawei-user-123', nickname: '阿澈' };
  const b64 = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const decoded = decodeJwtPayload('header.' + b64 + '.signature');
  assert.equal(decoded.sub, 'huawei-user-123');
  assert.equal(decoded.nickname, '阿澈');
});

test('JWT payload 解码：畸形输入返回 null 而不是抛异常', () => {
  assert.equal(decodeJwtPayload(''), null);
  assert.equal(decodeJwtPayload('nodots'), null);
  assert.equal(decodeJwtPayload('a.!!!.c'), null);
});

test('校验授权码：成功路径返回 sub', async () => {
  const config = resolveHuaweiConfig({ HUAWEI_CLIENT_ID: 'cid', HUAWEI_CLIENT_SECRET: 'sec' });
  const idToken = 'h.' + Buffer.from(JSON.stringify({ sub: 'u-1', nickname: '小满' })).toString('base64url') + '.s';
  const fakeFetch = async (url, init) => {
    assert.equal(url, 'https://oauth-login.cloud.huawei.com/oauth2/v3/token');
    assert.equal(init.method, 'POST');
    const body = String(init.body);
    assert.ok(body.includes('grant_type=authorization_code'));
    assert.ok(body.includes('code=CODE123'));
    return {
      ok: true,
      text: async () => JSON.stringify({ access_token: 'at', id_token: idToken })
    };
  };
  const identity = await verifyHuaweiCode(config, 'CODE123', fakeFetch);
  assert.equal(identity.sub, 'u-1');
  assert.equal(identity.nickname, '小满');
});

test('校验授权码：华为返回错误时要抛出可读原因', async () => {
  const config = resolveHuaweiConfig({ HUAWEI_CLIENT_ID: 'cid', HUAWEI_CLIENT_SECRET: 'sec' });
  const fakeFetch = async () => ({
    ok: false,
    text: async () => JSON.stringify({ error: 'invalid_grant', error_description: '授权码已过期' })
  });
  await assert.rejects(
    () => verifyHuaweiCode(config, 'BAD', fakeFetch),
    /授权码已过期/
  );
});

test('校验授权码：token 里没有 id_token 要明确失败', async () => {
  const config = resolveHuaweiConfig({ HUAWEI_CLIENT_ID: 'cid', HUAWEI_CLIENT_SECRET: 'sec' });
  const fakeFetch = async () => ({ ok: true, text: async () => JSON.stringify({ access_token: 'at' }) });
  await assert.rejects(() => verifyHuaweiCode(config, 'CODE', fakeFetch), /没返回有效的用户标识/);
});
