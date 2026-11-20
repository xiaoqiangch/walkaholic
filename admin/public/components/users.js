/* 步迷 · 兴趣点后台 — 用户账号管理面板
 *
 * 为什么单独一个文件：和 settings.js 一样，admin.js 已经两千多行。
 * 约定：
 *   - 依赖 window.WAUI / window.WAAPI
 *   - admin.js 里 data-action="users" 调 WAUsers.open()
 *   - 表格 + 行内操作，不弹二级页面：运维日常是「搜一个人 → 停用/重置/删除」
 */
(function () {
  'use strict';

  const UI = window.WAUI;
  const API = window.WAAPI;

  const state = {
    open: false,
    loading: false,
    data: null,
    error: '',
    filter: 'all',
    q: '',
    busyId: '',
    status: null
  };

  let panel = null;
  let body = null;

  function errorText(error) {
    if (!error) return '未知错误';
    const code = error.code && error.code !== 'HTTP_500' ? '（' + error.code + '）' : '';
    return (error.message || String(error)) + code;
  }

  function bytesLabel(bytes) {
    if (!bytes) return '—';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1024 / 1024).toFixed(2) + ' MB';
  }

  function providerLabel(provider) {
    return ({ password: '密码', wechat: '微信', apple: 'Apple', phone: '手机号' })[provider] || provider;
  }

  function renderTabs(data) {
    const counts = (data && data.counts) || {};
    const tabs = [
      { id: 'all', label: '全部', count: counts.all || 0 },
      { id: 'active', label: '正常', count: counts.active || 0 },
      { id: 'disabled', label: '已停用', count: counts.disabled || 0 }
    ].map(function (tab) {
      return '<button type="button" class="surprise__tab' + (state.filter === tab.id ? ' is-on' : '') +
        '" data-users-filter="' + tab.id + '">' + UI.escapeHtml(tab.label) +
        '<span>' + tab.count + '</span></button>';
    }).join('');

    return '<div class="surprise__toolbar">' +
      '<div class="surprise__tabs" role="tablist">' + tabs + '</div>' +
      '<input class="input surprise__search" id="users-search" type="search" ' +
        'placeholder="搜用户名 / 用户 ID" value="' + UI.escapeHtml(state.q) + '" aria-label="搜索用户">' +
    '</div>';
  }

  function rowHtml(user) {
    const busy = state.busyId === user.id;
    const disabled = !!user.disabledAt;
    // 只有密码注册的用户没有 identities 记录；微信 / Apple / 手机号登录都会留一条绑定
    const providers = user.providers.length
      ? user.providers.map(providerLabel).join('、')
      : '密码';
    const actions = disabled
      ? '<button type="button" class="btn btn--sm" data-users-enable="' + UI.escapeHtml(user.id) + '"' +
        (busy ? ' disabled' : '') + '>恢复</button>'
      : '<button type="button" class="btn btn--sm btn--danger" data-users-disable="' + UI.escapeHtml(user.id) + '"' +
        (busy ? ' disabled' : '') + '>停用</button>';
    return '<tr class="' + (disabled ? 'is-disabled' : '') + '" data-user-id="' + UI.escapeHtml(user.id) + '">' +
      '<td>' +
        '<p class="users__name">' + UI.escapeHtml(user.username) +
          (disabled ? ' <span class="surprise__pill is-hidden">已停用</span>' : '') + '</p>' +
        '<p class="users__id" title="' + UI.escapeHtml(user.id) + '">' + UI.escapeHtml(user.id) + '</p>' +
        (disabled && user.disabledReason
          ? '<p class="users__id">停用原因：' + UI.escapeHtml(user.disabledReason) + '</p>'
          : '') +
      '</td>' +
      '<td class="users__num">' + UI.escapeHtml(UI.formatTime(user.createdAt)) + '</td>' +
      '<td>' + UI.escapeHtml(providers) + '</td>' +
      '<td class="users__num">' + bytesLabel(user.profileBytes) + '</td>' +
      '<td class="users__num">' + user.sessionCount + '</td>' +
      '<td class="users__num">' + user.surpriseCount + ' / ' + user.photoCount + '</td>' +
      '<td class="users__ops">' +
        actions +
        '<button type="button" class="btn btn--sm" data-users-password="' + UI.escapeHtml(user.id) + '"' +
          (busy ? ' disabled' : '') + '>重置密码</button>' +
        '<button type="button" class="btn btn--sm btn--ghost" data-users-delete="' + UI.escapeHtml(user.id) +
          '" data-users-name="' + UI.escapeHtml(user.username) + '"' + (busy ? ' disabled' : '') + '>删除</button>' +
      '</td>' +
    '</tr>';
  }

  function render() {
    if (!body) return;
    if (state.loading && !state.data) {
      body.innerHTML = '<p class="mapkeys__loading">正在读取用户账号…</p>';
      return;
    }
    if (state.error) {
      body.innerHTML = '<p class="mapkeys__err">读取失败：' + UI.escapeHtml(state.error) + '</p>' +
        '<p class="mapkeys__help">若提示「账号库不存在」，检查账号服务的 WA_DATA_DIR，' +
        '或用 WA_ACCOUNT_DB 显式指定 walkaholic-users.db 的路径。</p>';
      return;
    }

    const data = state.data || { items: [], total: 0, counts: {} };
    const rows = data.items.length
      ? data.items.map(rowHtml).join('')
      : '<tr><td colspan="7"><div class="empty"><p class="empty__title">没有匹配的用户</p>' +
        '<p class="empty__sub">换个关键词，或切到「全部」。</p></div></td></tr>';

    body.innerHTML =
      '<div class="mapkeys__note">' + UI.icon('alert', 14) +
        '<span><strong>停用</strong>后该账号所有需要登录的接口都会返回 403（客户端会提示「账号已被停用」），' +
        '但数据保留；<strong>重置密码</strong>会清掉全部会话，用户需要用新密码重新登录；' +
        '<strong>删除</strong>会级联清掉资料、会话、登录绑定与到达照片，用户埋下的惊喜保留给寻者。</span>' +
      '</div>' +
      renderTabs(data) +
      '<div class="users__scroll">' +
        '<table class="users__table">' +
          '<thead><tr>' +
            '<th>用户</th><th>注册时间</th><th>登录方式</th><th>资料</th>' +
            '<th>会话</th><th>惊喜 / 照片</th><th>操作</th>' +
          '</tr></thead>' +
          '<tbody>' + rows + '</tbody>' +
        '</table>' +
      '</div>' +
      '<footer class="mapkeys__foot"><span class="mapkeys__public">共 ' + data.total + ' 个用户' +
        (data.total > data.items.length ? '（显示前 ' + data.items.length + ' 个）' : '') + '</span></footer>';
  }

  async function load() {
    state.loading = true;
    state.error = '';
    render();
    try {
      state.data = await API.users({ filter: state.filter, q: state.q, limit: 100 });
      state.status = null;
    } catch (error) {
      state.error = errorText(error);
      state.data = null;
    } finally {
      state.loading = false;
      render();
    }
  }

  /** 弹一个「输入一行文本」的弹层；确认返回字符串，取消返回 null。
   *  不用 window.prompt：阻塞式弹窗在部分浏览器里被禁用，也没法写说明文字。 */
  function askText(options) {
    const opts = options || {};
    return new Promise(function (resolve) {
      let settled = false;
      const handle = UI.openModal({
        title: opts.title || '输入',
        subtitle: opts.subtitle || '',
        bodyHTML:
          '<div class="field">' +
            '<label class="field__label" for="ask-input">' + UI.escapeHtml(opts.label || '') + '</label>' +
            '<input class="input" id="ask-input" type="' + (opts.password ? 'password' : 'text') + '"' +
              ' autocomplete="off" spellcheck="false" value="' + UI.escapeHtml(opts.value || '') + '"' +
              ' placeholder="' + UI.escapeHtml(opts.placeholder || '') + '">' +
            (opts.help ? '<p class="field__hint">' + UI.escapeHtml(opts.help) + '</p>' : '') +
          '</div>',
        footerHTML:
          '<button type="button" class="btn" data-act="cancel">取消</button>' +
          '<div class="spacer"></div>' +
          '<button type="button" class="btn btn--primary" data-act="ok">' +
            UI.escapeHtml(opts.confirmText || '确定') + '</button>'
      });
      const input = handle.body.querySelector('#ask-input');
      function done(value) {
        if (settled) return;
        settled = true;
        handle.close(true);
        resolve(value);
      }
      handle.foot.querySelector('[data-act="cancel"]').addEventListener('click', function () { done(null); });
      handle.foot.querySelector('[data-act="ok"]').addEventListener('click', function () {
        done(input ? input.value : '');
      });
      if (input) {
        input.addEventListener('keydown', function (event) {
          if (event.key === 'Enter') {
            event.preventDefault();
            done(input.value);
          }
        });
      }
      handle.onClose = function () { done(null); };
    });
  }

  async function toggle(userId, disabled, button) {
    let reason = '';
    if (disabled) {
      const ok = await UI.confirmDialog({
        title: '停用这个账号？',
        message: '停用后该账号无法登录，也不能同步资料（所有接口返回 403）。数据不会删除，随时可以恢复。',
        confirmText: '继续',
        danger: true
      });
      if (!ok) return;
      const input = await askText({
        title: '停用原因',
        label: '原因（只给管理员看，可留空）',
        placeholder: '例如：批量刷分 / 用户要求注销',
        confirmText: '停用'
      });
      if (input === null) return;
      reason = input;
    }
    UI.setBusy(button, true, disabled ? '停用中…' : '恢复中…');
    state.busyId = userId;
    try {
      const result = await API.setUserDisabled(userId, disabled, reason);
      UI.toast(disabled ? '已停用 ' + result.user.username : '已恢复 ' + result.user.username, 'success', 2400);
      // 切换后如果这个人不在当前分类里（在「已停用」点恢复 / 在「正常」点停用），
      // 列表会变成空的，看起来像操作失败。切回「全部」，让用户看到刚改完的那一行。
      if ((!disabled && state.filter === 'disabled') || (disabled && state.filter === 'active')) {
        state.filter = 'all';
      }
      await load();
    } catch (error) {
      UI.toast('操作失败：' + errorText(error), 'error', 5200);
    } finally {
      state.busyId = '';
      render();
    }
  }

  async function resetPassword(userId, username, button) {
    const password = await askText({
      title: '重置 ' + username + ' 的密码',
      label: '新密码（6–128 位）',
      placeholder: '通过其它渠道告诉用户',
      password: true,
      confirmText: '下一步'
    });
    if (password === null) return;
    if (password.length < 6) {
      UI.toast('密码至少 6 位', 'error', 3000);
      return;
    }
    const ok = await UI.confirmDialog({
      title: '重置密码？',
      message: '重置后该用户全部设备上的会话都会失效，需要用新密码重新登录。请通过其它渠道把新密码告诉用户。',
      confirmText: '重置',
      danger: true
    });
    if (!ok) return;
    UI.setBusy(button, true, '重置中…');
    state.busyId = userId;
    try {
      await API.resetUserPassword(userId, password);
      UI.toast(username + ' 的密码已重置，会话已全部失效', 'success', 4200);
      await load();
    } catch (error) {
      UI.toast('重置失败：' + errorText(error), 'error', 5200);
    } finally {
      state.busyId = '';
      render();
    }
  }

  async function removeUser(userId, username, button) {
    const ok = await UI.confirmDialog({
      title: '删除 ' + username + '？',
      message: '会级联删除该账号的资料、会话、登录绑定与到达照片，不可恢复。' +
        '他埋下的惊喜会保留（别人可能已经找到）。',
      confirmText: '彻底删除',
      danger: true
    });
    if (!ok) return;
    UI.setBusy(button, true, '删除中…');
    state.busyId = userId;
    try {
      const result = await API.removeUser(userId);
      UI.toast('已删除 ' + result.username +
        '（保留 ' + result.surprisesKept + ' 条惊喜）', 'success', 4200);
      await load();
    } catch (error) {
      UI.toast('删除失败：' + errorText(error), 'error', 5200);
    } finally {
      state.busyId = '';
      render();
    }
  }

  function open() {
    if (!panel) return;
    state.open = true;
    panel.hidden = false;
    load();
  }

  function close() {
    if (!panel) return;
    state.open = false;
    panel.hidden = true;
  }

  function bind() {
    panel = document.getElementById('users-panel');
    body = document.getElementById('users-body');
    if (!panel || !body) return;

    panel.addEventListener('click', function (event) {
      if (event.target.closest('[data-users-close]')) {
        close();
        return;
      }
      const tab = event.target.closest('[data-users-filter]');
      if (tab) {
        state.filter = tab.getAttribute('data-users-filter');
        load();
        return;
      }
      const disableBtn = event.target.closest('[data-users-disable]');
      if (disableBtn) {
        toggle(disableBtn.getAttribute('data-users-disable'), true, disableBtn);
        return;
      }
      const enableBtn = event.target.closest('[data-users-enable]');
      if (enableBtn) {
        toggle(enableBtn.getAttribute('data-users-enable'), false, enableBtn);
        return;
      }
      const passwordBtn = event.target.closest('[data-users-password]');
      if (passwordBtn) {
        const id = passwordBtn.getAttribute('data-users-password');
        const row = state.data && state.data.items
          ? state.data.items.filter(function (u) { return u.id === id; })[0]
          : null;
        resetPassword(id, row ? row.username : id, passwordBtn);
        return;
      }
      const deleteBtn = event.target.closest('[data-users-delete]');
      if (deleteBtn) {
        removeUser(
          deleteBtn.getAttribute('data-users-delete'),
          deleteBtn.getAttribute('data-users-name') || '',
          deleteBtn
        );
      }
    });

    body.addEventListener('input', UI.debounce(function (event) {
      if (event.target && event.target.id === 'users-search') {
        state.q = event.target.value.trim();
        load();
      }
    }, 350));

    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && state.open) close();
    });
  }

  window.WAUsers = { open: open, close: close, bind: bind };
})();
