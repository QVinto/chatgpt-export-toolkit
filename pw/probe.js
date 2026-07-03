// probe.js — checks whether Playwright passes Cloudflare and the token authenticates the API.
'use strict';
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// base-dir = parent folder of this script (pw/..) — works for any folder name
const EXPORT_DIR = path.resolve(__dirname, '..');
const TOKEN = fs.readFileSync(path.join(EXPORT_DIR, 'token.txt'), 'utf8')
  .replace(/[\r\n]/g, '').trim().replace(/^[Bb]earer\s*/, '');
const ACC = process.env.ACC || '';
const HEADLESS = process.env.HEADLESS === '1';
const userDataDir = path.join(EXPORT_DIR, 'pw', 'userdata');

const inPageFetch = async (page, url, headers) =>
  page.evaluate(async ({ url, headers }) => {
    try {
      const r = await fetch(url, { headers, credentials: 'include' });
      const t = await r.text();
      return { status: r.status, ok: r.ok, ct: r.headers.get('content-type') || '', cfm: r.headers.get('cf-mitigated') || '', snippet: t.slice(0, 160) };
    } catch (e) { return { error: String(e) }; }
  }, { url, headers });

(async () => {
  console.log(`[probe] headless=${HEADLESS} token.len=${TOKEN.length} acc=${ACC || '(none)'}`);
  const ctx = await chromium.launchPersistentContext(userDataDir, {
    headless: HEADLESS,
    viewport: { width: 1280, height: 820 },
    locale: 'sk-SK',
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--disable-dev-shm-usage'],
  });
  const page = ctx.pages()[0] || await ctx.newPage();
  console.log('[probe] goto https://chatgpt.com/ ...');
  try { await page.goto('https://chatgpt.com/', { waitUntil: 'domcontentloaded', timeout: 60000 }); }
  catch (e) { console.log('[probe] goto warn:', e.message); }

  const H = { 'Authorization': 'Bearer ' + TOKEN, 'Accept': 'application/json' };
  if (ACC) H['chatgpt-account-id'] = ACC;

  let me = null;
  for (let i = 1; i <= 8; i++) {
    await page.waitForTimeout(4000);
    const title = await page.title().catch(() => '?');
    me = await inPageFetch(page, 'https://chatgpt.com/backend-api/me', H);
    console.log(`[probe] attempt ${i} | title="${title}" | me=${JSON.stringify(me)}`);
    if (me && me.status && me.status !== 403 && !me.error) break;
    if (i === 3) { console.log('[probe] reloading page...'); await page.goto('https://chatgpt.com/', { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {}); }
  }

  const conv = await inPageFetch(page, 'https://chatgpt.com/backend-api/conversations?offset=0&limit=1&order=updated', H);
  console.log('[probe] conversations:', JSON.stringify(conv));

  // verdict
  const ok = conv && conv.status === 200 && !conv.error;
  console.log(`[probe] VERDICT: ${ok ? 'SUCCESS – passed Cloudflare, token works' : 'FAILED – status=' + (conv && conv.status)}`);
  await ctx.close();
  process.exit(ok ? 0 : 2);
})().catch(e => { console.error('[probe] FATAL:', e); process.exit(3); });
