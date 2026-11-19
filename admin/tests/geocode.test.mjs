import test from 'node:test';
import assert from 'node:assert/strict';

import { geocodeAddress, GeocodeError } from '../server/geocode.mjs';

test('地址解析优先用已配置的高德 Key', async () => {
  const calls = [];
  const result = await geocodeAddress('南京市鼓楼区金银街16号', {
    getKey: (provider) => provider === 'amap' ? 'test-amap-key' : '',
    fetchImpl: async (url) => {
      calls.push(url);
      return {
        ok: true,
        json: async () => ({
          status: '1',
          geocodes: [{ location: '118.7713,32.0597' }]
        })
      };
    }
  });
  assert.deepEqual(result, { lat: 32.0597, lon: 118.7713, provider: 'amap' });
  assert.equal(calls.length, 1);
  assert.match(calls[0], /test-amap-key/);
});

test('地图服务失败时回退 Nominatim，且不返回无效坐标', async () => {
  const calls = [];
  const result = await geocodeAddress('南京鼓楼', {
    getKey: (provider) => provider === 'baidu' ? 'test-baidu-key' : '',
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      if (url.includes('baidu.com')) {
        return { ok: true, json: async () => ({ status: 1 }) };
      }
      return { ok: true, json: async () => [{ lat: '32.06', lon: '118.77' }] };
    }
  });
  assert.deepEqual(result, { lat: 32.06, lon: 118.77, provider: 'nominatim' });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].init.headers['User-Agent'], 'WalkaholicAdmin/1.0 (address geocoding)');
});

test('地址长度、空白、解析失败均明确报错，不会生成默认坐标', async () => {
  let called = false;
  const options = { fetchImpl: async () => { called = true; throw new Error('offline'); } };
  await assert.rejects(() => geocodeAddress('   ', options),
    (error) => error instanceof GeocodeError && error.code === 'BAD_REQUEST');
  await assert.rejects(() => geocodeAddress('南京'.repeat(101), options),
    (error) => error instanceof GeocodeError && error.code === 'BAD_REQUEST');
  await assert.rejects(() => geocodeAddress('不存在的地址', options),
    (error) => error instanceof GeocodeError && error.code === 'GEOCODE_FAILED' &&
      error.message.includes('地址解析失败'));
  assert.equal(called, true);
});

test('无 Key 时使用 Nominatim 并处理空结果', async () => {
  const result = await geocodeAddress('南京市鼓楼区金银街16号', {
    getKey: () => '',
    fetchImpl: async () => ({ ok: true, json: async () => [] })
  }).catch((error) => error);
  assert.ok(result instanceof GeocodeError);
  assert.equal(result.code, 'GEOCODE_FAILED');
  assert.match(result.message, /OpenStreetMap 未找到匹配地址/);
});

test('外部地址服务超时后回退并返回明确解析错误', async () => {
  const error = await geocodeAddress('超时测试地址', {
    timeoutMs: 5,
    getKey: (provider) => provider === 'amap' ? 'test-key' : '',
    fetchImpl: (url, init) => {
      if (!url.includes('amap.com')) return Promise.resolve({ ok: true, json: async () => [] });
      return new Promise((resolve, reject) => {
        init.signal.addEventListener('abort', () => {
          const timeout = new Error('aborted');
          timeout.name = 'AbortError';
          reject(timeout);
        });
      });
    }
  }).catch((failure) => failure);
  assert.ok(error instanceof GeocodeError);
  assert.match(error.message, /amap 地址服务超时/);
  assert.match(error.message, /OpenStreetMap 未找到匹配地址/);
});
