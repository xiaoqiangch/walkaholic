/**
 * 步迷 Walkaholic · 兴趣点后台 — 用户账号管理（直接读写账号库）
 *
 * 为什么直连账号库：
 *   和惊喜审核（surprises.mjs）、微信设置（accountsettings.mjs）同一套做法。
 *   账号服务是另一个进程、另一个库；让浏览器跨服务调就得把长期管理令牌发到前端，
 *   那是把凭证交出去。后台本来就已经开着账号库，这里沿用同一套做法：
 *   后台直接读写，账号服务每次请求现读，改完立即生效。
 *
 * 能做什么（全部是运维真正会用到的，不做无边界的「任意 SQL」）：
 *   - 列表 / 搜索 / 分页：用户名、注册时间、资料体积、会话数、惊喜数、登录方式、封禁状态
 *   - 停用 / 恢复账号（停用时清掉全部会话，立即掉线）
 *   - 重置密码（scrypt，与 account/server/auth.mjs 同参数；重置后清掉会话）
 *   - 删除账号（与账号服务 DELETE /api/me 的级联口径一致）
 *
 * 安全约束：
 *   - 读取接口绝不返回 pass_hash / pass_salt，只回统计字段
 *   - 不建业务库；库不存在就明确报不可用
 *   - user_admin（封禁状态）表若还没建，这里按与账号服务完全一致的 DDL 补建，
 *     纯增量操作，不会改动 users / profiles / sessions
 */

import fs from 'node:fs';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

import { resolveAccountDbPath } from './surprises.mjs';

export const SCRYPT_KEYLEN = 64;
export const PASSWORD_MIN_LENGTH = 6;
export const PASSWORD_MAX_LENGTH = 128;
export const USER_FILTERS = ['all', 'active', 'disabled'];

/**
 * 与 account/server/db.mjs 的 SCHEMA_SQL 保持完全一致。
 * 账号服务重启后同样会跑一次 CREATE TABLE IF NOT EXISTS，两边不会分叉。
 */
const USER_ADMIN_DDL = `
CREATE TABLE IF NOT EXISTS user_admin (
  user_id TEXT PRIMARY KEY,
  disabled_at INTEGER,
  disabled_reason TEXT,
  updated_at INTEGER NOT NULL
);
`;

export class UserAdminError extends Error {
  constructor(message, code, status = 400) {
    super(message);
    this.name = 'UserAdminError';
    this.code = code;
    this.status = status;
  }
}

/** 生成 scrypt 哈希与 salt（hex）——参数必须与 account/server/auth.mjs 一致 */
export function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(String(password), salt, SCRYPT_KEYLEN);
  return { hash: hash.toString('hex'), salt: salt.toString('hex') };
}

function rowToUser(row) {
  if (!row) return null;
  return {
    id: String(row.id),
    username: String(row.username),
    createdAt: Number(row.created_at),
    disabledAt: row.disabled_at ? Number(row.disabled_at) : null,
    disabledReason: row.disabled_reason ? String(row.disabled_reason) : '',
    profileBytes: Number(row.profile_bytes || 0),
    profileUpdatedAt: row.profile_updated_at === null || row.profile_updated_at === undefined
      ? null
      : Number(row.profile_updated_at),
    sessionCount: Number(row.session_count || 0),
    surpriseCount: Number(row.surprise_count || 0),
    photoCount: Number(row.photo_count || 0),
    providers: row.providers ? String(row.providers).split(',').filter(Boolean) : []
  };
}

const USER_SELECT = `
  SELECT u.id, u.username, u.created_at,
         a.disabled_at, a.disabled_reason,
         COALESCE(length(p.data), 0) AS profile_bytes,
         p.updated_at AS profile_updated_at,
         (SELECT COUNT(*) FROM sessions s WHERE s.user_id = u.id AND s.expires_at > ?) AS session_count,
         (SELECT COUNT(*) FROM surprises su WHERE su.user_id = u.id) AS surprise_count,
         (SELECT COUNT(*) FROM place_photos ph WHERE ph.user_id = u.id) AS photo_count,
         (SELECT group_concat(i.provider, ',') FROM identities i WHERE i.user_id = u.id) AS providers
  FROM users u
  LEFT JOIN profiles p ON p.user_id = u.id
  LEFT JOIN user_admin a ON a.user_id = u.id`;

