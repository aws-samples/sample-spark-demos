// Demo inspector overlay — MIT-0 demo tooling, NOT part of the upstream
// product. Injected at the demo edge (ingress sub_filter); the upstream
// frontend image is byte-identical to its source.
//
// Tab "API Calls": patches fetch/XHR and lists every request the SPA makes
// against the SPARK API (method, service, path, status, duration).
// Tab "Backend": SSE stream from the inspector backend — LLM calls through
// LiteLLM (the Amazon Bedrock moment), RabbitMQ queues, CloudWatch Bedrock
// invocation counts.
//
// Everything the panel shows comes from untrusted sources (request URLs,
// model names, queue names, error messages from the backend), so the UI is
// built with DOM nodes and textContent only — no HTML string assembly.
(function () {
  'use strict';
  if (window.__sparkDemoInspector) return;
  window.__sparkDemoInspector = true;

  var MAX_ROWS = 200;
  var calls = [];
  var llmEvents = [];
  var rabbit = { queues: [] };
  var bedrock = { models: [] };
  var sourceErrors = {};
  var open = localStorage.getItem('sparkDemoInspector') === 'open';
  var activeTab = 'calls';
  var es = null;

  // ---- capture: fetch ------------------------------------------------------
  var origFetch = window.fetch;
  window.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var method = (init && init.method) || (typeof input === 'object' && input.method) || 'GET';
    var t0 = performance.now();
    var rec = track(method, url);
    return origFetch.apply(this, arguments).then(
      function (resp) { finish(rec, resp.status, t0); return resp; },
      function (err) { finish(rec, 0, t0); throw err; }
    );
  };

  // ---- capture: XHR --------------------------------------------------------
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__insp = { method: method, url: url };
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var self = this;
    if (self.__insp) {
      var t0 = performance.now();
      var rec = track(self.__insp.method, self.__insp.url);
      self.addEventListener('loadend', function () { finish(rec, self.status, t0); });
    }
    return origSend.apply(this, arguments);
  };

  function track(method, url) {
    try {
      var u = new URL(url, location.origin);
      if (u.origin !== location.origin) return null;
      if (u.pathname.indexOf('/demo-inspector') === 0) return null;
      if (u.pathname.indexOf('/oauth2') === 0) return null;
      var isApi = u.pathname.indexOf('/api/') === 0;
      var service = isApi ? u.pathname.split('/')[2] : '(frontend asset)';
      var rec = {
        time: new Date().toLocaleTimeString(),
        method: (method || 'GET').toUpperCase(),
        service: service,
        path: u.pathname + u.search,
        api: isApi,
        status: '…',
        ms: null,
      };
      calls.unshift(rec);
      if (calls.length > MAX_ROWS) calls.pop();
      scheduleRender();
      return rec;
    } catch (e) { return null; }
  }

  function finish(rec, status, t0) {
    if (!rec) return;
    rec.status = status || 'ERR';
    rec.ms = Math.round(performance.now() - t0);
    scheduleRender();
  }

  // ---- backend stream ------------------------------------------------------
  function connectStream() {
    if (es) return;
    es = new EventSource('/demo-inspector/events');
    es.onmessage = function (msg) {
      try {
        var ev = JSON.parse(msg.data);
        if (ev.type === 'llm') {
          llmEvents.unshift(ev);
          if (llmEvents.length > MAX_ROWS) llmEvents.pop();
        } else if (ev.type === 'rabbitmq') rabbit = ev;
        else if (ev.type === 'bedrock') bedrock = ev;
        else if (ev.type === 'source_error') sourceErrors[ev.source] = ev.message;
        if (ev.type !== 'source_error') delete sourceErrors[(ev.type === 'llm' && 'litellm') || ev.type];
        scheduleRender();
      } catch (e) { /* ignore */ }
    };
    es.onerror = function () { /* EventSource auto-reconnects */ };
  }

  // ---- UI ------------------------------------------------------------------
  // Static shell (styles + chrome). Constant markup, no data involved.
  var host = document.createElement('div');
  var root = host.attachShadow({ mode: 'open' });
  root.innerHTML =
    '<style>' +
    ':host{all:initial}' +
    '.btn{position:fixed;bottom:16px;right:16px;z-index:2147483000;background:#1a56db;color:#fff;' +
    'border:none;border-radius:20px;padding:10px 16px;font:600 13px system-ui;cursor:pointer;box-shadow:0 2px 10px rgba(0,0,0,.35)}' +
    '.panel{position:fixed;bottom:64px;right:16px;z-index:2147483000;width:620px;max-width:92vw;height:440px;' +
    'background:#0b1120;color:#e2e8f0;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.5);display:flex;flex-direction:column;font:12px ui-monospace,monospace;' +
    'resize:both;overflow:hidden;min-width:340px;min-height:36px}' +
    '.panel.min{height:36px !important;min-height:36px;resize:none}' +
    '.panel.min .body{display:none}' +
    '.hd{display:flex;align-items:center;gap:8px;padding:8px 12px;border-bottom:1px solid #1e293b;font:600 13px system-ui;cursor:move;user-select:none}' +
    '.tab{background:none;border:none;color:#94a3b8;padding:4px 10px;cursor:pointer;font:600 12px system-ui;border-radius:6px}' +
    '.tab.on{background:#1e293b;color:#fff}' +
    '.win{background:none;border:1px solid #334155;color:#94a3b8;width:22px;height:22px;border-radius:6px;cursor:pointer;font:600 12px system-ui}' +
    '.win:hover{color:#fff;border-color:#64748b}' +
    '.body{flex:1;overflow:auto;padding:6px 10px}' +
    'table{width:100%;border-collapse:collapse}td,th{padding:3px 6px;text-align:left;white-space:nowrap}' +
    'td.path{max-width:230px;overflow:hidden;text-overflow:ellipsis}' +
    'th{position:sticky;top:0;background:#0b1120;color:#64748b;font-weight:600}' +
    '.s2xx{color:#4ade80}.s3xx{color:#fbbf24}.s4xx,.s5xx,.sERR{color:#f87171}' +
    '.pill{display:inline-block;background:#172554;color:#93c5fd;border-radius:8px;padding:0 6px;margin-left:6px}' +
    '.sec{margin:10px 0 4px;color:#64748b;font:600 12px system-ui}' +
    '.err{color:#f87171;padding:2px 0}' +
    '.hint{color:#64748b;padding:8px 2px}' +
    '</style>' +
    '<button class="btn"></button>' +
    '<div class="panel" hidden>' +
    '  <div class="hd">SPARK API demo inspector' +
    '    <span style="flex:1"></span>' +
    '    <button class="tab" data-tab="calls">API Calls</button>' +
    '    <button class="tab" data-tab="backend">Backend</button>' +
    '    <button class="win" data-win="min" title="Collapse to title bar">–</button>' +
    '    <button class="win" data-win="close" title="Close">✕</button>' +
    '  </div>' +
    '  <div class="body"></div>' +
    '</div>';

  var btn = root.querySelector('.btn');
  var panel = root.querySelector('.panel');
  var body = root.querySelector('.body');
  var head = root.querySelector('.hd');
  var minimized = localStorage.getItem('sparkDemoInspectorMin') === '1';

  btn.addEventListener('click', function () {
    open = !open;
    localStorage.setItem('sparkDemoInspector', open ? 'open' : 'closed');
    sync();
  });
  root.querySelectorAll('.tab').forEach(function (t) {
    t.addEventListener('click', function () { activeTab = t.dataset.tab; render(); });
  });
  root.querySelector('[data-win="min"]').addEventListener('click', function (e) {
    e.stopPropagation();
    minimized = !minimized;
    localStorage.setItem('sparkDemoInspectorMin', minimized ? '1' : '0');
    sync();
  });
  root.querySelector('[data-win="close"]').addEventListener('click', function (e) {
    e.stopPropagation();
    open = false;
    localStorage.setItem('sparkDemoInspector', 'closed');
    sync();
  });

  // Drag by the title bar (panel switches to fixed top/left coordinates).
  (function () {
    var drag = null;
    head.addEventListener('mousedown', function (e) {
      if (e.target.closest('.tab') || e.target.closest('.win')) return;
      var r = panel.getBoundingClientRect();
      drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
      e.preventDefault();
    });
    window.addEventListener('mousemove', function (e) {
      if (!drag) return;
      panel.style.left = Math.max(0, Math.min(window.innerWidth - 80, e.clientX - drag.dx)) + 'px';
      panel.style.top = Math.max(0, Math.min(window.innerHeight - 36, e.clientY - drag.dy)) + 'px';
      panel.style.right = 'auto';
      panel.style.bottom = 'auto';
    });
    window.addEventListener('mouseup', function () { drag = null; });
  })();

  function sync() {
    panel.hidden = !open;
    panel.classList.toggle('min', minimized);
    btn.textContent = open ? 'Inspector ✕' : 'API ' + String(calls.filter(function (c) { return c.api; }).length);
    if (open) { connectStream(); render(); }
  }

  var pending = false;
  function scheduleRender() {
    btn.textContent = open ? 'Inspector ✕' : 'API ' + String(calls.filter(function (c) { return c.api; }).length);
    if (!open || pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; render(); });
  }

  // ---- DOM helpers -----------------------------------------------------------
  // el(tag, attrs, children): attrs are plain attributes (class/title/colspan),
  // children are nodes or strings — strings always become text nodes.
  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (attrs[k] != null) node.setAttribute(k, String(attrs[k]));
      });
    }
    (children || []).forEach(function (c) {
      if (c == null) return;
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }
  function text(v) { return v == null ? '' : String(v); }
  function tr(cells) { return el('tr', null, cells); }
  function td(content, attrs) {
    return el('td', attrs, Array.isArray(content) ? content : [text(content)]);
  }
  function headerRow(labels) {
    return tr(labels.map(function (l) { return el('th', null, [l]); }));
  }
  function table(header, rows, emptyHint) {
    var t = el('table', null, [headerRow(header)]);
    if (rows.length) rows.forEach(function (r) { t.appendChild(r); });
    else if (emptyHint) t.appendChild(tr([td(emptyHint, { colspan: header.length, class: 'hint' })]));
    return t;
  }

  function render() {
    root.querySelectorAll('.tab').forEach(function (t) {
      t.classList.toggle('on', t.dataset.tab === activeTab);
    });
    var out = [];
    if (activeTab === 'calls') {
      var rows = calls.filter(function (c) { return c.api; }).map(function (c) {
        var status = text(c.status);
        return tr([
          td(c.time),
          td(c.method),
          td(c.service),
          td(c.path, { class: 'path', title: c.path }),
          td(status, { class: 's' + status.charAt(0) + 'xx s' + status }),
          td(c.ms == null ? '' : c.ms + ' ms'),
        ]);
      });
      out.push(el('div', { class: 'hint' }, [
        'Every request this UI sends to the SPARK API (newest first). The UI is just a client — everything below is plain REST.',
      ]));
      out.push(table(['time', 'method', 'service', 'path', 'status', 'dur'], rows,
        'No API calls yet — click through the UI.'));
    } else {
      var llmRows = llmEvents.map(function (e) {
        return tr([
          td(text(e.started_at).slice(11, 19)),
          td([text(e.model), el('span', { class: 'pill' }, ['Bedrock'])]),
          td(e.call_type),
          td(text(e.prompt_tokens) + '/' + text(e.completion_tokens)),
          td(e.duration_ms == null ? '' : e.duration_ms + ' ms'),
        ]);
      });
      var qRows = (rabbit.queues || []).map(function (q) {
        return tr([
          td(q.name),
          td(q.messages),
          td(q.consumers),
          td(Number(q.publish_rate || 0).toFixed(1) + '/s'),
        ]);
      });
      var bRows = (bedrock.models || []).map(function (m) {
        return tr([td(m.model), td(m.invocations_10m)]);
      });
      out.push(el('div', { class: 'sec' }, ['LLM calls via LiteLLM → Amazon Bedrock (from the LiteLLM request log)']));
      out.push(table(['time', 'model', 'type', 'tokens in/out', 'dur'], llmRows,
        'No LLM calls yet — trigger an AI feature.'));
      out.push(el('div', { class: 'sec' }, ['RabbitMQ queues']));
      out.push(table(['queue', 'messages', 'consumers', 'publish'], qRows, null));
      out.push(el('div', { class: 'sec' }, ['CloudWatch AWS/Bedrock — invocations (last 10 min)']));
      out.push(table(['model', 'invocations'], bRows, 'none yet'));
      Object.keys(sourceErrors).forEach(function (k) {
        out.push(el('div', { class: 'err' }, [k + ': ' + text(sourceErrors[k])]));
      });
    }
    body.replaceChildren.apply(body, out);
  }

  function mount() {
    document.body.appendChild(host);
    sync();
  }
  if (document.body) mount();
  else document.addEventListener('DOMContentLoaded', mount);
})();
