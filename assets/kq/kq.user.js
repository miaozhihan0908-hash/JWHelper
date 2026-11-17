// ==UserScript==
// @name         山体智慧考勤
// @namespace    kq.sdpei
// @version      1.4.3
// @description  自动签到/签退 · 精简版（小到不会被剪贴板截断）
// @match        *://qdxt.sdpei.edu.cn/*
// @include      *://qdxt.sdpei.edu.cn:7083/*
// @run-at       document-idle
// @grant        none
// @noframes
// ==/UserScript==
(() => {
'use strict';
if (window.__KQ_MOBILE__) return;
window.__KQ_MOBILE__ = true;
const TO = (m, c) => { try { const d = document.createElement('div'); d.textContent = m; d.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:2147483647;background:' + (c || 'rgb(185,28,28)') + ';color:#fff;font:12px/1.6 monospace;padding:8px 10px;border-radius:8px;max-width:92vw;white-space:pre-wrap'; (document.body || document.documentElement).appendChild(d); setTimeout(() => d.remove(), 20000); } catch (e) {} };
try {
const CF = 'kq_mobile_cfg', DN = 'kq_mobile_done';
const cfg = Object.assign({ gpsMode: 'auto', fixedGps: '', jitterM: 8, lowTrace: true, jitterSigma: 10, arrivalSpreadMin: 20, idlePollMinutes: 40, leadMin: 10, outLeadMin: 5, outLagMin: 20, faceReport: false, intervalMs: 45000, commit: false, autoStart: true }, JSON.parse(localStorage.getItem(CF) || '{}'));
const save = () => localStorage.setItem(CF, JSON.stringify(cfg));
const N2 = n => String(n).padStart(2, '0');
const Y = d => d.getFullYear() + '-' + N2(d.getMonth() + 1) + '-' + N2(d.getDate());
const HM = d => N2(d.getHours()) + ':' + N2(d.getMinutes());
const ST = d => Y(d) + ' ' + HM(d) + ':' + N2(d.getSeconds());
const SL = ms => new Promise(r => setTimeout(r, ms));
const DM = (() => { try { return JSON.parse(localStorage.getItem(DN) || '{}'); } catch (e) { return {}; } })();
const isDone = k => (DM[Y(new Date())] || []).indexOf(k) >= 0;
const mkDone = k => { const d = Y(new Date()); (DM[d] = DM[d] || []).push(k); localStorage.setItem(DN, JSON.stringify(DM)); };
const GS = () => { let u = 0, v = 0; while (!u) u = Math.random(); while (!v) v = Math.random(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };
const UID = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxxyxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }) + Date.now().toString(16));
const LG = [];
let UI = { refresh() {} };
const say = (m, lv) => { const d = new Date(); LG.push((lv === 'err' ? 'x ' : '') + N2(d.getHours()) + ':' + N2(d.getMinutes()) + ':' + N2(d.getSeconds()) + ' ' + m); if (LG.length > 5) LG.shift(); try { UI.refresh(); } catch (e) {} console.log('[KQ]', m); };
let MD = null;
async function mod() {
  if (MD) return MD;
  if (window.__KQ_TEST_MOD__) { MD = window.__KQ_TEST_MOD__; return MD; }
  const rs = performance.getEntriesByType('resource').map(e => e.name);
  let u = rs.find(x => /\/assets\/request\.[\w-]+\.js/.test(x));
  if (!u) { const i = rs.find(x => /\/assets\/index-[\w-]+\.js/.test(x)); if (i) { const t = await (await fetch(i)).text(); const m = t.match(/assets\/request\.[\w-]+\.js/); if (m) u = new URL(m[0], location.origin).href; } }
  if (!u) throw new Error('未找到 request 模块，请刷新');
  MD = await import(u);
  if (typeof MD.c !== 'function') throw new Error('request 模块异常');
  return MD;
}
/* 注入环境（如 App 的 WebView）里页面未必已经加载完 request 模块，这里重试等它 */
async function waitMod(n) { let e; for (let i = 0; i < n; i++) { try { return await mod(); } catch (x) { e = x; if (i < n - 1) await SL(1000); } } throw e; }
async function token0() { try { const M = await mod(); return (M.k && typeof M.k.get === 'function' ? M.k.get('JwtToken', true, 'STR') : '') || ''; } catch (e) { return ''; } }
/* App 里走的是「智慧山体」统一认证：JwtToken 可能永远不出现，
   但 userToken cookie 在、或者页面已经进到 /pages/kq/，就说明有登录态 */
function hasSso() {
  try { if (document.cookie && String(document.cookie).indexOf('userToken=') >= 0) return true; } catch (e) {}
  try { return String(location.pathname || '').indexOf('/pages/kq/') >= 0; } catch (e) { return false; }
}
async function authOK() { if (await token0()) return true; return hasSso(); }
const q = async (url, method, params) => { const M = await mod(); return M.c({ url, method, params: Object.assign({}, params, { uniContentType: 'json' }) }); };
const api = {
  myInfo: () => q('/myinfoApp', 'POST', {}),
  schedule: (d, no) => q('/studentPaike/mySchedule', 'POST', { classDate: d, studentNo: no }),
  doSign: p => q('/studentSign/doSign', 'POST', p),
  doSignOut: p => q('/studentSign/doSignOut', 'POST', p),
  faceReport: p => q('/faceSign/report', 'POST', p),
  mobileLog: p => q('/mobileLog/add', 'POST', p),
};
let STU = null;
const scan = () => { for (let i = 0; i < localStorage.length; i++) { const v = localStorage.getItem(localStorage.key(i)) || ''; const m = v.match(/"staffCode"\s*:\s*"([^"]+)"/); if (m) return m[1]; } return null; };
async function studentNo() {
  if (STU) return STU;
  STU = scan();
  if (STU) return STU;
  if (!(await authOK())) throw new Error('未登录，先在本页登录');
  try { const i = await api.myInfo(); const m = JSON.stringify(i).match(/"staffCode"\s*:\s*"([^"]+)"/); if (m) STU = m[1]; } catch (e) {}
  if (!STU) STU = scan();
  if (!STU) throw new Error('拿不到学号');
  return STU;
}
function hav(a, b, c, d) { const r1 = a * Math.PI / 180, r2 = b * Math.PI / 180, dl = (c - a) * Math.PI / 180, dj = (d - b) * Math.PI / 180; const x = Math.sin(dl / 2) ** 2 + Math.cos(r1) * Math.cos(r2) * Math.sin(dj / 2) ** 2; return 12742000 * Math.asin(Math.sqrt(x)); }
function inP(lng, lat, P) { let r = false; for (let i = 0, j = P.length - 1; i < P.length; j = i++) { const x1 = P[j][0], y1 = P[j][1], x2 = P[i][0], y2 = P[i][1]; if ((y1 > lat) !== (y2 > lat) && lng < (x2 - x1) * (lat - y1) / (y2 - y1) + x1) r = !r; } return r; }
function ctr(list) {
  if (!list || !list.length) return null;
  const c = list.find(p => String(p.title) === 'c');
  if (c) return [Number(c.longitude), Number(c.latitude)];
  const ps = list.filter(p => String(p.title) !== 'c');
  if (!ps.length) return null;
  return [ps.reduce((s, p) => s + Number(p.longitude), 0) / ps.length, ps.reduce((s, p) => s + Number(p.latitude), 0) / ps.length];
}
function evl(list, gps) {
  if (!list || !list.length || !gps) return { distance: 400, status: '4' };
  const p = gps.split(',').map(Number);
  const ps = list.filter(x => String(x.title) !== 'c');
  if (ps.length >= 3 && inP(p[0], p[1], ps.map(x => [Number(x.longitude), Number(x.latitude)]))) return { distance: 0, status: '3' };
  const t = ctr(list);
  if (!t) return { distance: 200, status: '4' };
  const d = hav(t[0], t[1], p[0], p[1]);
  return { distance: d, status: d > 100 ? '4' : '3' };
}
function devGps() { return new Promise(r => { if (!navigator.geolocation) return r(''); navigator.geolocation.getCurrentPosition(p => r(p.coords.longitude.toFixed(6) + ',' + p.coords.latitude.toFixed(6)), () => r(''), { enableHighAccuracy: true, timeout: 6000, maximumAge: 60000 }); }); }
async function pick(c) {
  let lng, lat;
  if (cfg.gpsMode === 'device') { const g = await devGps(); if (g) return g; }
  if (cfg.gpsMode === 'fixed' && cfg.fixedGps) { const p = cfg.fixedGps.split(','); lng = Number(p[0]); lat = Number(p[1]); }
  else { const t = ctr(c.roomGpsList); if (!t) throw new Error('该课无围栏坐标'); lng = t[0]; lat = t[1]; }
  if (cfg.jitterM > 0) {
    if (cfg.lowTrace) { const s = (cfg.jitterSigma == null ? 10 : cfg.jitterSigma) / 111320; lng += GS() * s; lat += GS() * s * 0.8; }
    else { lng += (Math.random() * 2 - 1) * cfg.jitterM / 111320; lat += (Math.random() * 2 - 1) * cfg.jitterM / 111320; }
  }
  return lng.toFixed(6) + ',' + lat.toFixed(6);
}
const AT = (d, s) => { const a = d.split('-').map(Number), b = String(s).split(':').map(Number); return new Date(a[0], a[1] - 1, a[2], b[0], b[1], 0, 0); };
function WIN(c) {
  const d = Y(new Date()), s = AT(d, c.startTime), e = AT(d, c.endTime);
  return { signIn: [new Date(+s - cfg.leadMin * 60000), e], signOut: [new Date(+e - cfg.outLeadMin * 60000), new Date(+e + cfg.outLagMin * 60000)] };
}
const inW = (t, w) => t >= w[0] && t <= w[1];
// ==KQ-SPLIT==
let busy = false;
const seen = new Set(), arr = new Map();
function net() { const c = navigator.connection || navigator.mozConnection || {}; return [navigator.onLine, c.type || '', c.effectiveType || '', c.downlink || ''].join('|'); }
async function chain(no, gps, ev, inF) {
  const lng = Number(gps.split(',')[0]), lat = Number(gps.split(',')[1]);
  const dist = Number.isFinite(ev && ev.distance) ? Number(ev.distance.toFixed(1)) : 0;
  const n0 = net();
  const gd = () => { if (cfg.lowTrace && net() !== n0) throw new Error('网络已切换，链路中止'); };
  try { await api.faceReport({ uuid: UID(), user_id: no, latitude: String(lat), longitude: String(lng), altitude: inF ? 1 : 0, accuracy: dist, altitudeAccuracy: inF ? 0 : 4, time: ST(new Date()) }); } catch (e) { say('预记录失败 ' + e, 'err'); }
  gd();
  try { await api.mobileLog({ userId: no, type: '3', message: gps }); } catch (e) {}
  gd();
  await SL(8000 + Math.random() * 12000);
  gd();
}
async function face(no, gps) {
  const p = gps.split(',');
  try { await api.faceReport({ uuid: UID(), user_id: no, score: Number((0.52 + Math.random() * 0.19).toFixed(4)), threshold: 0.45, status: 'PASS', latitude: p[0], longitude: p[1], altitude: 0, accuracy: 0, altitudeAccuracy: 0, time: ST(new Date()) }); } catch (e) { say('人脸结果失败 ' + e, 'err'); }
}
let SC = { at: 0, date: '', data: [] };
async function sched(f) {
  const d = Y(new Date()), n = Date.now();
  if (!f && SC.date === d && n - SC.at < 600000) return { code: '200', data: SC.data };
  const r = await api.schedule(d, await studentNo());
  if (r && String(r.code) === '200') SC = { at: n, date: d, data: r.data || [] };
  return r;
}
function near(m) {
  const t = new Date(), k = m == null ? 40 : m;
  return (SC.data || []).some(c => { const w = WIN(c); return t >= new Date(+w.signIn[0] - k * 60000) && t <= new Date(+w.signOut[1] + k * 60000); });
}
async function sign(force) {
  if (busy) return 0;
  busy = true;
  try {
    const cm = force || cfg.commit;
    if (!(await authOK())) { say('未登录，先登录再点签到', 'err'); return 0; }
    const no = await studentNo();
    const r0 = await sched();
    const cs = (r0 && r0.data) || [];
    if (!cs.length) { say('今日无课'); return 0; }
    let n = 0;
    for (const c of cs) {
      if (['1', '2', '3', '4'].indexOf(String(c.signInStatus)) >= 0) continue;
      const w = WIN(c), t = new Date();
      if (!inW(t, w.signIn)) continue;
      const key = Y(t) + '|' + c.id;
      if (isDone(key)) continue;
      if (cfg.lowTrace) {
        if (!arr.has(key)) { const sp = (cfg.arrivalSpreadMin == null ? 20 : cfg.arrivalSpreadMin) * 60000; const tg = Math.min(+w.signIn[0] + Math.random() * sp, +AT(Y(t), c.startTime) + 300000); arr.set(key, new Date(Math.max(tg, Date.now()))); }
        const eta = arr.get(key);
        if (eta - t > 1000) { if (!seen.has(key)) { seen.add(key); say(c.courseName + ' 计划 ' + HM(eta) + ' 签到'); } continue; }
      }
      let gps;
      try { gps = await pick(c); } catch (e) { say(c.courseName + '：' + e.message, 'err'); continue; }
      const ev = evl(c.roomGpsList, gps);
      const inF = ev.status === '3';
      const pl = { classDate: Y(t), studentNo: no, paikeId: c.id, signType: '1', gps };
      if (!inF) pl.signInStatus = '4';
      say((cm ? '提交 ' : '演练 ') + '签到 ' + c.courseName + ' ' + gps + ' 距' + ev.distance.toFixed(0) + 'm');
      if (!cm) { if (!seen.has(key)) { seen.add(key); say('payload ' + JSON.stringify(pl)); } continue; }
      if (cfg.lowTrace || cfg.faceReport) { try { await chain(no, gps, ev, inF); } catch (e) { say(String(e.message || e), 'err'); continue; } }
      try {
        const r = await api.doSign(pl);
        if (String(r && r.code) === '200') { n++; mkDone(key); if (cfg.lowTrace || cfg.faceReport) await face(no, gps); say('签到成功 ' + c.courseName); }
        else say('签到失败 ' + JSON.stringify(r).slice(0, 120), 'err');
      } catch (e) { say('签到异常 ' + e, 'err'); }
      await SL(900 + Math.random() * 1800);
    }
    return n;
  } catch (e) { say(String(e && e.message || e), 'err'); return 0; } finally { busy = false; UI.refresh(); }
}
async function signout() {
  if (busy) return;
  if (!(await authOK())) { say('未登录，先登录再点签退', 'err'); return; }
  busy = true;
  try {
    const no = await studentNo();
    const r0 = await sched();
    for (const c of ((r0 && r0.data) || [])) {
      if (c.signOutTime || String(c.signOutStatus) === '1') continue;
      const w = WIN(c), t = new Date();
      if (!inW(t, w.signOut)) continue;
      const key = Y(t) + '|out|' + c.id;
      if (isDone(key)) continue;
      let gps;
      try { gps = await pick(c); } catch (e) { continue; }
      const ev = evl(c.roomGpsList, gps);
      say((cfg.commit ? '提交 ' : '演练 ') + '签退 ' + c.courseName + ' ' + gps);
      if (!cfg.commit) continue;
      try {
        const pl = { classDate: Y(t), studentNo: no, paikeId: c.id, gps };
        if (ev.status === '4') pl.signOutStatus = '4';
        const r = await api.doSignOut(pl);
        if (String(r && r.code) === '200') { mkDone(key); say('签退成功 ' + c.courseName); }
        else say('签退失败 ' + JSON.stringify(r).slice(0, 120), 'err');
      } catch (e) { say('签退异常 ' + e, 'err'); }
      await SL(900 + Math.random() * 1800);
    }
  } catch (e) { say(String(e && e.message || e), 'err'); } finally { busy = false; UI.refresh(); }
}
let tm = null, lk = null;
async function awake() { try { if ('wakeLock' in navigator) lk = await navigator.wakeLock.request('screen'); } catch (e) {} }
function start() {
  if (tm) return;
  awake();
  say('常驻启动，' + Math.round(cfg.intervalMs / 1000) + 's 一扫，提交=' + cfg.commit);
  const tick = async () => {
    try {
      if (cfg.lowTrace) { if (SC.date !== Y(new Date())) await sched(true); if (!near(cfg.idlePollMinutes)) { UI.refresh(); return; } }
      await sign(); await signout();
    } catch (e) { say('轮询异常 ' + (e && e.message || e), 'err'); }
    UI.refresh();
  };
  tick();
  tm = setInterval(tick, cfg.intervalMs);
  UI.refresh();
}
function stop() { if (tm) { clearInterval(tm); tm = null; say('常驻已停止'); } if (lk) { try { lk.release(); } catch (e) {} lk = null; } UI.refresh(); }
/* 手动探测：把真实返回码打在日志里，用来判断 cookie 够不够、接口通不通 */
async function probe() {
  try {
    if (!(await authOK())) { say('没有登录态：cookie 无 userToken', 'err'); return; }
    say('探测中…');
    const r = await api.schedule(Y(new Date()), await studentNo());
    say('探测 code=' + (r && r.code) + ' ' + String(JSON.stringify(r)).slice(0, 80));
  } catch (e) { say('探测失败 ' + (e && e.message || e), 'err'); }
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && tm && !lk) awake(); });
(function panel() {
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;right:8px;bottom:80px;z-index:2147483600;display:flex;flex-direction:column;align-items:flex-end;font:12px/1.5 sans-serif';
  const E = (t, css, x) => { const e = document.createElement(t); if (css) e.style.cssText = css; if (x != null) e.textContent = x; return e; };
  const B = 'flex:1;padding:8px 4px;border-radius:8px;border:1px solid rgb(55,65,81);background:rgb(31,41,55);color:rgb(229,231,235);font-size:12px';
  const ball = E('div', 'width:52px;height:52px;border-radius:50%;background:rgb(31,41,55);color:#fff;display:flex;align-items:center;justify-content:center;font:600 12px sans-serif;box-shadow:0 4px 14px rgba(0,0,0,.35);border:2px solid rgb(75,85,99)', '考勤');
  const box = E('div', 'display:none;width:248px;background:rgb(17,24,39);color:rgb(229,231,235);border-radius:12px;padding:8px;margin-bottom:8px');
  const st = E('div', 'color:rgb(156,163,175);margin-bottom:6px', '初始化…');
  const r1 = E('div', 'display:flex;gap:6px;margin:6px 0');
  const r2 = E('div', 'display:flex;gap:6px;margin:6px 0');
  const r3 = E('div', 'display:flex;gap:6px;margin:6px 0');
  const log = E('div', 'max-height:92px;overflow:auto;background:rgb(11,18,32);border-radius:8px;padding:6px;font:10px/1.5 monospace;color:rgb(156,163,175);white-space:pre-wrap');
  const btn = (l, f, ex) => { const b = E('button', B + (ex || ''), l); b.addEventListener('click', f); return b; };
  const b1 = btn('签到', () => sign());
  const b2 = btn('签退', () => signout());
  const b3 = btn('', () => { cfg.commit = !cfg.commit; save(); say(cfg.commit ? '已开启提交，会真签' : '已切回演练'); }, ';background:rgb(124,45,18)');
  const b4 = btn('', () => (tm ? stop() : start()));
  r1.appendChild(b1); r1.appendChild(b2); r2.appendChild(b3); r2.appendChild(b4);
  const b5 = btn('探测', () => probe(), ';background:rgb(30,58,138)');
  const b6 = btn('重载', () => location.reload());
  r3.appendChild(b5); r3.appendChild(b6);
  box.appendChild(st); box.appendChild(r1); box.appendChild(r2); box.appendChild(r3); box.appendChild(log);
  ball.addEventListener('click', () => { box.style.display = box.style.display === 'none' ? 'block' : 'none'; });
  host.appendChild(box); host.appendChild(ball);
  (document.body || document.documentElement).appendChild(host);
  UI = { refresh() {
    ball.style.background = cfg.commit ? 'rgb(153,27,27)' : 'rgb(31,41,55)';
    ball.textContent = cfg.commit ? '签·开' : '考勤';
    st.textContent = (STU || '--') + ' · ' + (tm ? (busy ? '扫描中' : '常驻中') : (busy ? '执行中' : '待机')) + ' · 提交' + (cfg.commit ? '开' : '关');
    b3.textContent = '提交:' + (cfg.commit ? '开' : '关');
    b4.textContent = '常驻:' + (tm ? '开' : '关');
    log.textContent = LG.join('\n');
    log.scrollTop = log.scrollHeight;
  } };
})();
(async () => {
  try {
    await waitMod(40);
    UI.refresh();
    if (!(await authOK())) {
      say('等待登录态：cookie 无 userToken，登录后自动开始');
      const iv = setInterval(async () => { if (await token0()) { clearInterval(iv); say('检测到登录，开始工作'); STU = await studentNo().catch(() => null); UI.refresh(); if (cfg.autoStart) start(); } }, 2000);
      setTimeout(() => clearInterval(iv), 600000);
      return;
    }
    STU = await studentNo().catch(() => null);
    say('已加载，学号 ' + (STU || '未知') + '，提交=' + cfg.commit);
    UI.refresh();
    if (cfg.autoStart) start();
  } catch (e) { say('初始化失败：' + (e && e.message || e), 'err'); UI.refresh(); }
})();
window.KQ = { cfg, saveCfg: save, sign, signout, startAuto: start, stopAuto: stop, studentNo, api, say, evaluate: evl, windows: WIN, pickGps: pick };
} catch (e) { console.error('[KQ] 启动失败', e); TO('KQ 启动失败：' + (e && e.message || e) + '\n截图发我', 'rgb(185,28,28)'); }
})();
