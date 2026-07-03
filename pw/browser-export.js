// =============================================================================
// browser-export.js
// Runs the original export-chatgpt tool, but routes ALL HTTP requests to
// chatgpt.com through a real browser (Playwright/Chromium) that passes the
// Cloudflare "managed challenge". The tool's logic (pagination, projects,
// markdown, files, resume) stays untouched — only the transport layer
// (the global fetch) changes.
//
// SAFETY: works only inside its own folder. NEVER adds --update.
// =============================================================================
'use strict';
const { chromium } = require('playwright');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
// base-dir = parent folder of this script (pw/..) — works for any folder name
const EXPORT_DIR = path.resolve(__dirname, '..');
const TOOL_DIR = path.join(EXPORT_DIR, 'tool');
const OUT_DIR = path.join(EXPORT_DIR, 'out');
const TOKEN_FILE = path.join(EXPORT_DIR, 'token.txt');
const USER_DATA_DIR = path.join(EXPORT_DIR, 'pw', 'userdata');
const ORIGIN = 'https://chatgpt.com';

function log(...a) { console.log('[bx]', ...a); }

function readToken() {
  let t = process.env.CHATGPT_BEARER_TOKEN || '';
  if (!t) { try { t = fs.readFileSync(TOKEN_FILE, 'utf8'); } catch {} }
  return t.replace(/[\r\n]/g, '').trim().replace(/^[Bb]earer\s*/, '');
}

// The throttle is read from a file (<folder>/.throttle) — this lets you change
// the pace between restarts (15s probe vs. a safe 60s) without editing this script.
function readStateNum(name, def) {
  try { const v = fs.readFileSync(path.join(EXPORT_DIR, name), 'utf8').trim(); if (/^\d+$/.test(v)) return v; } catch {}
  return def;
}

function extractAccountId(token) {
  try {
    const p = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    const a = p['https://api.openai.com/auth'] || {};
    return a.chatgpt_account_id || '';
  } catch { return ''; }
}

const TOKEN = readToken();
if (!TOKEN) { log('ERROR: empty token.'); process.exit(1); }
const ACC = process.env.ACC || extractAccountId(TOKEN);

// ---- Browser state ----------------------------------------------------------
let ctx = null;
let page = null;

async function launchBrowser() {
  ctx = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: process.env.HEADLESS === '1',
    viewport: { width: 1280, height: 820 },
    locale: 'sk-SK',
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--disable-dev-shm-usage'],
  });
  page = ctx.pages()[0] || await ctx.newPage();
  page.setDefaultTimeout(60000);
  await gotoOrigin();
}

async function gotoOrigin() {
  try { await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded', timeout: 60000 }); }
  catch (e) { log('goto warn:', e.message); }
}

// Performs the fetch INSIDE the page (same-origin -> cf_clearance cookie + Chrome TLS).
// Returns the body as base64 (works for both text and binary).
async function pageFetch(url, options) {
  return page.evaluate(async ({ url, options }) => {
    const r = await fetch(url, {
      method: options.method || 'GET',
      headers: options.headers || {},
      body: options.body,
      credentials: 'include',
    });
    const ab = await r.arrayBuffer();
    const bytes = new Uint8Array(ab);
    let bin = '';
    const CH = 0x8000;
    for (let i = 0; i < bytes.length; i += CH) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
    const headers = {};
    r.headers.forEach((v, k) => { headers[k] = v; });
    return { status: r.status, statusText: r.statusText, ok: r.ok, headers, b64: btoa(bin) };
  }, { url, options });
}

function looksLikeChallenge(status, headers, bodyText) {
  if (status !== 403 && status !== 429 && status !== 503) return false;
  if ((headers['cf-mitigated'] || '') === 'challenge') return true;
  return /<html|just a moment|enable javascript|cf_chl|attention required|cf-browser-verification/i.test(bodyText || '');
}

// Builds a Response-like object compatible with what the tool uses.
function makeResponse(raw) {
  const buf = Buffer.from(raw.b64, 'base64');
  return {
    status: raw.status,
    statusText: raw.statusText || '',
    ok: raw.ok,
    headers: { get: (n) => { const v = raw.headers[String(n).toLowerCase()]; return v === undefined ? null : v; } },
    json: async () => JSON.parse(buf.toString('utf8')),
    text: async () => buf.toString('utf8'),
    arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength),
  };
}

const nativeFetch = globalThis.fetch.bind(globalThis);

