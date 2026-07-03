'use strict';
// Lokálny prehliadač ChatGPT exportu — číta IBA z ~/chatgpt-export/out (read-only).
// API + statický frontend. Dostupné cez Tailscale (bind 0.0.0.0).
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

// base-dir = nadradený priečinok tohto viewera (funguje pre akýkoľvek priečinok)
const E = path.resolve(__dirname, '..');
const OUT = path.join(E, 'out');
// Samostatný archív: súbory z oficiálneho OpenAI exportu, ktoré nie sú v našom (nenapojené na konverzácie).
const ARCH = path.join(E, 'official-openai', 'new-not-in-our-export');
const PORT = parseInt(process.env.VIEWER_PORT || '8765', 10);

// ---------- helpers ----------
function userDirs() {
  try { return fs.readdirSync(OUT).map(d => path.join(OUT, d)).filter(p => { try { return fs.statSync(p).isDirectory(); } catch { return false; } }); }
  catch { return []; }
}
function convFiles() {
  const out = [];
  for (const ud of userDirs()) {
    const jd = path.join(ud, 'json');
    if (fs.existsSync(jd)) for (const f of fs.readdirSync(jd)) if (f.endsWith('.json')) out.push({ file: path.join(jd, f), project: null });
    const pd = path.join(ud, 'projects');
    if (fs.existsSync(pd)) for (const p of fs.readdirSync(pd)) {
      const pjd = path.join(pd, p, 'json');
      if (fs.existsSync(pjd)) for (const f of fs.readdirSync(pjd)) if (f.endsWith('.json')) out.push({ file: path.join(pjd, f), project: p });
    }
  }
  return out;
}
// fileId -> absolútna cesta (obrázky/prílohy)
let fmCache = { ts: 0, map: {} };
function fileMap() {
  if (Date.now() - fmCache.ts < 30000 && Object.keys(fmCache.map).length) return fmCache.map;
  const map = {};
  for (const ud of userDirs()) {
    const dirs = [path.join(ud, 'files')];
    const pd = path.join(ud, 'projects');
    if (fs.existsSync(pd)) for (const p of fs.readdirSync(pd)) dirs.push(path.join(pd, p, 'files'));
    for (const d of dirs) {
      if (!fs.existsSync(d)) continue;
      for (const f of fs.readdirSync(d)) { const id = f.replace(/\.[^.]+$/, ''); map[id] = path.join(d, f); map[f] = path.join(d, f); }
    }
  }
  fmCache = { ts: Date.now(), map };
  return map;
}
function unesc(s){ try { return JSON.parse('"' + s + '"'); } catch { return s; } }
function stripPtr(p){ return String(p).replace(/^(sediment|file-service):\/\//,''); }

// rýchla metadata bez plného parse (číta prvých 16KB, regex)
const metaCache = new Map();
function quickMeta(file, project) {
  let st; try { st = fs.statSync(file); } catch { return null; }
  const c = metaCache.get(file);
  if (c && c.mtime === st.mtimeMs) return c.meta;
  let head = '';
  try { const fd = fs.openSync(file,'r'); const buf = Buffer.alloc(16384); const n = fs.readSync(fd, buf, 0, 16384, 0); fs.closeSync(fd); head = buf.slice(0,n).toString('utf8'); } catch {}
  const tm = head.match(/"title"\s*:\s*"((?:[^"\\]|\\.)*)"/);
  const ct = head.match(/"create_time"\s*:\s*([0-9.]+)/);
  const ut = head.match(/"update_time"\s*:\s*([0-9.]+)/);
  const meta = {
    file: path.relative(OUT, file), project,
    title: tm ? unesc(tm[1]) : path.basename(file),
    create_time: ct ? parseFloat(ct[1]) : null,
    update_time: ut ? parseFloat(ut[1]) : (st.mtimeMs/1000),
  };
  metaCache.set(file, { mtime: st.mtimeMs, meta });
  return meta;
}
function listAll() {
  return convFiles().map(c => quickMeta(c.file, c.project)).filter(Boolean)
    .sort((a,b) => (b.update_time||0) - (a.update_time||0));
}