export class UserAdminService {
  /**
   * @param {{ dbPath?: string, env?: object, adminDataDir?: string, now?: () => number }} options
   */
  constructor(options = {}) {
    this.dbPath = resolveAccountDbPath(options);
    this.now = options.now || (() => Date.now());
    this.db = null;
    this.error = '';
    this.open();
  }

  open() {
    if (!fs.existsSync(this.dbPath)) {
      this.error = '账号库不存在：' + this.dbPath + '（账号服务还没跑过，或 WA_ACCOUNT_DB 配错了）';
      return;
    }
    try {
      this.db = new DatabaseSync(this.dbPath);
      this.db.exec('PRAGMA busy_timeout = 3000');
      const table = this.db.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'users'"
      ).get();
      if (!table) {
        this.db.close();
        this.db = null;
        this.error = '账号库里没有 users 表（不像账号服务的库，检查 WA_ACCOUNT_DB）';
        return;
      }
      // 封禁状态是纯增量表：账号服务还没升级到含该表的版本时，这里补建同结构表
      this.db.exec(USER_ADMIN_DDL);
      this.error = '';
    } catch (error) {
      this.db = null;
      this.error = '打开账号库失败：' + (error && error.message ? error.message : String(error));
    }
  }

  get available() {
    return this.db !== null;
  }

  status() {
    return { available: this.available, dbPath: this.dbPath, error: this.error };
  }

  requireDb() {
    if (!this.db) {
      throw new UserAdminError(this.error || '账号库不可用', 'USERS_UNAVAILABLE', 503);
    }
    return this.db;
  }

  list(params = {}) {
    const db = this.requireDb();
    const q = String(params.q || '').trim();
    const filter = String(params.filter || 'all').trim() || 'all';
    if (USER_FILTERS.indexOf(filter) < 0) {
      throw new UserAdminError('filter 只能是 all / active / disabled', 'BAD_REQUEST', 400);
    }
    const limit = Math.min(200, Math.max(1, Number(params.limit) || 50));
    const offset = Math.max(0, Number(params.offset) || 0);

    const where = [];
    const args = [];
    if (q) {
      where.push('(u.username LIKE ? OR u.id LIKE ?)');
      const like = '%' + q + '%';
      args.push(like, like);
    }
    if (filter === 'disabled') where.push('a.disabled_at IS NOT NULL');
    else if (filter === 'active') where.push('a.disabled_at IS NULL');
    const clause = where.length ? ' WHERE ' + where.join(' AND ') : '';

    const totalRow = db.prepare(
      'SELECT COUNT(*) AS c FROM users u LEFT JOIN user_admin a ON a.user_id = u.id' + clause
    ).get(...args);

    const rows = db.prepare(
      USER_SELECT + clause + ' ORDER BY u.created_at DESC LIMIT ? OFFSET ?'
    ).all(this.now(), ...args, limit, offset);

    const totalUsers = db.prepare('SELECT COUNT(*) AS c FROM users').get();
    const disabledRow = db.prepare(
      'SELECT COUNT(*) AS c FROM user_admin WHERE disabled_at IS NOT NULL'
    ).get();
    const all = totalUsers ? Number(totalUsers.c) : 0;
    const disabled = disabledRow ? Number(disabledRow.c) : 0;

    return {
      items: rows.map(rowToUser),
      total: totalRow ? Number(totalRow.c) : 0,
      counts: { all, active: all - disabled, disabled },
      limit,
      offset
    };
  }

  get(userId) {
    const db = this.requireDb();
    const row = db.prepare(USER_SELECT + ' WHERE u.id = ?').get(this.now(), String(userId));
    if (!row) throw new UserAdminError('用户不存在：' + userId, 'NOT_FOUND', 404);
    return rowToUser(row);
  }

  find(userId) {
    const db = this.requireDb();
    const row = db.prepare(USER_SELECT + ' WHERE u.id = ?').get(this.now(), String(userId));
    return rowToUser(row);
  }

  /**
   * 停用 / 恢复。
   *
   * 刻意**不删会话**：删了之后用户拿到的是 401「登录已过期」，会被客户端当成普通掉线，
   * 用户不知道为什么。保留会话时账号服务的 requireUser 会稳定返回 403 ACCOUNT_DISABLED，
   * 客户端才能如实提示「账号已被停用」。安全性不依赖删会话 —— 每条需要登录的接口
   * 都会先查 isUserDisabled，登录接口也会重新校验。
   * @returns {{ user: object, sessionsCleared: number }}
   */
  setDisabled(userId, disabled, reason) {
    const db = this.requireDb();
    const id = String(userId);
    const existing = this.find(id);
    if (!existing) throw new UserAdminError('用户不存在：' + id, 'NOT_FOUND', 404);

    const now = this.now();
    db.prepare(
      `INSERT INTO user_admin (user_id, disabled_at, disabled_reason, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(user_id) DO UPDATE SET
         disabled_at = excluded.disabled_at,
         disabled_reason = excluded.disabled_reason,
         updated_at = excluded.updated_at`
    ).run(id, disabled ? now : null, disabled ? String(reason || '').slice(0, 200) : null, now);
    return { user: this.get(id), sessionsCleared: 0 };
  }

  /**
   * 重置密码（运维给用户一个临时密码）。只换哈希与 salt，并清掉旧会话，
   * 让「密码已重置」这件事在所有设备上立刻生效。
   */
  resetPassword(userId, password) {
    const db = this.requireDb();
    const id = String(userId);
    const existing = this.find(id);
    if (!existing) throw new UserAdminError('用户不存在：' + id, 'NOT_FOUND', 404);
    if (typeof password !== 'string') {
      throw new UserAdminError('password 必须是字符串', 'BAD_REQUEST', 400);
    }
    if (password.length < PASSWORD_MIN_LENGTH || password.length > PASSWORD_MAX_LENGTH) {
      throw new UserAdminError(
        '密码需要 ' + PASSWORD_MIN_LENGTH + '–' + PASSWORD_MAX_LENGTH + ' 位',
        'BAD_REQUEST',
        400
      );
    }
    const hashed = hashPassword(password);
    let sessionsCleared = 0;
    db.exec('BEGIN');
    try {
      db.prepare('UPDATE users SET pass_hash = ?, pass_salt = ? WHERE id = ?')
        .run(hashed.hash, hashed.salt, id);
      sessionsCleared = Number(db.prepare('DELETE FROM sessions WHERE user_id = ?').run(id).changes);
      db.exec('COMMIT');
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
    return { user: this.get(id), sessionsCleared };
  }

  /**
   * 删除账号。级联口径与账号服务 deleteUserCascade 一致：
   * users / profiles / sessions / identities / place_photos / user_admin 一起清掉。
   * 用户埋下的惊喜保留（别人可能已经找到，突然消失会让寻者困惑）。
   */
  remove(userId) {
    const db = this.requireDb();
    const id = String(userId);
    const existing = this.find(id);
    if (!existing) throw new UserAdminError('用户不存在：' + id, 'NOT_FOUND', 404);

    db.exec('BEGIN');
    try {
      const counts = {
        profiles: Number(db.prepare('DELETE FROM profiles WHERE user_id = ?').run(id).changes),
        sessions: Number(db.prepare('DELETE FROM sessions WHERE user_id = ?').run(id).changes),
        identities: Number(db.prepare('DELETE FROM identities WHERE user_id = ?').run(id).changes),
        photos: Number(db.prepare('DELETE FROM place_photos WHERE user_id = ?').run(id).changes),
        admin: Number(db.prepare('DELETE FROM user_admin WHERE user_id = ?').run(id).changes),
        users: Number(db.prepare('DELETE FROM users WHERE id = ?').run(id).changes)
      };
      db.exec('COMMIT');
      return { ok: true, removed: counts, username: existing.username, surprisesKept: existing.surpriseCount };
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  }

  close() {
    if (this.db) {
      try { this.db.close(); } catch (_) { /* 忽略 */ }
      this.db = null;
    }
  }
}
