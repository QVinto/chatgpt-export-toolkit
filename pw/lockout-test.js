// lockout-test.js — ONE real conversation fetch to check whether a rate-limit lockout has lifted.
'use strict';
const { chromium } = require('playwright');
const fs = require('fs'); const os = require('os'); const path = require('path');
// base-dir = parent folder of this script (pw/..) — portable for any folder name
const E = path.resolve(__dirname, '..');
const TOK = fs.readFileSync(E+'/token.txt','utf8').replace(/[\r\n]/g,'').trim().replace(/^[Bb]earer\s*/,'');
const ACC = (()=>{try{const p=JSON.parse(Buffer.from(TOK.split('.')[1],'base64url').toString('utf8'));return (p['https://api.openai.com/auth']||{}).chatgpt_account_id||'';}catch{return '';}})();
const ID = process.argv[2];
(async()=>{
  const ctx = await chromium.launchPersistentContext(E+'/pw/userdata',{headless:false,viewport:{width:1280,height:820},args:['--no-sandbox','--disable-blink-features=AutomationControlled','--disable-dev-shm-usage']});
  const page = ctx.pages()[0]||await ctx.newPage(); page.setDefaultTimeout(60000);
  try{ await page.goto('https://chatgpt.com/',{waitUntil:'domcontentloaded',timeout:60000}); }catch(e){console.log('goto warn',e.message);}
  await page.waitForTimeout(5000);
  const H={'Authorization':'Bearer '+TOK,'Accept':'application/json'}; if(ACC)H['chatgpt-account-id']=ACC;
  const r = await page.evaluate(async({url,headers})=>{ try{const x=await fetch(url,{headers,credentials:'include'});const t=await x.text();return{status:x.status,ct:x.headers.get('content-type')||'',cfm:x.headers.get('cf-mitigated')||'',snip:t.slice(0,120)};}catch(e){return{error:String(e)};} },{url:'https://chatgpt.com/backend-api/conversation/'+ID,headers:H});
  console.log('TEST conversation '+ID+' =>', JSON.stringify(r));
  const ok = r.status===200;
  console.log(ok ? 'VERDICT: ✅ LOCKOUT LIFTED (200) — safe to start' : 'VERDICT: ⛔ still '+ (r.status||r.error));
  await ctx.close().catch(()=>{});
  process.exit(ok?0:2);
})().catch(e=>{console.error('FATAL',e);process.exit(3);});