// plný parse + linearizácia jednej konverzácie
function partsTI(content) {
  const r = { text: '', images: [] };
  if (!content) return r;
  const ct = content.content_type;
  if (ct === 'text' && Array.isArray(content.parts)) r.text = content.parts.filter(p=>typeof p==='string').join('\n');
  else if (ct === 'multimodal_text' && Array.isArray(content.parts)) {
    const t=[]; for (const p of content.parts){ if(typeof p==='string') t.push(p); else if(p&&p.asset_pointer) r.images.push(stripPtr(p.asset_pointer)); } r.text=t.join('\n');
  } else if (ct === 'code' || ct === 'execution_output') r.text = '```\n' + (content.text||'') + '\n```';
  else if (Array.isArray(content.parts)) r.text = content.parts.filter(p=>typeof p==='string').join('\n');
  else if (content.text) r.text = content.text;
  if (content.asset_pointer) r.images.push(stripPtr(content.asset_pointer));
  return r;
}
// Interné tool-správy, ktoré ChatGPT UI NEzobrazuje (retrieval/search injekcie do kontextu).
const HIDDEN_TOOL_AUTHORS = new Set(['file_search', 'web', 'browser', 'myfiles_browser']);
// Odstráni citačné značky v private-use Unicode (cite​turn0file0 a pod.), ktoré sa inak zobrazia ako prázdne štvorčeky.
function cleanCitations(t){
  if(!t) return t;
  return String(t)
    .replace(/[\ue000-\uf8ff]+/g,'')
    .replace(/cite\s*turn\d+\w*/gi,'')
    .replace(/turn\d+(?:file|news|search|view|image)\d+/gi,'');
}
function linearize(d) {
  const mapping = d.mapping || {}; let pathArr = [];
  let nid = d.current_node;
  if (nid && mapping[nid]) { const seen=new Set(); while(nid && mapping[nid] && !seen.has(nid)){ seen.add(nid); pathArr.push(mapping[nid]); nid=mapping[nid].parent; } pathArr.reverse(); }
  else { let root=Object.values(mapping).find(n=>!n.parent); let cur=root; const seen=new Set(); while(cur&&!seen.has(cur.id)){ seen.add(cur.id); pathArr.push(cur); cur=cur.children&&cur.children.length?mapping[cur.children[0]]:null; } }
  const out=[];
  for (const node of pathArr) {
    const m=node.message; if(!m||!m.content) continue;
    const role=m.author&&m.author.role; if(role==='system') continue;
    if(m.metadata&&m.metadata.is_visually_hidden_from_conversation) continue;
    // interné nástroje (vyhľadávanie v súboroch/web) — napr. "Make sure to include filecite… to cite this file" — v ChatGPT UI skryté
    const aname=(m.author&&m.author.name)||'';
    if(role==='tool' && HIDDEN_TOOL_AUTHORS.has(aname)) continue;
    let {text,images}=partsTI(m.content);
    text=cleanCitations(text);
    if(!String(text).trim() && images.length===0) continue;
    out.push({ role, text, images, create_time:m.create_time||null });
  }
  return out;
}

// full-text cache (na hľadanie)
const textCache = new Map();
function fullText(file) {
  let st; try { st = fs.statSync(file); } catch { return ''; }
  const c = textCache.get(file); if (c && c.mtime===st.mtimeMs) return c.text;
  let text='';
  try { const d=JSON.parse(fs.readFileSync(file,'utf8')); text=(d.title||'')+'\n'+linearize(d).map(m=>m.text).join('\n'); } catch {}
  textCache.set(file,{mtime:st.mtimeMs,text});
  return text;
}

