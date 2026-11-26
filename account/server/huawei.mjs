/**
 * 华为账号（HUAWEI ID）登录 —— 鸿蒙端的原生登录方式
 *
 * 为什么需要：鸿蒙版之前照搬 iOS 的「通过 Apple 登录」，这是平台错乱。
 * 鸿蒙应用应该用华为账号登录，就像 iOS 用 Apple 登录一样自然。
 *
 * 配置（环境变量，未配置时 providers 接口如实返回 enabled:false + missing）：
 *   HUAWEI_CLIENT_ID      AGC「项目设置 → 应用」里的 OAuth Client ID
 *   HUAWEI_CLIENT_SECRET  AGC 里对应 Client Secret（只留服务端）
 *
 * 校验流程（Authorization Code 模式）：
 *   客户端 AccountKit 拿到 authorizationCode
 *     → 服务端 POST https://oauth-login.cloud.huawei.com/oauth2/v3/token
 *        (grant_type=authorization_code, client_id, client_secret, code)
 *     → 拿 access_token + id_token
 *     → 解码 id_token 取 sub（用户唯一标识）
 *
 * 边界：不做「静默失败」。没配好就明确告诉客户端缺什么，不假装能登录。
 */

const TOKEN_ENDPOINT = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';

/** 读取配置；missing 列出缺哪些环境变量 */
export function resolveHuaweiConfig(env = process.env) {
  const clientId = String(env.HUAWEI_CLIENT_ID || '').trim();
  const clientSecret = String(env.HUAWEI_CLIENT_SECRET || '').trim();
  const missing = [];
  if (clientId.length === 0) missing.push('HUAWEI_CLIENT_ID');
  if (clientSecret.length === 0) missing.push('HUAWEI_CLIENT_SECRET');
  return {
    enabled: missing.length === 0,
    missing,
    clientId,
    clientSecret
  };
}

/** 下发给客户端的部分：**绝不含 secret** */
export function publicHuaweiConfig(env = process.env) {
  const config = resolveHuaweiConfig(env);
  return { enabled: config.enabled, missing: config.missing, clientId: config.enabled ? config.clientId : '' };
}

/** 用授权码换 token */
export async function exchangeHuaweiCode(config, code, fetchImpl = fetch) {
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    client_id: config.clientId,
    client_secret: config.clientSecret,
    code: String(code || '')
  });
  const res = await fetchImpl(TOKEN_ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString()
  });
  const text = await res.text();
  let json = {};
  try {
    json = JSON.parse(text);
  } catch (err) {
    json = {};
  }
  if (!res.ok) {
    const message = typeof json.error_description === 'string'
      ? json.error_description
      : (typeof json.error === 'string' ? json.error : '华为账号校验失败');
    throw new Error(message);
  }
  return json;
}

/** 从 JWT 里取 payload（不验签：token 来自华为 token 端点，走的服务端到服务端 TLS） */
export function decodeJwtPayload(token) {
  const parts = String(token || '').split('.');
  if (parts.length < 2) return null;
  try {
    const raw = Buffer.from(parts[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
    const payload = JSON.parse(raw);
    if (typeof payload !== 'object' || payload === null) return null;
    return payload;
  } catch (err) {
    return null;
  }
}

/**
 * 完整校验：授权码 → sub（华为账号唯一标识）
 * 返回 { sub, nickname, avatar }
 */
export async function verifyHuaweiCode(config, code, fetchImpl = fetch) {
  const token = await exchangeHuaweiCode(config, code, fetchImpl);
  const idToken = typeof token.id_token === 'string' ? token.id_token : '';
  const payload = decodeJwtPayload(idToken);
  const sub = payload === null ? '' : String(payload.sub || '');
  if (sub.length === 0) {
    throw new Error('华为账号没返回有效的用户标识');
  }
  return {
    sub,
    nickname: payload !== null && typeof payload.nickname === 'string' ? payload.nickname : '',
    avatar: payload !== null && typeof payload.picture === 'string' ? payload.picture : ''
  };
}
