(function () {
  'use strict';

  var state = {
    catalog: null,
    filter: 'all',
    source: null,
    query: '',
    selectedId: null,
    loading: false,
    lastError: null,
    newIds: Object.create(null),
    poll: null
  };

  var $ = function (id) { return document.getElementById(id); };

  var app = $('app');
  var list = $('list');
  var search = $('search');
  var clearBtn = $('btn-clear');
  var refreshBtn = $('btn-refresh');
  var detail = $('detail');
  var detailEmpty = $('detail-empty');
  var detailContent = $('detail-content');
  var detailClose = $('detail-close');
  var stampTimer = null;
  var scrim = $('scrim');
  var toasts = $('toasts');
  var dialog = $('body-dialog');
  var bodyTitle = $('body-title');
  var bodyPath = $('body-path');
  var bodyText = $('body-text');
  var live = $('live');
  var liveText = $('live-text');

  var SOURCE_EN = { user: 'USER', plugin: 'PLUGIN', builtin: 'BUILTIN', agents: 'AGENTS' };
  var SOURCE_LABEL = { user: '用户目录', plugin: '插件附带', builtin: '内置', agents: '通用目录' };

  /* ------------------------------------------------------------ helpers */

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function highlight(text, query) {
    var source = String(text == null ? '' : text);
    if (!query) return esc(source);
    var lower = source.toLowerCase();
    var needle = query.toLowerCase();
    var out = '';
    var from = 0;
    while (from < source.length) {
      var at = lower.indexOf(needle, from);
      if (at < 0) { out += esc(source.slice(from)); break; }
      out += esc(source.slice(from, at));
      out += '<mark>' + esc(source.slice(at, at + needle.length)) + '</mark>';
      from = at + needle.length;
    }
    return out || esc(source);
  }

  function fmtBytes(bytes) {
    if (!bytes || bytes < 0) return '—';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
  }

  function pad2(n) { return n < 10 ? '0' + n : String(n); }

  function fmtDate(ms) {
    if (!ms || ms < 0) return '—';
    var d = new Date(ms);
    return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
      ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  }

  function fmtClock(ms) {
    var d = ms ? new Date(ms) : new Date();
    return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
  }

  function relative(ms) {
    if (!ms || ms < 0) return '从未';
    var diff = Date.now() - ms;
    if (diff < 45000) return '刚刚';
    if (diff < 3600000) return Math.max(1, Math.round(diff / 60000)) + ' 分钟前';
    if (diff < 86400000) return Math.round(diff / 3600000) + ' 小时前';
    if (diff < 2592000000) return Math.round(diff / 86400000) + ' 天前';
    return fmtDate(ms).slice(0, 10);
  }

  function isTyping(el) {
    if (!el) return false;
    var tag = (el.tagName || '').toLowerCase();
    return tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable;
  }

  function allEntries(catalog) {
    return (catalog.plugins || []).concat(catalog.skills || []);
  }

  function findEntry(id) {
    if (!id || !state.catalog) return null;
    var all = allEntries(state.catalog);
    for (var i = 0; i < all.length; i++) if (all[i].id === id) return all[i];
    return null;
  }

  function skillById(id) {
    if (!state.catalog) return null;
    var skills = state.catalog.skills || [];
    for (var i = 0; i < skills.length; i++) if (skills[i].id === id) return skills[i];
    return null;
  }

  function matches(entry, q) {
    if (!q) return true;
    var hay = [
      entry.name, entry.label, entry.rowTitle, entry.summary, entry.description,
      entry.sourceLabel, entry.pluginLabel, entry.plugin, entry.version,
      (entry.tags || []).join(' ')
    ].join(' ').toLowerCase();
    return hay.indexOf(q) >= 0;
  }

  function filteredGroups() {
    if (!state.catalog) return [];
    var q = state.query.toLowerCase();
    var groups = [];

    if (state.filter === 'all' || state.filter === 'plugin') {
      var plugins = (state.catalog.plugins || []).filter(function (p) { return matches(p, q); });
      if (plugins.length) groups.push({ key: 'plugin', name: '插件', en: 'PLUGINS', entries: plugins });
    }

    if (state.filter === 'all' || state.filter === 'skill') {
      var sources = state.source ? [state.source] : ['user', 'plugin', 'builtin', 'agents'];
      sources.forEach(function (source) {
        var skills = (state.catalog.skills || []).filter(function (s) {
          return s.source === source && matches(s, q);
        });
        if (!skills.length) return;
        groups.push({
          key: 'skill-' + source,
          name: '技能 · ' + (SOURCE_LABEL[source] || source),
          en: SOURCE_EN[source] || source,
          entries: skills
        });
      });
    }

    groups.forEach(function (group) {
      group.entries.sort(function (a, b) {
        return String(a.label || a.name).localeCompare(String(b.label || b.name), 'zh-Hans-CN');
      });
    });
    return groups;
  }

  /* ------------------------------------------------------------ fetch */

  function setLive(ok) {
    live.classList.toggle('is-live', ok);
    live.classList.toggle('is-down', !ok);
    liveText.textContent = ok ? '实时 · 已连接' : '连接中断 · 重试中';
  }

  async function loadCatalog(manual) {
    if (state.loading) return;
    state.loading = true;
    if (manual) refreshBtn.classList.add('is-busy');
    try {
      var res = await fetch('/api/catalog', { cache: 'no-store' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      var data = await res.json();
      var previous = state.catalog;
      state.catalog = data;

      if (!previous) {
        state.lastError = null;
        renderAll();
      } else if (previous.revision !== data.revision) {
        var before = Object.create(null);
        allEntries(previous).forEach(function (e) { before[e.id] = e; });
        var after = Object.create(null);
        allEntries(data).forEach(function (e) { after[e.id] = e; });

        var added = Object.keys(after).filter(function (id) { return !before[id]; });
        var removed = Object.keys(before).filter(function (id) { return !after[id]; });
        added.forEach(function (id) { state.newIds[id] = true; });
        renderAll();
        added.forEach(function (id) {
          var item = after[id];
          toast(item.type === 'plugin' ? '发现新插件' : '发现新技能', item.label || item.name);
          setTimeout(function () {
            delete state.newIds[id];
            var row = findRow(id);
            if (row) row.classList.remove('is-new');
          }, 12000);
        });
        removed.forEach(function (id) {
          var item = before[id];
          toast(item.type === 'plugin' ? '插件已移除' : '技能已移除', item.label || item.name);
        });
        if (!added.length && !removed.length) toast('索引已更新', '文件内容或调用记录发生变化');
      } else {
        renderStatus();
      }

      setLive(true);
      state.lastError = null;
    } catch (error) {
      setLive(false);
      state.lastError = error;
      if (!state.catalog) renderError(error);
      else toast('同步失败', '将在 3 秒后重试');
    } finally {
      state.loading = false;
      refreshBtn.classList.remove('is-busy');
    }
  }

  /* ------------------------------------------------------------ render */

  function renderAll() {
    if (!state.catalog) return;
    renderCounts();
    renderStatus();
    renderList();
    renderDetail();
  }

  function renderCounts() {
    var catalog = state.catalog;
    var totals = catalog.totals || {};
    $('count-all').textContent = totals.entries || 0;
    $('count-plugins').textContent = totals.plugins || 0;
    $('count-skills').textContent = totals.skills || 0;

    var bySource = {};
    (catalog.sources || []).forEach(function (s) { bySource[s.id] = s.count; });
    $('count-user').textContent = bySource.user || 0;
    $('count-plugin-skills').textContent = bySource.plugin || 0;
    $('count-builtin').textContent = bySource.builtin || 0;
    $('count-agents').textContent = bySource.agents || 0;
    var agentsBtn = $('source-agents');
    if (agentsBtn) agentsBtn.hidden = !bySource.agents;
    $('total-count').textContent = totals.entries || 0;

    var plateCount = $('plate-count');
    if (plateCount) plateCount.textContent = String(totals.entries || 0).padStart(2, '0');
  }

  function renderStatus() {
    if (!state.catalog) return;
    $('meta-rev').textContent = String(state.catalog.revision || '—').slice(0, 8);
    $('meta-updated').textContent = fmtClock();
    $('meta-dsh').textContent = (state.catalog.dsh && state.catalog.dsh.profile) || '—';
  }

  function renderList() {
    var groups = filteredGroups();
    var scrollTop = list.scrollTop;
    var focusedId = document.activeElement && document.activeElement.closest
      ? (document.activeElement.closest('.row') || {}).dataset
      : null;
    focusedId = focusedId ? focusedId.id : null;

    var totalVisible = groups.reduce(function (sum, g) { return sum + g.entries.length; }, 0);
    $('visible-count').textContent = totalVisible;

    if (!totalVisible) {
      var label = state.query ? '没有匹配「' + esc(state.query) + '」的条目' : '这个筛选下没有条目';
      list.innerHTML =
        '<div class="empty-result">' +
          '<h3>' + (state.query ? '没有匹配项' : '没有条目') + '</h3>' +
          '<p>' + label + '</p>' +
          '<button class="btn" type="button" id="empty-reset">清除筛选</button>' +
        '</div>';
      var reset = $('empty-reset');
      if (reset) reset.addEventListener('click', resetFilters);
      return;
    }

    var html = '';
    var index = 0;
    groups.forEach(function (group) {
      html += '<div class="group-head" role="presentation">' +
        '<span class="group-name">' + esc(group.name) + '</span>' +
        '<span class="group-en">' + esc(group.en) + '</span>' +
        '<span class="group-line"></span>' +
        '<span class="group-count">' + String(group.entries.length).padStart(2, '0') + '</span>' +
        '</div>';

      group.entries.forEach(function (entry) {
        index += 1;
        var selected = entry.id === state.selectedId;
        var isNew = !!state.newIds[entry.id];
        var chips = '';
        if (isNew) chips += '<span class="chip chip-new">NEW</span>';
        if (entry.type === 'plugin') {
          if (entry.version) chips += '<span class="chip chip-version">v' + esc(entry.version) + '</span>';
        } else {
          chips += '<span class="chip">' + esc(SOURCE_EN[entry.source] || 'SKILL') + '</span>';
        }
        if (entry.disabled) chips += '<span class="chip chip-off">停用</span>';

        var showName = entry.name && String(entry.name).toLowerCase() !== String(entry.label || '').toLowerCase();
        html += '<button class="row' + (selected ? ' is-selected' : '') + (isNew ? ' is-new' : '') + '"' +
          ' type="button" role="option" aria-selected="' + (selected ? 'true' : 'false') + '"' +
          ' tabindex="' + (selected ? '0' : '-1') + '"' +
          ' data-id="' + esc(entry.id) + '"' +
          ' title="' + esc(entry.label || entry.name) + '">' +
          '<span class="row-no">' + String(index).padStart(2, '0') + '</span>' +
          '<span class="row-main">' +
            '<span class="row-title">' + highlight(entry.label || entry.name, state.query) + '</span>' +
            (showName ? '<span class="row-name">' + highlight(entry.name, state.query) + '</span>' : '') +
          '</span>' +
          '<span class="row-summary">' + highlight(entry.summary || '', state.query) + '</span>' +
          '<span class="row-meta">' + chips + '</span>' +
        '</button>';
      });
    });

    list.innerHTML = html;
    list.scrollTop = scrollTop;

    if (focusedId) {
      var rows = list.querySelectorAll('.row');
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].dataset.id === focusedId) { rows[i].focus(); break; }
      }
    }
  }

  function findRow(id) {
    var rows = list.querySelectorAll('.row');
    for (var i = 0; i < rows.length; i++) if (rows[i].dataset.id === id) return rows[i];
    return null;
  }

  function renderDetail() {
    var entry = findEntry(state.selectedId);
    if (!entry) {
      detailEmpty.hidden = false;
      detailContent.hidden = true;
      paintPaper();
      closeDrawer();
      return;
    }

    detailEmpty.hidden = true;
    detailContent.hidden = false;

    var isPlugin = entry.type === 'plugin';
    $('d-kicker').textContent = (isPlugin ? 'PLUGIN' : 'SKILL') + ' / ' +
      (isPlugin ? (entry.kind || 'COMMUNITY') : (SOURCE_EN[entry.source] || 'SKILL'));
    $('d-title').textContent = entry.label || entry.name;
    $('d-sub').textContent = entry.name + (isPlugin && entry.version ? ' · v' + entry.version : '');
    $('d-summary').textContent = entry.summary || entry.description || '未提供说明。';
    $('d-desc').textContent = entry.description || entry.summary || '未提供说明。';

    var tagsWrap = $('d-tags');
    var tagsSection = $('d-tags-section');
    tagsWrap.textContent = '';
    var tags = entry.tags || [];
    tags.forEach(function (tag) {
      var span = document.createElement('span');
      span.className = 'tag';
      span.textContent = tag;
      tagsWrap.appendChild(span);
    });
    tagsSection.hidden = !tags.length;

    var bodyBtn = $('d-body');
    bodyBtn.hidden = isPlugin || !entry.hasBody;
    bodyBtn.onclick = function () { openBody(entry); };
    $('d-copy').onclick = function () { copyPath(entry.path); };

    var meta = $('d-meta');
    meta.textContent = '';
    if (isPlugin) {
      addMeta(meta, '包名', entry.name, 'mono');
      addMeta(meta, '版本', entry.version || '—');
      addMeta(meta, '来源', entry.kind || '—');
      addMeta(meta, '许可证', entry.license || '—');
      if (entry.homepage) addMetaLink(meta, '主页', entry.homepage);
      addMeta(meta, '位置', entry.path, 'mono');
      addMeta(meta, '更新', fmtDate(entry.updatedAt));
      addMeta(meta, '提供技能', String((entry.skillIds || []).length) + ' 个');
      addMeta(meta, '调用记录', entry.uses ? entry.uses + ' 次 · 最近 ' + relative(entry.lastUsed) : '尚未调用');
    } else {
      addMeta(meta, '标识', entry.name, 'mono');
      addMeta(meta, '来源', entry.sourceLabel || '—');
      if (entry.plugin) addMeta(meta, '所属插件', entry.plugin, 'mono');
      addMeta(meta, '位置', entry.path, 'mono');
      addMeta(meta, '文件大小', fmtBytes(entry.size));
      addMeta(meta, '更新', fmtDate(entry.updatedAt));
      addMeta(meta, '调用记录', entry.uses ? entry.uses + ' 次 · 最近 ' + relative(entry.lastUsed) : '尚未调用');
      addMeta(meta, '状态', entry.disabled ? '已停用' : '启用');
    }

    var relatedSection = $('d-skills-section');
    var related = $('d-skills');
    related.textContent = '';
    var relatedIds = isPlugin ? (entry.skillIds || []) : [];
    if (relatedIds.length) {
      relatedIds.forEach(function (id) {
        var skill = skillById(id);
        if (!skill) return;
        var button = document.createElement('button');
        button.type = 'button';
        button.innerHTML = '<span class="related-name">' + esc(skill.label || skill.name) + '</span>' +
          '<span class="related-meta">' + esc(skill.name) + ' →</span>';
        button.addEventListener('click', function () { selectItem(skill.id, true); });
        related.appendChild(button);
      });
      relatedSection.hidden = false;
    } else {
      relatedSection.hidden = true;
    }

    if (state.selectedId && window.matchMedia('(max-width: 1120px)').matches) {
      app.classList.add('detail-open');
      scrim.hidden = false;
    }
    paintPaper();
  }

  /* The right leaf is paper; set ink inline so a stale stylesheet can never
     leave white-on-cream text after an update. */
  function paintPaper() {
    var ink = '#17130f';
    var soft = '#3a352d';
    var muted = '#6b6458';
    var clay = '#c4573f';
    function color(id, value) {
      var el = $(id);
      if (el) el.style.setProperty('color', value, 'important');
    }
    color('d-title', ink);
    color('d-sub', muted);
    color('d-kicker', clay);
    color('d-summary', ink);
    color('d-desc', soft);

    var body = $('d-body');
    if (body) {
      body.style.background = clay;
      body.style.borderColor = clay;
      body.style.color = '#fff8ef';
    }
    var copy = $('d-copy');
    if (copy) {
      copy.style.background = 'transparent';
      copy.style.borderColor = 'rgba(25,21,17,.24)';
      copy.style.color = ink;
    }
    var close = $('detail-close');
    if (close) {
      close.style.background = 'transparent';
      close.style.borderColor = 'rgba(25,21,17,.24)';
      close.style.color = ink;
    }

    var tags = $('d-tags');
    if (tags) {
      Array.prototype.forEach.call(tags.querySelectorAll('.tag'), function (tag) {
        tag.style.background = 'rgba(25,21,17,.05)';
        tag.style.borderColor = 'rgba(25,21,17,.16)';
        tag.style.color = ink;
      });
    }

    var meta = $('d-meta');
    if (meta) {
      Array.prototype.forEach.call(meta.querySelectorAll('dt'), function (dt) { dt.style.color = muted; });
      Array.prototype.forEach.call(meta.querySelectorAll('dd'), function (dd) { dd.style.color = ink; });
      Array.prototype.forEach.call(meta.querySelectorAll('dd.mono'), function (dd) { dd.style.color = soft; });
      Array.prototype.forEach.call(meta.querySelectorAll('dd a'), function (a) { a.style.color = clay; });
    }

    Array.prototype.forEach.call(document.querySelectorAll('#detail-content .section-title'), function (title) {
      title.style.color = muted;
    });
    Array.prototype.forEach.call(document.querySelectorAll('#d-skills .related-name'), function (name) {
      name.style.color = ink;
    });
    Array.prototype.forEach.call(document.querySelectorAll('#d-skills .related-meta'), function (note) {
      note.style.color = muted;
    });

    Array.prototype.forEach.call(document.querySelectorAll('#detail-empty h2, #plate-count'), function (el) {
      el.style.color = ink;
    });
    Array.prototype.forEach.call(document.querySelectorAll('#detail-empty .empty-copy, #detail-empty .empty-meta dt, .plate-caption, .plate-cap'), function (el) {
      el.style.color = muted;
    });
    Array.prototype.forEach.call(document.querySelectorAll('#detail-empty .empty-meta dd'), function (el) {
      el.style.color = ink;
    });
    var plate = document.querySelector('.plate');
    if (plate) plate.style.color = ink;
  }

  function addMeta(dl, label, value, className) {
    var row = document.createElement('div');
    var dt = document.createElement('dt');
    dt.textContent = label;
    var dd = document.createElement('dd');
    if (className) dd.className = className;
    dd.textContent = value == null ? '—' : value;
    row.appendChild(dt);
    row.appendChild(dd);
    dl.appendChild(row);
  }

  function addMetaLink(dl, label, url) {
    var row = document.createElement('div');
    var dt = document.createElement('dt');
    dt.textContent = label;
    var dd = document.createElement('dd');
    if (/^https?:\/\//i.test(url)) {
      var a = document.createElement('a');
      a.href = url;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      a.textContent = url;
      dd.appendChild(a);
    } else {
      dd.textContent = url;
    }
    row.appendChild(dt);
    row.appendChild(dd);
    dl.appendChild(row);
  }

  function renderError(error) {
    list.innerHTML =
      '<div class="error-state">' +
        '<h3>无法读取本机索引</h3>' +
        '<p>' + esc(error && error.message ? error.message : '本地服务没有响应') +
        '。请确认 Harness Index 服务仍在运行，然后重试。</p>' +
        '<button class="btn" type="button" id="retry">重试</button>' +
      '</div>';
    var retry = $('retry');
    if (retry) retry.addEventListener('click', function () { loadCatalog(true); });
  }

  /* ------------------------------------------------------------ interaction */

  function syncSelection() {
    var rows = list.querySelectorAll('.row');
    for (var i = 0; i < rows.length; i++) {
      var selected = rows[i].dataset.id === state.selectedId;
      rows[i].classList.toggle('is-selected', selected);
      rows[i].setAttribute('aria-selected', selected ? 'true' : 'false');
      rows[i].tabIndex = selected ? 0 : -1;
    }
  }

  function selectItem(id, scrollIntoView) {
    state.selectedId = id || null;
    syncSelection();
    renderDetail();
    if (detail) {
      detail.classList.remove('is-stamped');
      void detail.offsetWidth;
      detail.classList.add('is-stamped');
      clearTimeout(stampTimer);
      stampTimer = setTimeout(function () { detail.classList.remove('is-stamped'); }, 620);
    }
    if (scrollIntoView) {
      var row = findRow(id);
      if (row) row.scrollIntoView({ block: 'nearest' });
    }
  }

  function closeDrawer() {
    app.classList.remove('detail-open');
    scrim.hidden = true;
  }

  function resetFilters() {
    state.filter = 'all';
    state.source = null;
    state.query = '';
    search.value = '';
    clearBtn.hidden = true;
    document.querySelectorAll('[data-filter]').forEach(function (btn) {
      var active = btn.dataset.filter === 'all';
      btn.setAttribute('aria-pressed', active ? 'true' : 'false');
      btn.classList.toggle('is-active', active);
    });
    document.querySelectorAll('[data-source]').forEach(function (btn) {
      btn.setAttribute('aria-pressed', 'false');
    });
    renderList();
  }

  function toast(title, sub) {
    var item = document.createElement('div');
    item.className = 'toast';
    item.innerHTML = '<span class="toast-copy"><span class="toast-title">' + esc(title) + '</span>' +
      (sub ? '<span class="toast-sub">' + esc(sub) + '</span>' : '') + '</span>';
    toasts.appendChild(item);
    while (toasts.children.length > 4) toasts.removeChild(toasts.firstChild);
    setTimeout(function () {
      item.classList.add('is-out');
      setTimeout(function () { if (item.parentNode) item.parentNode.removeChild(item); }, 220);
    }, 4600);
  }

  async function copyPath(path) {
    if (!path) return;
    try {
      await navigator.clipboard.writeText(path);
    } catch (error) {
      var area = document.createElement('textarea');
      area.value = path;
      area.setAttribute('readonly', 'readonly');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      try { document.execCommand('copy'); } catch (e) { }
      document.body.removeChild(area);
    }
    toast('路径已复制', path);
  }

  async function openBody(entry) {
    bodyTitle.textContent = entry.name;
    bodyPath.textContent = entry.path;
    bodyText.textContent = '正在读取…';
    if (!dialog.open) dialog.showModal();
    try {
      var res = await fetch('/api/body?id=' + encodeURIComponent(entry.id), { cache: 'no-store' });
      var data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || ('HTTP ' + res.status));
      bodyText.textContent = data.text || '（空文件）';
    } catch (error) {
      bodyText.textContent = '读取失败：' + (error && error.message ? error.message : '未知错误');
    }
  }

  function moveFocus(delta) {
    var rows = Array.prototype.slice.call(list.querySelectorAll('.row'));
    if (!rows.length) return;
    var current = document.activeElement;
    var index = rows.indexOf(current);
    if (index < 0) {
      index = 0;
      rows[index].focus();
      return;
    }
    var next = Math.max(0, Math.min(rows.length - 1, index + delta));
    rows[next].focus();
    rows[next].scrollIntoView({ block: 'nearest' });
  }

  /* ------------------------------------------------------------ events */

  document.querySelectorAll('[data-filter]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      state.filter = btn.dataset.filter;
      state.source = null;
      document.querySelectorAll('[data-filter]').forEach(function (other) {
        var active = other === btn;
        other.setAttribute('aria-pressed', active ? 'true' : 'false');
        other.classList.toggle('is-active', active);
      });
      document.querySelectorAll('[data-source]').forEach(function (other) {
        other.setAttribute('aria-pressed', 'false');
      });
      renderList();
    });
  });

  document.querySelectorAll('[data-source]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var source = btn.dataset.source;
      var active = btn.getAttribute('aria-pressed') === 'true';
      state.filter = 'skill';
      state.source = active ? null : source;
      document.querySelectorAll('[data-source]').forEach(function (other) {
        other.setAttribute('aria-pressed', other === btn && !active ? 'true' : 'false');
      });
      document.querySelectorAll('[data-filter]').forEach(function (other) {
        var on = other.dataset.filter === 'skill';
        other.setAttribute('aria-pressed', on ? 'true' : 'false');
        other.classList.toggle('is-active', on);
      });
      renderList();
    });
  });

  var searchTimer = null;
  search.addEventListener('input', function () {
    clearTimeout(searchTimer);
    var value = search.value;
    clearBtn.hidden = !value;
    searchTimer = setTimeout(function () {
      state.query = value.trim();
      renderList();
    }, 90);
  });

  clearBtn.addEventListener('click', function () {
    search.value = '';
    clearBtn.hidden = true;
    state.query = '';
    renderList();
    search.focus();
  });

  list.addEventListener('click', function (event) {
    var row = event.target.closest && event.target.closest('.row');
    if (row) selectItem(row.dataset.id, false);
  });

  list.addEventListener('keydown', function (event) {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      moveFocus(event.key === 'ArrowDown' ? 1 : -1);
    } else if (event.key === 'Escape') {
      if (app.classList.contains('detail-open')) closeDrawer();
      else state.selectedId = null, syncSelection(), renderDetail();
    }
  });

  document.addEventListener('keydown', function (event) {
    if (event.key === '/' && !isTyping(event.target) && !dialog.open) {
      event.preventDefault();
      search.focus();
      search.select();
    }
    if (event.key === 'Escape' && !dialog.open) {
      if (app.classList.contains('detail-open')) closeDrawer();
      else if (state.query) {
        search.value = '';
        clearBtn.hidden = true;
        state.query = '';
        renderList();
      }
    }
  });

  detailClose.addEventListener('click', function () {
    closeDrawer();
    state.selectedId = null;
    syncSelection();
    renderDetail();
  });

  scrim.addEventListener('click', function () {
    closeDrawer();
  });

  refreshBtn.addEventListener('click', function () { loadCatalog(true); });

  dialog.addEventListener('click', function (event) {
    if (event.target === dialog) dialog.close();
  });
  $('body-close').addEventListener('click', function () { dialog.close(); });

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) loadCatalog(false);
  });

  /* ------------------------------------------------------------ boot */

  loadCatalog(false);
  state.poll = setInterval(function () {
    if (!document.hidden) loadCatalog(false);
  }, 3000);
})();