// ---------- HTTP ----------
const MIME = { '.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.webp':'image/webp','.svg':'image/svg+xml','.pdf':'application/pdf','.wav':'audio/wav','.mp3':'audio/mpeg','.m4a':'audio/mp4','.ogg':'audio/ogg','.webm':'video/webm','.mp4':'video/mp4','.txt':'text/plain; charset=utf-8','.html':'text/html; charset=utf-8','.js':'text/javascript','.css':'text/css','.csv':'text/csv; charset=utf-8','.json':'application/json; charset=utf-8','.xlsx':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' };
function assetKind(ext){ ext=(ext||'').toLowerCase(); if(['.png','.jpg','.jpeg','.gif','.webp','.svg'].includes(ext))return'image'; if(['.wav','.mp3','.m4a','.ogg'].includes(ext))return'audio'; if(['.mp4','.webm'].includes(ext))return'video'; return'file'; }
// Typ + MIME aj pre súbory bez prípony (sniff magických bajtov) — archív má veľa UUID-mien bez koncovky.
function sniffType(abs, ext){
  if (MIME[ext]) return { mime: MIME[ext], kind: assetKind(ext) };
  try { const fd=fs.openSync(abs,'r'); const b=Buffer.alloc(16); const n=fs.readSync(fd,b,0,16,0); fs.closeSync(fd);
    if (n>=4 && b[0]===0x89&&b[1]===0x50&&b[2]===0x4E&&b[3]===0x47) return {mime:'image/png',kind:'image'};
    if (n>=3 && b[0]===0xFF&&b[1]===0xD8&&b[2]===0xFF) return {mime:'image/jpeg',kind:'image'};
    if (n>=4 && b[0]===0x47&&b[1]===0x49&&b[2]===0x46) return {mime:'image/gif',kind:'image'};
    if (n>=12 && b.slice(0,4).toString('latin1')==='RIFF' && b.slice(8,12).toString('latin1')==='WEBP') return {mime:'image/webp',kind:'image'};
    if (n>=4 && b[0]===0x25&&b[1]===0x50&&b[2]===0x44&&b[3]===0x46) return {mime:'application/pdf',kind:'file'};
  } catch {}
  return { mime: 'application/octet-stream', kind: 'file' };
}
let archCache = { ts:0, items:[] };
function archiveList(){
  let st; try{ st=fs.statSync(ARCH); }catch{ return []; }
  if (archCache.ts===st.mtimeMs && archCache.items.length) return archCache.items;
  let items=[];
  try { for (const f of fs.readdirSync(ARCH)) {
    if (f==='MANIFEST.txt') continue;
    const abs=path.join(ARCH,f); let s; try{ s=fs.statSync(abs); }catch{ continue; }
    if(!s.isFile()) continue;
    const { kind } = sniffType(abs, path.extname(f).toLowerCase());
    items.push({ name:f, size:s.size, kind });
  } } catch {}
  items.sort((a,b)=> a.kind===b.kind ? a.name.localeCompare(b.name) : (a.kind==='image'?-1:1));
  archCache = { ts:st.mtimeMs, items };
  return items;
}
function send(res, code, type, body){ res.writeHead(code, {'Content-Type':type,'Access-Control-Allow-Origin':'*'}); res.end(body); }
function sendJson(res, obj){ send(res, 200, 'application/json; charset=utf-8', JSON.stringify(obj)); }

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  try {
    if (u.pathname === '/' ) {
      return send(res, 200, 'text/html; charset=utf-8', fs.readFileSync(path.join(__dirname,'index.html')));
    }
    if (u.pathname === '/api/list') {
      const items = listAll();
      const projects = [...new Set(items.map(i=>i.project).filter(Boolean))].sort();
      return sendJson(res, { count: items.length, projects, items });
    }
    if (u.pathname === '/api/conv') {
      const rel = u.searchParams.get('file'); if (!rel) return send(res,400,'text/plain','missing file');
      const abs = path.join(OUT, rel); if (!abs.startsWith(OUT)) return send(res,403,'text/plain','no');
      const d = JSON.parse(fs.readFileSync(abs,'utf8'));
      const fm = fileMap();
      const msgs = linearize(d).map(m => ({ role:m.role, text:m.text, create_time:m.create_time,
        images: m.images.map(id => { const abs=fm[id]; const ext=abs?path.extname(abs):''; return { id, url: abs ? ('/file?id='+encodeURIComponent(id)) : null, kind: abs?assetKind(ext):'missing', name: abs?path.basename(abs):id }; }) }));
      return sendJson(res, { title:d.title||'(Untitled)', create_time:d.create_time, update_time:d.update_time, messages: msgs });
    }
    if (u.pathname === '/api/search') {
      const q = (u.searchParams.get('q')||'').trim().toLowerCase(); if(!q) return sendJson(res,{items:[]});
      const items=[];
      for (const c of convFiles()) {
        const t = fullText(c.file).toLowerCase();
        const idx = t.indexOf(q);
        if (idx>=0) { const meta=quickMeta(c.file,c.project); const snip=fullText(c.file).slice(Math.max(0,idx-60), idx+120).replace(/\s+/g,' ');
          items.push({ ...meta, snippet: snip }); }
        if (items.length>=300) break;
      }
      items.sort((a,b)=>(b.update_time||0)-(a.update_time||0));
      return sendJson(res, { count: items.length, items });
    }
    if (u.pathname === '/file') {
      const id = u.searchParams.get('id'); const fm = fileMap(); const abs = fm[id];
      if (!abs || !fs.existsSync(abs)) return send(res,404,'text/plain','not found');
      const ext = path.extname(abs).toLowerCase();
      res.writeHead(200, {'Content-Type': MIME[ext]||'application/octet-stream'});
      return fs.createReadStream(abs).pipe(res);
    }
    if (u.pathname === '/api/archive') {
      const items = archiveList();
      return sendJson(res, { count: items.length, items });
    }
    if (u.pathname === '/archive-file') {
      const name = u.searchParams.get('name') || '';
      if (name.includes('/') || name.includes('..') || name.includes('\0')) return send(res,403,'text/plain','no');
      const abs = path.join(ARCH, name);
      if (!abs.startsWith(ARCH) || !fs.existsSync(abs)) return send(res,404,'text/plain','not found');
      const { mime } = sniffType(abs, path.extname(abs).toLowerCase());
      res.writeHead(200, {'Content-Type': mime});
      return fs.createReadStream(abs).pipe(res);
    }
    return send(res, 404, 'text/plain', 'not found');
  } catch (e) {
    return send(res, 500, 'text/plain', 'error: ' + e.message);
  }
});
server.listen(PORT, '0.0.0.0', () => console.log('viewer beží na 0.0.0.0:'+PORT));
