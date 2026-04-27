/* ============================================================
   tinydb Admin Dashboard — app.js
   Pure vanilla JS. No frameworks. No dependencies.
   ============================================================ */

'use strict';

// ── Config ──────────────────────────────────────────────────
const API_BASE        = 'http://localhost:8080';
const LS_SCHEMA_KEY   = 'tinydb_schema_fields';
const STATUS_INTERVAL = 5000;  // ms between health checks

// ── State ───────────────────────────────────────────────────
let schemaFields = [];          // ['name', 'age', 'city']
let backendOnline = null;       // null | true | false

// ── DOM Refs ────────────────────────────────────────────────
const $ = id => document.getElementById(id);

const dom = {
  statusPill:    $('statusPill'),
  statusDot:     $('statusDot'),
  statusLabel:   $('statusLabel'),
  headerSchema:  $('headerSchema'),

  initCount:     $('initCount'),
  initFields:    $('initFields'),
  btnInit:       $('btnInit'),

  insertId:      $('insertId'),
  insertDynFields: $('insertDynFields'),
  btnInsert:     $('btnInsert'),

  getId:         $('getId'),
  btnGet:        $('btnGet'),
  getResult:     $('getResult'),
  getResultId:   $('getResultId'),
  getResultBody: $('getResultBody'),

  delId:         $('delId'),
  btnDel:        $('btnDel'),

  logPanel:      $('logPanel'),
  btnClearLog:   $('btnClearLog'),
};

// ── Toast Container (injected once) ─────────────────────────
const toastContainer = document.createElement('div');
toastContainer.id = 'toastContainer';
document.body.appendChild(toastContainer);

// ============================================================
// API Layer
// ============================================================

