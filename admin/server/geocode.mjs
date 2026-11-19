export class GeocodeError extends Error {
  constructor(message, code = 'GEOCODE_FAILED', status = 422) {
    super(message);
    this.name = 'GeocodeError';
    this.code = code;
    this.status = status;
  }
}

const REQUEST_TIMEOUT_MS = 4500;
const MAX_ADDRESS_LENGTH = 200;

function validCoordinates(lat, lon) {
  return Number.isFinite(lat) && Number.isFinite(lon) &&
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
}

function coordinateResult(lat, lon, provider) {
  const latitude = Number(lat);
  const longitude = Number(lon);
  if (!validCoordinates(latitude, longitude)) return null;
  return { lat: latitude, lon: longitude, provider };
}

async function fetchJson(fetchImpl, url, headers, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      method: 'GET',
      headers,
      signal: controller.signal
    });
    if (!response || !response.ok) throw new Error('服务暂不可用');
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function geocodeAmap(address, key, fetchImpl, timeoutMs) {
  const url = 'https://restapi.amap.com/v3/geocode/geo?address=' +
    encodeURIComponent(address) + '&key=' + encodeURIComponent(key);
  const payload = await fetchJson(fetchImpl, url, undefined, timeoutMs);
  if (payload.status !== '1' || !Array.isArray(payload.geocodes)) return null;
  const location = String(payload.geocodes[0] && payload.geocodes[0].location || '').split(',');
  if (location.length !== 2) return null;
  return coordinateResult(location[1], location[0], 'amap');
}

async function geocodeBaidu(address, key, fetchImpl, timeoutMs) {
  const url = 'https://api.map.baidu.com/geocoding/v3/?address=' +
    encodeURIComponent(address) + '&output=json&ak=' + encodeURIComponent(key);
  const payload = await fetchJson(fetchImpl, url, undefined, timeoutMs);
  if (Number(payload.status) !== 0 || !payload.result || !payload.result.location) return null;
  return coordinateResult(payload.result.location.lat, payload.result.location.lng, 'baidu');
}

async function geocodeNominatim(address, fetchImpl, timeoutMs) {
  const url = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=' +
    encodeURIComponent(address);
  const payload = await fetchJson(fetchImpl, url, {
    'User-Agent': 'WalkaholicAdmin/1.0 (address geocoding)'
  }, timeoutMs);
  if (!Array.isArray(payload) || payload.length === 0) return null;
  return coordinateResult(payload[0].lat, payload[0].lon, 'nominatim');
}

export async function geocodeAddress(input, options = {}) {
  if (typeof input !== 'string') {
    throw new GeocodeError('地址必须是文本', 'BAD_REQUEST', 400);
  }
  const address = input.trim();
  if (!address) throw new GeocodeError('地址不能为空', 'BAD_REQUEST', 400);
  if (address.length > MAX_ADDRESS_LENGTH || /[\u0000-\u001f\u007f]/.test(address)) {
    throw new GeocodeError('地址最多 200 个字符，且不能包含控制字符', 'BAD_REQUEST', 400);
  }

  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const timeoutMs = Number.isFinite(options.timeoutMs)
    ? Math.max(1, options.timeoutMs)
    : REQUEST_TIMEOUT_MS;
  const failures = [];
  const providers = [
    ['amap', options.getKey && options.getKey('amap'), geocodeAmap],
    ['baidu', options.getKey && options.getKey('baidu'), geocodeBaidu]
  ];
  for (const [provider, key, resolve] of providers) {
    if (!key) continue;
    try {
      const result = await resolve(address, key, fetchImpl, timeoutMs);
      if (result) return result;
      failures.push(provider + ' 未找到匹配地址');
    } catch (error) {
      failures.push(error && error.name === 'AbortError'
        ? provider + ' 地址服务超时'
        : provider + ' 暂不可用');
    }
  }

  try {
    const result = await geocodeNominatim(address, fetchImpl, timeoutMs);
    if (result) return result;
    failures.push('OpenStreetMap 未找到匹配地址');
  } catch (error) {
    failures.push(error && error.name === 'AbortError'
      ? 'OpenStreetMap 地址服务超时'
      : 'OpenStreetMap 地址服务暂不可用');
  }
  throw new GeocodeError(
    '地址解析失败：' + (failures.length ? failures.join('；') : '没有找到匹配地址'),
    'GEOCODE_FAILED',
    422
  );
}
