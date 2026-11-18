// ==UserScript==
// @name         山体智慧考勤 · DEBUG
// @namespace    kq.sdpei
// @version      1.4.7dbg
// @description  调试版：全量日志 / 状态快照 / 强制签到 / 日志导出
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
const TO = (m, c) => { try { const d = document.createElement('div'); d.textContent = m; d.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:2147483647;background:' + (c || 'rgb(185,28,28)') + ';color:#fff;font:12px/1.6 monospace;padding:8px 10px;border-radius:8px;max-width:92vw;white-space:pre-wrap'; (document.body || document.documentElement).appendChild(d); setTimeout(() => d.remove(), 40000); } catch (e) {} };
try {
const CF = 'kq_mobile_cfg', DN = 'kq_mobile_done', LF = 'kq_mobile_log', BF = 'kq_mobile_beat', UV = 147;
const cfg = Object.assign({ gpsMode: 'auto', fixedGps: '', jitterM: 8, lowTrace: true, jitterSigma: 10, arrivalSpreadMin: 20, idlePollMinutes: 40, leadMin: 10, outLeadMin: 5, outLagMin: 20, faceReport: false, intervalMs: 45000, commit: false, autoStart: true, debug: false }, JSON.parse(localStorage.getItem(CF) || '{}'));
if (cfg.uv !== UV) { cfg.uv = UV; cfg.debug = true; cfg.intervalMs = 15000; cfg.idlePollMinutes = 600; cfg.autoStart = true; localStorage.setItem(CF, JSON.stringify(cfg)); }
const save = () => localStorage.setItem(CF, JSON.stringify(cfg));
const N2 = n => String(n).padStart(2, '0');
const Y = d => d.getFullYear() + '-' + N2(d.getMonth() + 1) + '-' + N2(d.getDate());
const HM = d => N2(d.getHours()) + ':' + N2(d.getMinutes());
const ST = d => Y(d) + ' ' + HM(d) + ':' + N2(d.getSeconds());
const SL = ms => new Promise(r => setTimeout(r, ms));
const DM = (() => { try { return JSON.parse(localStorage.getItem(DN) || '{}'); } catch (e) { return {}; } })();
const isDone = k => (DM[Y(new Date())] || []).indexOf(k) >= 0;
const mkDone = k => { const d = Y(new Date()); (DM[d] = DM[d] || []).push(k); localStorage.setItem(DN, JSON.stringify(DM)); };
const undDone = k => { const d = Y(new Date()); const a = DM[d] || []; const i = a.indexOf(k); if (i >= 0) a.splice(i, 1); try { localStorage.setItem(DN, JSON.stringify(DM)); } catch (e) {} };
const GS = () => { let u = 0, v = 0; while (!u) u = Math.random(); while (!v) v = Math.random(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };
const UID = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxxyxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }) + Date.now().toString(16));
/* ---------- 日志：内存 400 条 + 落 localStorage，刷新不丢，可导出 ---------- */
let LB = [];
try { LB = JSON.parse(localStorage.getItem(LF) || '[]') || []; } catch (e) { LB = []; }
let SF = 0;
const flush = () => { if (SF) return; SF = 1; setTimeout(() => { SF = 0; try { localStorage.setItem(LF, JSON.stringify(LB)); } catch (e) {} }, 400); };
const J = o => { try { return JSON.stringify(o); } catch (e) { return String(o); } };
let UI = { refresh() {} };
const say = (m, lv) => { const d = new Date(); const line = (lv === 'err' ? '×' : '·') + N2(d.getHours()) + ':' + N2(d.getMinutes()) + ':' + N2(d.getSeconds()) + ' ' + m; LB.push(line); if (LB.length > 400) LB.splice(0, LB.length - 400); flush(); try { UI.refresh(); } catch (e) {} console.log('[KQ]', m); };
const clip = (s, n) => { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '…' : s; };
/* ---------- 站点模块 ---------- */
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
async function waitMod(n) { let e; for (let i = 0; i < n; i++) { try { return await mod(); } catch (x) { e = x; if (i < n - 1) await SL(1000); } } throw e; }
async function token0() { try { const M = await mod(); return (M.k && typeof M.k.get === 'function' ? M.k.get('JwtToken', true, 'STR') : '') || ''; } catch (e) { return ''; } }
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
  try { const i = await api.myInfo(); const m = J(i).match(/"staffCode"\s*:\s*"([^"]+)"/); if (m) STU = m[1]; } catch (e) {}
  if (!STU) STU = scan();
  if (!STU) throw new Error('拿不到学号');
  return STU;
}
/* ---------- 地理 ---------- */
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
/* 服务端给的真实可点区间，例如 signInClickRange="13:40-15:35" */
function RNG(s) {
  if (!s) return null;
  const a = String(s).split('-');
  if (a.length < 2 || !a[0] || !a[1]) return null;
  try { const d = Y(new Date()); return [AT(d, a[0]), AT(d, a[1])]; } catch (e) { return null; }
}
function WIN(c) {
  const d = Y(new Date()), s = AT(d, c.startTime), e = AT(d, c.endTime);
  /* 签到：我们的默认是「上课前 5 分钟 ~ 下课」；
     但一定要夹在服务端 signInClickRange 里，免得白打被拒。*/
  const ci = RNG(c.signInClickRange) || [new Date(+s - 600000), e];
  const co = RNG(c.signOutClickRange) || [new Date(+e - 300000), new Date(+e + 1200000)];
  const lo = new Date(Math.max(+ci[0], +s - 300000));
  const hi = new Date(Math.min(+ci[1], +e));
  const olo = new Date(Math.max(+co[0], +e - cfg.outLeadMin * 60000));
  const ohi = new Date(Math.min(+co[1], +e + cfg.outLagMin * 60000));
  return { signIn: [lo, hi], signOut: [olo, ohi], click: { ci, co } };
}
/* 已签到判定：状态 1/2/3，或者已经有首次签到时间 */
const signedIn = c => ['1', '2', '3'].indexOf(String(c.signInStatus)) >= 0 || !!c.firstSignInTime;
const signedOut = c => String(c.signOutStatus) === '1' || !!c.signOutTime;
const inW = (t, w) => t >= w[0] && t <= w[1];
/* ---------- 主流程 ---------- */
let busy = false, TN = 0;
const seen = new Set(), arr = new Map(), stt = {};
function net() { const c = navigator.connection || navigator.mozConnection || {}; return [navigator.onLine, c.type || '', c.effectiveType || '', c.downlink || ''].join('|'); }
async function chain(no, gps, ev, inF) {
  const lng = Number(gps.split(',')[0]), lat = Number(gps.split(',')[1]);
  const dist = Number.isFinite(ev && ev.distance) ? Number(ev.distance.toFixed(1)) : 0;
  const n0 = net();
  const gd = () => { if (cfg.lowTrace && net() !== n0) throw new Error('网络已切换，链路中止'); };
  try { const r = await api.faceReport({ uuid: UID(), user_id: no, latitude: String(lat), longitude: String(lng), altitude: inF ? 1 : 0, accuracy: dist, altitudeAccuracy: inF ? 0 : 4, time: ST(new Date()) }); if (cfg.debug) say('  预记录 ' + clip(J(r), 90)); } catch (e) { say('预记录失败 ' + clip(e, 90), 'err'); }
  gd();
  try { const r = await api.mobileLog({ userId: no, type: '3', message: gps }); if (cfg.debug) say('  mobileLog ' + clip(J(r), 90)); } catch (e) { say('mobileLog失败 ' + clip(e, 90), 'err'); }
  gd();
  await SL(8000 + Math.random() * 12000);
  gd();
}
async function face(no, gps) {
  const p = gps.split(',');
  try { const r = await api.faceReport({ uuid: UID(), user_id: no, score: Number((0.52 + Math.random() * 0.19).toFixed(4)), threshold: 0.45, status: 'PASS', latitude: p[0], longitude: p[1], altitude: 0, accuracy: 0, altitudeAccuracy: 0, time: ST(new Date()) }); if (cfg.debug) say('  人脸结果 ' + clip(J(r), 90)); } catch (e) { say('人脸结果失败 ' + clip(e, 90), 'err'); }
}
let SC = { at: 0, date: '', data: [] };
async function sched(f) {
  const d = Y(new Date()), n = Date.now();
  if (!f && SC.date === d && n - SC.at < 600000) return { code: '200', data: SC.data, cached: 1 };
  const r = await api.schedule(d, await studentNo());
  if (r && String(r.code) === '200') SC = { at: n, date: d, data: r.data || [] };
  if (cfg.debug) say('课表 code=' + (r && r.code) + ' 条数=' + ((r && r.data) || []).length + (f ? ' (强制)' : ''));
  return r;
}
function near(m) {
  const t = new Date(), k = m == null ? 40 : m;
  return (SC.data || []).some(c => { const w = WIN(c); return t >= new Date(+w.signIn[0] - k * 60000) && t <= new Date(+w.signOut[1] + k * 60000); });
}
/* 每门课只打一次状态翻转，不刷屏 */
function note(c, s, msg) {
  const k = Y(new Date()) + '|' + c.id;
  if (stt[k] === s) return;
  stt[k] = s;
  say(c.courseName + ' ' + msg);
}
/* 提交后回查服务端，确认真入账（不看 code 200 自嗨） */
async function confirmSign(no, id) {
  await SL(2500);
  try {
    const r = await api.schedule(Y(new Date()), no);
    const c = ((r && r.data) || []).find(x => String(x.id) === String(id));
    if (!c) { say('  确认：课表里没找到这门课'); return false; }
    const ok = signedIn(c);
    say('  确认 status=' + c.signInStatus + ' 首次=' + (c.firstSignInTime || '-') + (ok ? ' ✓ 已入账' : ' ✗ 服务端没记录'));
    return ok;
  } catch (e) { say('  确认失败 ' + clip((e && e.message) || e, 80), 'err'); return false; }
}
async function sign(force) {
  if (busy) return 0;
  busy = true;
  try {
    const cm = force || cfg.commit;
    if (!(await authOK())) { say('未登录，先登录再点签到', 'err'); return 0; }
    const no = await studentNo();
    const r0 = await sched(force ? 1 : 0);
    const cs = (r0 && r0.data) || [];
    if (!cs.length) { say('今日无课 (code=' + (r0 && r0.code) + ')'); return 0; }
    let n = 0;
    for (const c of cs) {
      const sst = String(c.signInStatus);
      if (!force && signedIn(c)) { if (cfg.debug) note(c, 's' + sst, '已签到(status=' + sst + ' 首次=' + (c.firstSignInTime || '-') + ')，跳过'); continue; }
      const w = WIN(c), t = new Date();
      if (!force && !inW(t, w.signIn)) {
        if (cfg.debug) { const s = t < w.signIn[0] ? 'w' : 'e'; note(c, s, s === 'w' ? ('窗外，' + HM(w.signIn[0]) + ' 才开始，现在 ' + HM(t)) : '窗口已过'); }
        continue;
      }
      const key = Y(t) + '|' + c.id;
      if (!force && isDone(key)) { if (cfg.debug) note(c, 'd', '今天已标记完成'); continue; }
      if (!force && cfg.lowTrace) {
        if (!arr.has(key)) { const sp = (cfg.arrivalSpreadMin == null ? 20 : cfg.arrivalSpreadMin) * 60000; const tg = Math.min(+w.signIn[0] + Math.random() * sp, +AT(Y(t), c.startTime) + 300000); arr.set(key, new Date(Math.max(tg, Date.now()))); }
        const eta = arr.get(key);
        if (eta - t > 1000) { note(c, 'a', '已排队，' + HM(eta) + ' 出发'); continue; }
      }
      let gps;
      try { gps = await pick(c); } catch (e) { say(c.courseName + '：' + e.message, 'err'); continue; }
      const ev = evl(c.roomGpsList, gps);
      const inF = ev.status === '3';
      const pl = { classDate: Y(t), studentNo: no, paikeId: c.id, signType: sst === '2' ? '2' : '1', gps };
      if (!inF) pl.signInStatus = '4';
      if (String(c.extendStatus) === '4') pl.signInStatus = '4';
      say((cm ? '提交' : '演练') + '签到 ' + c.courseName + ' gps=' + gps + ' 距' + ev.distance.toFixed(0) + 'm 状态' + sst);
      if (cfg.debug) say('  payload ' + J(pl));
      if (!cm) { if (!seen.has(key)) { seen.add(key); say('  (演练模式，没真发)'); } continue; }
      if (cfg.lowTrace || cfg.faceReport) { try { await chain(no, gps, ev, inF); } catch (e) { say(String(e.message || e), 'err'); continue; } }
      try {
        const r = await api.doSign(pl);
        say('  doSign → ' + clip(J(r), 200));
        if (String(r && r.code) === '200') {
          n++; mkDone(key);
          if (cfg.lowTrace || cfg.faceReport) await face(no, gps);
          const cf = await confirmSign(no, c.id);
          if (cf) say('✓ 签到成功 ' + c.courseName);
          else { undDone(key); say('! 接口返回 200 但服务端没记录，下一轮重试 ' + c.courseName, 'err'); }
          SC.at = 0;
        }
        else say('× 签到失败 ' + clip(J(r), 160), 'err');
      } catch (e) { say('× 签到异常 ' + clip((e && (e.msg || e.message)) || e, 160), 'err'); }
      await SL(900 + Math.random() * 1800);
    }
    return n;
  } catch (e) { say('× ' + clip((e && (e.msg || e.message)) || e, 160), 'err'); return 0; } finally { busy = false; UI.refresh(); }
}
/* 强制：不看窗口不看状态，直接打 doSign，把服务端原话打出来 */
async function force() {
  if (busy) { say('忙，等一下'); return; }
  busy = true;
  try {
    say('=== 强制签到开始 ===');
    if (!(await authOK())) { say('未登录：cookie 无 userToken 且不在 /pages/kq/', 'err'); return; }
    const no = await studentNo();
    say('学号 ' + no);
    const r0 = await api.schedule(Y(new Date()), no);
    say('课表 code=' + (r0 && r0.code) + ' 条数=' + ((r0 && r0.data) || []).length);
    const cs = (r0 && r0.data) || [];
    if (!cs.length) { say('今天没课'); return; }
    for (const c of cs) {
      const w = WIN(c);
      say('— ' + c.courseName + ' id=' + c.id + ' ' + c.startTime + '-' + c.endTime + ' status=' + c.signInStatus + ' 首次=' + (c.firstSignInTime || '-'));
      say('  可点 ' + (c.signInClickRange || '-') + ' 我夹在 ' + HM(w.signIn[0]) + '~' + HM(w.signIn[1]) + ' 现在' + (inW(new Date(), w.signIn) ? '在窗内' : '窗外'));
      if (signedIn(c)) { say('  已签到(首次=' + (c.firstSignInTime || String(c.signInStatus)) + ')，跳过'); continue; }
      let gps;
      try { gps = await pick(c); } catch (e) { say('  无坐标：' + e.message, 'err'); continue; }
      const ev = evl(c.roomGpsList, gps);
      const sst = String(c.signInStatus);
      const pl = { classDate: Y(new Date()), studentNo: no, paikeId: c.id, signType: sst === '2' ? '2' : '1', gps };
      if (ev.status !== '3') pl.signInStatus = '4';
      if (String(c.extendStatus) === '4') pl.signInStatus = '4';
      say('  围栏判定 ' + ev.status + ' 距' + ev.distance.toFixed(0) + 'm ' + (pl.signInStatus ? '带 signInStatus=4' : '围栏内'));
      say('  POST doSign ' + J(pl));
      try {
        const r = await api.doSign(pl);
        say('  RESP ' + J(r));
        if (String(r && r.code) === '200') {
          mkDone(Y(new Date()) + '|' + c.id);
          const cf = await confirmSign(no, c.id);
          say(cf ? '  ✓ 成功且已入账' : '  ! 200 但服务端没记录', cf ? undefined : 'err');
          SC.at = 0;
        }
      } catch (e) { say('  × 异常 ' + clip((e && (e.msg || e.message)) || e, 160), 'err'); }
      await SL(1200);
    }
    say('=== 强制签到结束 ===');
  } catch (e) { say('× 强制失败 ' + clip((e && (e.msg || e.message)) || e, 160), 'err'); } finally { busy = false; UI.refresh(); }
}
/* 状态快照：把服务端今天所有字段原样打出来 */
async function dump() {
  const d = new Date();
  say('── 快照 ' + ST(d) + ' tz' + (-d.getTimezoneOffset()) + 'min');
  say('url=' + location.pathname + ' cookie=' + (J(document.cookie).indexOf('userToken=') >= 0 ? 'Y' : 'N') + ' cfg=' + J({ commit: cfg.commit, iv: cfg.intervalMs, lt: cfg.lowTrace, gps: cfg.gpsMode, dbg: cfg.debug }));
  let tk = ''; try { tk = await token0(); } catch (e) {}
  say('JwtToken=' + (tk ? 'Y' + tk.length : 'N'));
  let no = null; try { no = await studentNo(); say('学号=' + no); } catch (e) { say('学号失败 ' + e.message, 'err'); }
  if (!no) return;
  let r;
  try { r = await api.schedule(Y(d), no); } catch (e) { say('课表异常 ' + clip((e && (e.message || e.msg)) || e, 160), 'err'); return; }
  say('课表 code=' + (r && r.code) + ' msg=' + ((r && (r.msg || r.message)) || '') + ' 条数=' + (((r && r.data) || []).length));
  const cs = (r && r.data) || [];
  if (cs.length) say('RAW ' + clip(J(cs), 2800));
  cs.forEach(c => {
    const w = WIN(c);
    say('· ' + c.courseName + ' status=' + c.signInStatus + ' ext=' + c.extendStatus + ' out=' + c.signOutStatus);
    say('  首次签=' + (c.firstSignInTime || '-') + ' 签退=' + (c.signOutTime || '-') + ' 已签=' + signedIn(c) + '/' + signedOut(c));
    say('  上课 ' + c.startTime + '-' + c.endTime + ' 可点 ' + (c.signInClickRange || '-') + ' / ' + (c.signOutClickRange || '-'));
    say('  我将签 ' + HM(w.signIn[0]) + '~' + HM(w.signIn[1]) + ' 现在' + (inW(d, w.signIn) ? '在窗内' : '窗外') + ' done=' + isDone(Y(d) + '|' + c.id));
  });
}
/* 日志导出：大字号只读框 + 复制 */
function exportLog() {
  const old = document.getElementById('kqexp');
  if (old) old.remove();
  const wrap = document.createElement('div');
  wrap.id = 'kqexp';
  wrap.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,.86);padding:10px;display:flex;flex-direction:column;gap:8px';
  const ta = document.createElement('textarea');
  ta.value = LB.join('\n');
  ta.style.cssText = 'flex:1;width:100%;box-sizing:border-box;background:#0b1220;color:#d1d5db;border:1px solid #374151;border-radius:8px;padding:8px;font:11px/1.45 monospace;white-space:pre;-webkit-user-select:text;user-select:text';
  ta.setAttribute('readonly', 'readonly');
  const bar = document.createElement('div');
  bar.style.cssText = 'display:flex;gap:8px';
  const mk = (t, f, bg) => { const b = document.createElement('button'); b.textContent = t; b.style.cssText = 'flex:1;padding:12px;border-radius:10px;border:1px solid #374151;background:' + (bg || '#1f2937') + ';color:#e5e7eb;font-size:14px'; b.addEventListener('click', f); return b; };
  bar.appendChild(mk('复制全部', async () => {
    try { if (navigator.clipboard && navigator.clipboard.writeText) { await navigator.clipboard.writeText(ta.value); TO('已复制 ' + ta.value.length + ' 字符', 'rgb(21,128,61)'); return; } } catch (e) {}
    try { ta.removeAttribute('readonly'); ta.focus(); ta.select(); document.execCommand('copy'); ta.setAttribute('readonly', 'readonly'); TO('已复制（旧方式）', 'rgb(21,128,61)'); } catch (e) { TO('复制失败，长按框内手动全选'); }
  }, '#166534'));
  bar.appendChild(mk('关闭', () => wrap.remove()));
  wrap.appendChild(ta);
  wrap.appendChild(bar);
  (document.body || document.documentElement).appendChild(wrap);
  setTimeout(() => { try { ta.scrollTop = ta.scrollHeight; } catch (e) {} }, 60);
}
function clearLog() { LB.length = 0; try { localStorage.removeItem(LF); } catch (e) {} say('日志已清空'); UI.refresh(); }
/* ---------- 常驻 ---------- */
let tm = null, lk = null;
async function awake() { try { if ('wakeLock' in navigator) lk = await navigator.wakeLock.request('screen'); } catch (e) {} }
function beat(extra) { try { const o = { at: Date.now(), n: TN, v: UV, extra: extra || '' }; localStorage.setItem(BF, J(o)); } catch (e) {} }
function start() {
  if (tm) return;
  awake();
  say('常驻启动 ' + Math.round(cfg.intervalMs / 1000) + 's/扫 提交=' + cfg.commit + ' 低痕迹=' + cfg.lowTrace);
  const tick = async () => {
    TN++;
    try {
      if (cfg.debug && TN % 4 === 1) say('心跳#' + TN + ' ' + (near() ? 'near' : 'idle') + ' 课' + (SC.data || []).length);
      beat();
      if (cfg.lowTrace && !cfg.debug) { if (SC.date !== Y(new Date())) await sched(true); if (!near(cfg.idlePollMinutes)) { UI.refresh(); return; } }
      await sign(); await signout();
    } catch (e) { say('× 轮询异常 ' + clip((e && e.message) || e, 140), 'err'); }
    UI.refresh();
  };
  tick();
  tm = setInterval(tick, cfg.intervalMs);
  UI.refresh();
}
function stop() { if (tm) { clearInterval(tm); tm = null; say('常驻已停止'); } if (lk) { try { lk.release(); } catch (e) {} lk = null; } UI.refresh(); }
async function signout() {
  if (busy) return;
  if (!(await authOK())) return;
  busy = true;
  try {
    const no = await studentNo();
    const r0 = await sched();
    for (const c of ((r0 && r0.data) || [])) {
      if (signedOut(c)) continue;
      const w = WIN(c), t = new Date();
      if (!inW(t, w.signOut)) continue;
      const key = Y(t) + '|out|' + c.id;
      if (isDone(key)) continue;
      let gps;
      try { gps = await pick(c); } catch (e) { continue; }
      const ev = evl(c.roomGpsList, gps);
      say((cfg.commit ? '提交' : '演练') + '签退 ' + c.courseName);
      if (!cfg.commit) continue;
      try {
        const pl = { classDate: Y(t), studentNo: no, paikeId: c.id, gps };
        if (ev.status === '4') pl.signOutStatus = '4';
        const r = await api.doSignOut(pl);
        if (cfg.debug) say('  doSignOut → ' + clip(J(r), 160));
        if (String(r && r.code) === '200') { mkDone(key); say('✓ 签退成功 ' + c.courseName); SC.at = 0; }
        else say('× 签退失败 ' + clip(J(r), 140), 'err');
      } catch (e) { say('× 签退异常 ' + clip((e && (e.msg || e.message)) || e, 140), 'err'); }
      await SL(900 + Math.random() * 1800);
    }
  } catch (e) { say('× ' + clip((e && e.message) || e, 140), 'err'); } finally { busy = false; UI.refresh(); }
}
async function probe() {
  try {
    if (!(await authOK())) { say('没有登录态', 'err'); return; }
    const r = await api.schedule(Y(new Date()), await studentNo());
    say('探测 code=' + (r && r.code) + ' ' + clip(J(r), 200));
  } catch (e) { say('探测失败 ' + clip((e && (e.message || e.msg)) || e, 160), 'err'); }
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && tm && !lk) awake(); });
/* ---------- 面板 ---------- */
(function panel() {
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;right:8px;bottom:80px;z-index:2147483600;display:flex;flex-direction:column;align-items:flex-end;font:12px/1.5 sans-serif';
  const E = (t, css, x) => { const e = document.createElement(t); if (css) e.style.cssText = css; if (x != null) e.textContent = x; return e; };
  const B = 'flex:1;padding:8px 4px;border-radius:8px;border:1px solid rgb(55,65,81);background:rgb(31,41,55);color:rgb(229,231,235);font-size:12px';
  const ball = E('div', 'width:52px;height:52px;border-radius:50%;background:rgb(31,41,55);color:#fff;display:flex;align-items:center;justify-content:center;font:600 12px sans-serif;box-shadow:0 4px 14px rgba(0,0,0,.35);border:2px solid rgb(75,85,99)', '考勤');
  const box = E('div', 'display:none;width:268px;background:rgb(17,24,39);color:rgb(229,231,235);border-radius:12px;padding:8px;margin-bottom:8px');
  const st = E('div', 'color:rgb(156,163,175);margin-bottom:6px', 'init…');
  const log = E('div', 'max-height:190px;overflow:auto;background:rgb(11,18,32);border-radius:8px;padding:6px;font:10px/1.45 monospace;color:rgb(156,163,175);white-space:pre-wrap;-webkit-user-select:text;user-select:text');
  const btn = (l, f, ex) => { const b = E('button', B + (ex || ''), l); b.addEventListener('click', f); return b; };
  const rows = [E('div', 'display:flex;gap:6px;margin:6px 0'), E('div', 'display:flex;gap:6px;margin:6px 0'), E('div', 'display:flex;gap:6px;margin:6px 0')];
  const b1 = btn('签到', () => sign());
  const b2 = btn('签退', () => signout());
  const b3 = btn('', () => { cfg.commit = !cfg.commit; save(); say(cfg.commit ? '已开启提交，会真签' : '已切回演练'); }, ';background:rgb(124,45,18)');
  const b4 = btn('', () => (tm ? stop() : start()));
  const b5 = btn('探测', () => probe(), ';background:rgb(30,58,138)');
  const b6 = btn('状态', () => dump(), ';background:rgb(120,53,15)');
  const b7 = btn('强签', () => force(), ';background:rgb(153,27,27)');
  const b8 = btn('导出', () => exportLog(), ';background:rgb(22,101,52)');
  rows[0].appendChild(b1); rows[0].appendChild(b2); rows[0].appendChild(b5);
  rows[1].appendChild(b3); rows[1].appendChild(b4); rows[1].appendChild(b7);
  rows[2].appendChild(b6); rows[2].appendChild(b8); rows[2].appendChild(btn('清空', () => clearLog()));
  box.appendChild(st);
  rows.forEach(r => box.appendChild(r));
  box.appendChild(log);
  ball.addEventListener('click', () => { box.style.display = box.style.display === 'none' ? 'block' : 'none'; });
  host.appendChild(box); host.appendChild(ball);
  (document.body || document.documentElement).appendChild(host);
  UI = { refresh() {
    ball.style.background = cfg.commit ? 'rgb(153,27,27)' : 'rgb(31,41,55)';
    ball.textContent = cfg.commit ? '签·开' : '考勤';
    st.textContent = (STU || '--') + ' · ' + (tm ? (busy ? '执行中' : '常驻中') : (busy ? '执行中' : '待机')) + ' · 提交' + (cfg.commit ? '开' : '关') + ' · ' + LB.length + '行';
    b3.textContent = '提交:' + (cfg.commit ? '开' : '关');
    b4.textContent = '常驻:' + (tm ? '开' : '关');
    log.textContent = LB.slice(-200).join('\n');
    if (box.style.display !== 'none') log.scrollTop = log.scrollHeight;
  } };
})();
/* ---------- 启动 ---------- */
(async () => {
  try {
    let last = '';
    try { const b = JSON.parse(localStorage.getItem(BF) || 'null'); if (b && b.at) last = '上次心跳 ' + ST(new Date(b.at)) + ' #' + b.n; } catch (e) {}
    say('=== 1.4.7dbg 启动 ' + ST(new Date()) + ' ===');
    if (last) say(last + '（说明刷新过/被杀过）');
    await waitMod(40);
    UI.refresh();
    if (!(await authOK())) {
      say('等登录态：cookie 无 userToken，登录后自动开始');
      const iv = setInterval(async () => { if (await token0()) { clearInterval(iv); say('检测到登录'); STU = await studentNo().catch(() => null); UI.refresh(); if (cfg.autoStart) start(); } }, 2000);
      setTimeout(() => clearInterval(iv), 600000);
      return;
    }
    STU = await studentNo().catch(() => null);
    say('已加载 学号=' + (STU || '未知') + ' 提交=' + cfg.commit);
    UI.refresh();
    if (cfg.autoStart) start();
  } catch (e) { say('× 初始化失败 ' + clip((e && e.message) || e, 160), 'err'); UI.refresh(); }
})();
window.KQ = { cfg, saveCfg: save, sign, signout, signForce: force, dump, exportLog, clearLog, startAuto: start, stopAuto: stop, studentNo, api, say, evaluate: evl, windows: WIN, pickGps: pick, log: () => LB.join('\n') };
} catch (e) { console.error('[KQ] 启动失败', e); TO('KQ 启动失败：' + (e && e.message || e) + '\n截图发我', 'rgb(185,28,28)'); }
})();