async function apiPost(path, bodyStr) {
  const res = await fetch(`${API_BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: bodyStr,
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  return { ok: res.ok, status: res.status, data: json };
}

async function apiGet(path) {
  const res = await fetch(`${API_BASE}${path}`);
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  return { ok: res.ok, status: res.status, data: json };
}

// ── Health check ─────────────────────────────────────────────
async function checkHealth() {
  try {
    // Sending a minimal GET that will return 400 is fine — we just
    // want to know the server is alive.
    const res = await fetch(`${API_BASE}/get?id=__ping__`, {
      signal: AbortSignal.timeout(2500),
    });
    setOnline(true);
  } catch {
    setOnline(false);
  }
}

function setOnline(online) {
  if (backendOnline === online) return;
  backendOnline = online;

  dom.statusDot.className   = `status-dot ${online ? 'online' : 'offline'}`;
  dom.statusPill.className  = `status-pill ${online ? 'online' : 'offline'}`;
  dom.statusLabel.textContent = online ? 'Backend Connected' : 'Backend Offline';

  if (!online) {
    log('err', 'Backend unreachable at ' + API_BASE);
  } else {
    log('inf', 'Connected to ' + API_BASE);
  }
}

// ============================================================
// Schema Management
// ============================================================

function loadSchemaFromStorage() {
  try {
    const raw = localStorage.getItem(LS_SCHEMA_KEY);
    if (raw) {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed) && parsed.length > 0) {
        schemaFields = parsed;
        renderInsertFields();
        updateHeaderSchema();
      }
    }
  } catch {/* ignore */}
}

function saveSchemaToStorage(fields) {
  localStorage.setItem(LS_SCHEMA_KEY, JSON.stringify(fields));
}

function updateHeaderSchema() {
  dom.headerSchema.textContent = schemaFields.length
    ? `Schema: ${schemaFields.join(', ')}`
    : 'No schema';
}

function renderInsertFields() {
  dom.insertDynFields.innerHTML = '';

  if (!schemaFields.length) {
    dom.insertDynFields.innerHTML = `
      <div class="no-schema-notice">
        <span class="notice-icon">◈</span>
        Initialize schema first to unlock field inputs
      </div>`;
    return;
  }

  schemaFields.forEach(field => {
    const wrapper = document.createElement('div');
    wrapper.className = 'field';

    const label = document.createElement('label');
    label.className = 'field-label';
    label.setAttribute('for', `ins_${field}`);
    label.textContent = field;

    const input = document.createElement('input');
    input.className = 'field-input';
    input.type = 'text';
    input.id = `ins_${field}`;
    input.name = field;
    input.placeholder = `Enter ${field}…`;

    wrapper.appendChild(label);
    wrapper.appendChild(input);
    dom.insertDynFields.appendChild(wrapper);
  });
}

// ============================================================
// Button Loading State Helper
// ============================================================

function setLoading(btn, loading) {
  const textEl   = btn.querySelector('.btn-text');
  const loaderEl = btn.querySelector('.btn-loader');
  btn.disabled = loading;
  if (textEl)   textEl.hidden = loading;
  if (loaderEl) loaderEl.hidden = !loading;
}

// ============================================================
// Handlers
// ============================================================

// ── INIT ─────────────────────────────────────────────────────
dom.btnInit.addEventListener('click', async () => {
  const countRaw = dom.initCount.value.trim();
  const fieldsRaw = dom.initFields.value.trim();

  if (!countRaw || !fieldsRaw) {
    toast('err', 'Fill in field count and field names.');
    return;
  }

  const count = parseInt(countRaw, 10);
  const fieldList = fieldsRaw.split(/\s+/).filter(Boolean);

  if (isNaN(count) || count < 1 || count > 16) {
    toast('err', 'Field count must be between 1 and 16.');
    return;
  }

  if (fieldList.length !== count) {
    toast('err', `Expected ${count} field names, got ${fieldList.length}.`);
    return;
  }

  setLoading(dom.btnInit, true);
  log('inf', `POST /init — ${count} fields: ${fieldList.join(', ')}`);

  try {
    const body = `count=${count}&fields=${fieldList.join('+')}`;
    const { ok, data } = await apiPost('/init', body);

    if (ok && (data.ok === true || data.ok === 'true')) {
      schemaFields = fieldList;
      saveSchemaToStorage(schemaFields);
      renderInsertFields();
      updateHeaderSchema();
      log('ok', `Schema initialized: ${fieldList.join(', ')}`);
      toast('ok', `Schema set → ${fieldList.join(' · ')}`);
      dom.initCount.value = '';
      dom.initFields.value = '';
    } else {
      const msg = data.error || JSON.stringify(data);
      log('err', `Init failed: ${msg}`);
      toast('err', `Init failed: ${msg}`);
    }
  } catch (e) {
    log('err', `Network error: ${e.message}`);
    toast('err', 'Cannot reach backend.');
  } finally {
    setLoading(dom.btnInit, false);
  }
});

// ── INSERT ────────────────────────────────────────────────────
dom.btnInsert.addEventListener('click', async () => {
  const id = dom.insertId.value.trim();
  if (!id) { toast('err', 'Record ID is required.'); return; }

  if (!schemaFields.length) {
    toast('err', 'Initialize schema before inserting.');
    return;
  }

  const parts = [`id=${encodeURIComponent(id)}`];
  const fieldValues = {};
  let allFilled = true;

  schemaFields.forEach(field => {
    const input = document.getElementById(`ins_${field}`);
    const val = input ? input.value.trim() : '';
    if (!val) allFilled = false;
    parts.push(`${encodeURIComponent(field)}=${encodeURIComponent(val)}`);
    fieldValues[field] = val;
  });

  if (!allFilled) {
    toast('err', 'All field values are required.');
    return;
  }

  setLoading(dom.btnInsert, true);
  const body = parts.join('&');
  const preview = schemaFields.map(f => `${f}=${fieldValues[f]}`).join(', ');
  log('inf', `POST /insert — id=${id}, ${preview}`);

  try {
    const { ok, data } = await apiPost('/insert', body);
    if (ok && (data.ok === true || data.ok === 'true')) {
      log('ok', `Inserted record id=${id}`);
      toast('ok', `Record ${id} inserted.`);
      dom.insertId.value = '';
      schemaFields.forEach(field => {
        const input = document.getElementById(`ins_${field}`);
        if (input) input.value = '';
      });
    } else {
      const msg = data.error || JSON.stringify(data);
      log('err', `Insert failed: ${msg}`);
      toast('err', `Insert failed: ${msg}`);
    }
  } catch (e) {
    log('err', `Network error: ${e.message}`);
    toast('err', 'Cannot reach backend.');
  } finally {
    setLoading(dom.btnInsert, false);
  }
});

// ── GET ───────────────────────────────────────────────────────
dom.btnGet.addEventListener('click', async () => {
  const id = dom.getId.value.trim();
  if (!id) { toast('err', 'Enter a record ID.'); return; }

  setLoading(dom.btnGet, true);
  dom.getResult.hidden = true;
  log('inf', `GET /get?id=${id}`);

  try {
    const { ok, status, data } = await apiGet(`/get?id=${encodeURIComponent(id)}`);

    if (status === 404 || data.error) {
      dom.getResultId.textContent = `id = ${id}`;
      dom.getResultBody.innerHTML = `<div class="result-not-found">✕ &nbsp;Record not found</div>`;
      dom.getResult.hidden = false;
      log('err', `GET id=${id} → not found`);
    } else {
      dom.getResultId.textContent = `id = ${id}`;
      dom.getResultBody.innerHTML = '';
      Object.entries(data).forEach(([key, val]) => {
        const row = document.createElement('div');
        row.className = 'result-row';
        row.innerHTML = `
          <span class="result-key">${escHtml(key)}</span>
          <span class="result-val">${escHtml(String(val))}</span>
        `;
        dom.getResultBody.appendChild(row);
      });
      dom.getResult.hidden = false;
      log('ok', `GET id=${id} → ${JSON.stringify(data)}`);
    }
  } catch (e) {
    log('err', `Network error: ${e.message}`);
    toast('err', 'Cannot reach backend.');
  } finally {
    setLoading(dom.btnGet, false);
  }
});

// Allow Enter key on get input
dom.getId.addEventListener('keydown', e => {
  if (e.key === 'Enter') dom.btnGet.click();
});

// ── DEL ───────────────────────────────────────────────────────
dom.btnDel.addEventListener('click', async () => {
  const id = dom.delId.value.trim();
  if (!id) { toast('err', 'Enter a record ID.'); return; }

  setLoading(dom.btnDel, true);
  log('inf', `POST /del — id=${id}`);

  try {
    const { ok, data } = await apiPost('/del', `id=${encodeURIComponent(id)}`);

    if (data.deleted === 1 || data.deleted === '1') {
      log('ok', `Deleted record id=${id}`);
      toast('ok', `Record ${id} deleted.`);
      dom.delId.value = '';
      // Clear get result if it was showing the deleted record
      if (dom.getId.value.trim() === id) {
        dom.getResult.hidden = true;
      }
    } else {
      log('err', `DEL id=${id} → not found (deleted=0)`);
      toast('err', `Record ${id} not found.`);
    }
  } catch (e) {
    log('err', `Network error: ${e.message}`);
    toast('err', 'Cannot reach backend.');
  } finally {
    setLoading(dom.btnDel, false);
  }
});

// Allow Enter key on del input
dom.delId.addEventListener('keydown', e => {
  if (e.key === 'Enter') dom.btnDel.click();
});

// ── Clear log ─────────────────────────────────────────────────
dom.btnClearLog.addEventListener('click', () => {
  dom.logPanel.innerHTML = '<div class="log-empty">Log cleared.</div>';
});

// ============================================================
// Log & Toast Utilities
// ============================================================

function log(type, message) {
  // Remove empty state
  const empty = dom.logPanel.querySelector('.log-empty');
  if (empty) empty.remove();

  const now = new Date();
  const time = now.toTimeString().slice(0, 8);

  const entry = document.createElement('div');
  entry.className = 'log-entry';
  entry.innerHTML = `
    <span class="log-time">${time}</span>
    <span class="log-badge ${type}">${type.toUpperCase()}</span>
    <span class="log-msg">${escHtml(message)}</span>
  `;

  // Prepend so newest is on top
  dom.logPanel.insertBefore(entry, dom.logPanel.firstChild);

  // Keep max 100 entries
  const entries = dom.logPanel.querySelectorAll('.log-entry');
  if (entries.length > 100) entries[entries.length - 1].remove();
}

function toast(type, message) {
  const t = document.createElement('div');
  t.className = `toast ${type}`;
  t.innerHTML = `
    <span class="toast-icon">${type === 'ok' ? '✓' : '✕'}</span>
    <span class="toast-text">${escHtml(message)}</span>
  `;
  toastContainer.appendChild(t);

  // Auto-dismiss
  setTimeout(() => {
    t.classList.add('leaving');
    t.addEventListener('animationend', () => t.remove(), { once: true });
  }, 3200);
}

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ============================================================
// Init
// ============================================================

function init() {
  loadSchemaFromStorage();
  checkHealth();
  setInterval(checkHealth, STATUS_INTERVAL);

  // Pre-fill init inputs if schema already exists in storage
  if (schemaFields.length) {
    dom.initCount.value  = schemaFields.length;
    dom.initFields.value = schemaFields.join(' ');
  }

  log('inf', 'Dashboard ready');
}

init();