// Our transport. chatgpt.com -> via the browser; other hosts (signed CDN) -> native.
async function browserFetch(input, init = {}) {
  const url = typeof input === 'string' ? input : (input && input.url) || String(input);
  let host;
  try { host = new URL(url).host; } catch { return nativeFetch(input, init); }

  if (host !== 'chatgpt.com') {
    // Signed CDN download URL — no Cloudflare challenge, a native fetch is enough.
    return nativeFetch(input, init);
  }

  const options = { method: init.method || 'GET', headers: init.headers || {}, body: init.body };
  let last = null;
  for (let attempt = 0; attempt < 5; attempt++) {
    let raw;
    try {
      raw = await pageFetch(url, options);
    } catch (e) {
      // The page may have navigated/crashed — try to recover the context.
      log(`pageFetch error (${e.message}) — refreshing the page...`);
      try { await gotoOrigin(); } catch {}
      await new Promise(r => setTimeout(r, 3000));
      continue;
    }
    const bodyText = Buffer.from(raw.b64, 'base64').toString('utf8').slice(0, 600);
    if (looksLikeChallenge(raw.status, raw.headers, bodyText)) {
      log(`Cloudflare challenge (status ${raw.status}) — reloading the page and retrying (${attempt + 1}/5)...`);
      await gotoOrigin();
      await new Promise(r => setTimeout(r, 6000));
      last = raw;
      continue;
    }
    return makeResponse(raw);
  }
  // Persistent challenge: return it as a 503 so the tool treats it as a transient error
  // (retry / exit != auth), NOT as an expired token (otherwise it would needlessly ask for a new one).
  log('Could not pass the Cloudflare challenge even after 5 attempts — returning 503 (transient).');
  return makeResponse({ status: 503, statusText: 'Cloudflare challenge', ok: false, headers: {}, b64: Buffer.from('cloudflare challenge unresolved').toString('base64') });
}

// ---- Main run ---------------------------------------------------------------
(async () => {
  log(`start | token.len=${TOKEN.length} | account-id=${ACC || '(none)'}`);
  await launchBrowser();

  // Verify the browser passed Cloudflare and the token works.
  const test = await browserFetch(`${ORIGIN}/backend-api/me`, { headers: { Authorization: 'Bearer ' + TOKEN, Accept: 'application/json', ...(ACC ? { 'chatgpt-account-id': ACC } : {}) } });
  if (test.status === 200) {
    const me = await test.json().catch(() => ({}));
    log(`auth OK — logged in as ${me.email || me.id || '?'}`);
  } else if (test.status === 401 || test.status === 403) {
    log(`auth failed with ${test.status} (auth) — the token is invalid/expired.`);
    console.log('BX_AUTH_FAIL');
    await ctx.close().catch(() => {});
    process.exit(1);
  } else {
    log(`auth returned status ${test.status} — continuing, the tool has its own retry.`);
  }

  // Install our transport before loading the tool.
  globalThis.fetch = browserFetch;

  // Prepare argv for the tool (NEVER --update!).
  process.env.CHATGPT_BEARER_TOKEN = TOKEN;
  const argv = [process.argv[0], 'export-chatgpt',
    '--non-interactive',
    '--throttle', (process.env.BX_THROTTLE || readStateNum('.throttle', '60')),
    '--min-throttle', (process.env.BX_MIN_THROTTLE || readStateNum('.min-throttle', '60')),
    '--include-archived',
    '--output', OUT_DIR,
  ];
  if (ACC) { argv.push('--account-id', ACC); }
  if (process.env.BX_MAX) { argv.push('--max', process.env.BX_MAX); log(`TEST mode: --max ${process.env.BX_MAX}`); }
  process.argv = argv;

  // Intercept the tool's process.exit so we can close the browser cleanly.
  const realExit = process.exit.bind(process);
  process.exit = (code = 0) => { const e = new Error('__TOOL_EXIT__'); e.__code = code; throw e; };

  let exitCode = 0;
  try {
    const { main } = require(path.join(TOOL_DIR, 'lib', 'cli.js'));
    await main();
    log('tool finished its run (success).');
    exitCode = 0;
  } catch (e) {
    if (e && e.message === '__TOOL_EXIT__') {
      exitCode = e.__code || 0;
      log(`tool called exit(${exitCode}).`);
    } else {
      log('ERROR during the tool run:', (e && e.stack) || e);
      exitCode = 1;
    }
  } finally {
    process.exit = realExit;
    try { await ctx.close(); } catch {}
  }
  realExit(exitCode);
})().catch(e => { log('FATAL:', (e && e.stack) || e); process.exit(1); });
