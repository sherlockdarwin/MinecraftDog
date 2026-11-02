// Waveform / curve figures drawn from simulation data (wavedata.js).
const fmtv = (v, f) => {
  if (v === null || v === undefined) return 'x';
  if (f === 'ascii') return v >= 32 && v < 127 ? `'${String.fromCharCode(v)}'` : `0x${v.toString(16)}`;
  if (f === 'sdec8') return String(v >= 128 ? v - 256 : v);
  if (f === 'sdec14') { const s = v >= 8192 ? v - 16384 : v; return (s >= 0 ? '+' : '') + s; }
  if (f === 'hex') return '0x' + v.toString(16).toUpperCase().padStart(4, '0');
  return String(v);
};
function at(c, t) { let v = null; for (const [tt, vv] of c) { if (tt <= t) v = vv; else break; } return v; }

// rows: [{c, fmt, label, h}] ; returns y of bottom
function waves(rows, o) {
  const { x0, x1, ytop, tw0, tw1 } = o;
  const tx = t => x0 + (t - tw0) / (tw1 - tw0) * (x1 - x0);
  let y = ytop;
  rows.forEach((r, k) => {
    const h = r.h || 0.62, yc = y - h / 2, amp = h * 0.32;
    if (k % 2 === 0) rect(x0, y - h, x1 - x0, h, { fc: '#FAFAFA', z: 1 });
    label(x0 - 0.15, yc, r.label, { fs: 8.5, ha: 'right', color: '#263238', family: 'Consolas,monospace' });
    const c = r.c.filter(([t]) => t <= tw1);
    const segs = [];
    for (let i = 0; i < c.length; i++) {
      const ta = Math.max(c[i][0], tw0), tb = i + 1 < c.length ? Math.min(c[i + 1][0], tw1) : tw1;
      if (tb < tw0 || tb <= ta && i + 1 < c.length && c[i + 1][0] <= tw0) continue;
      segs.push([ta, tb, c[i][1]]);
    }
    if (r.fmt === 'bit') {
      const pts = []; let last = null;
      for (const [ta, tb, v] of segs) {
        const yy = v === null ? yc : (v ? yc + amp : yc - amp);
        if (last !== null) pts.push([tx(ta), last]);
        pts.push([tx(ta), yy], [tx(tb), yy]); last = yy;
      }
      line(pts, { color: r.color || '#1565C0', lw: r.lw || 1.1, z: 4 });
    } else {
      for (const [ta, tb, v] of segs) {
        const xa = tx(ta), xb = tx(tb), s = Math.min(0.06, (xb - xa) / 3);
        if (xb - xa < 0.005) continue;
        polygon([[xa, yc], [xa + s, yc + amp], [xb - s, yc + amp], [xb, yc], [xb - s, yc - amp], [xa + s, yc - amp]],
          { fc: v === null ? '#ECEFF1' : (r.fill || '#E3F2FD'), ec: '#1565C0', lw: 0.9, z: 3 });
        const txt = r.map ? r.map(v) : fmtv(v, r.fmt);
        const wtxt = txt.length * 8 * 0.6 / 44.64 + 0.08;
        if (v !== null && xb - xa > wtxt) label((xa + xb) / 2, yc, txt, { fs: 8, color: '#0D47A1', family: 'Consolas,monospace' });
      }
    }
    y -= h;
  });
  return y;
}
function taxis(o, y, step, unit, scale, t0lab = 0) {
  const { x0, x1, tw0, tw1 } = o;
  line([[x0, y], [x1, y]], { color: '#607D8B', lw: 0.8 });
  for (let t = tw0; t <= tw1 + 1; t += step) {
    const x = x0 + (t - tw0) / (tw1 - tw0) * (x1 - x0);
    line([[x, y], [x, y - 0.08]], { color: '#607D8B', lw: 0.8 });
    label(x, y - 0.25, `${((t - tw0) / scale + t0lab).toFixed(0)}`, { fs: 7.5, color: '#546E7A' });
  }
  label(x1 + 0.15, y - 0.25, unit, { fs: 7.5, color: '#546E7A', ha: 'left' });
}
function uartDecode(c, t0, t1, bitps) {          // bytes from a TX line: [[tstart, tend, byte]]
  const out = []; let t = t0;
  const lvl = tt => at(c, tt);
  for (let i = 0; i < c.length; i++) {
    const [tt, v] = c[i];
    if (tt < t || tt > t1 || v !== 0) continue;
    if (lvl(tt - 1) !== 1) continue;
    let b = 0;
    for (let k = 0; k < 8; k++) if (lvl(tt + (1.5 + k) * bitps) === 1) b |= 1 << k;
    out.push([tt, tt + 10 * bitps, b]);
    t = tt + 9.5 * bitps;
  }
  return out;
}

FIGS.wave_m0 = () => {
  const W = 20, H = 8.6; canvas(W, H);
  const x0 = 2.6, x1 = 19.0;
  const get = (D, n) => D.sig.find(s => s.name === n);
  label(0.2, 8.3, "(a) 接收：STM32 → FPGA  \"$l12350&\"（主人在左 12°、350 cm）", { fs: 9.5, ha: 'left', bold: true, color: '#263238' });
  const oa = { x0, x1, ytop: 7.85, tw0: 0, tw1: 800e6 };
  let y = waves([
    { c: get(D_RX, 'I_rx').c, fmt: 'bit', label: 'I_rx' },
    { c: get(D_RX, 'u_rx.O_valid').c, fmt: 'bit', label: 'rx_valid', color: '#E65100' },
    { c: get(D_RX, 'u_rx.O_data').c, fmt: 'ascii', label: 'rx_data' },
    { c: get(D_RX, 'O_tgt_deg').c, fmt: 'sdec8', label: 'O_tgt_deg' },
    { c: get(D_RX, 'O_tgt_cm').c, fmt: 'dec', label: 'O_tgt_cm' },
    { c: get(D_RX, 'O_tgt_ok').c, fmt: 'bit', label: 'O_tgt_ok' }], oa);
  taxis(oa, y, 100e6, 'μs', 1e6);
  const ccm = get(D_RX, "O_tgt_cm").c, tend = ccm[ccm.length - 1][0], xe = x0 + tend / 800e6 * (x1 - x0);
  line([[xe, 7.85], [xe, y]], { color: '#E53935', lw: 0.9, ls: '--', z: 5 });
  label(xe - 0.1, y + 0.45, '收到 "&" 后当拍更新：角度 −12、距离 350、有效 = 1', { fs: 8, ha: 'right', color: '#C62828', bbox: true });
  // TX
  const cv = get(D_TX, 'I_cmd_valid').c, tv = cv.filter(([t, v], i) => v === 1 && i > 0 && cv[i - 1][1] === 0)[0][0];
  const ob = { x0, x1, ytop: 2.9, tw0: tv - 30e6, tw1: tv + 1170e6 };
  const bytes = uartDecode(get(D_TX, 'O_tx').c, ob.tw0, ob.tw1, 1e12 / 115200);
  const fs_ = bytes.map(b => String.fromCharCode(b[2])).join(''), frame = fs_.slice(0, fs_.indexOf('*') + 1);
  label(0.2, 3.35, `(b) 发送：FPGA → STM32  "${frame}"（左轮 +3000、右轮 −500）`, { fs: 9.5, ha: 'left', bold: true, color: '#263238' });
  y = waves([
    { c: cv, fmt: 'bit', label: 'I_cmd_valid', color: '#E65100' },
    { c: get(D_TX, 'O_tx').c, fmt: 'bit', label: 'O_tx' },
    { c: [[ob.tw0, null], ...bytes.flatMap(b => [[b[0], b[2]], [b[1], null]])], fmt: 'ascii', label: '线上字节', fill: '#FFF3E0' }], ob);
  taxis(ob, y, 100e6, 'μs', 1e6);
  const xv = x0 + (tv - ob.tw0) / (ob.tw1 - ob.tw0) * (x1 - x0);
  label(xv + 0.12, 2.9 - 0.31, "这一拍锁存 L = +3000、R = −500，之后输入再变也不影响正在发的帧", { fs: 8, ha: "left", color: "#C62828", bbox: true });
  label(0.2, 0.12, "115200 8N1，每位 8.68 μs；接收端在每一位中点取样，帧格式不对整帧丢弃（仿真：tb_m0_link）", { fs: 8, ha: 'left', color: '#546E7A' });
};

FIGS.wave_i2s = () => {
  const W = 20, H = 5.6; canvas(W, H);
  const get = n => D_I2S.sig.find(s => s.name === n);
  const lr = get('O_lrck').c, val = get('I_valid').c;
  const tval = val.find(([t, v]) => v === 1)[0];
  const edges = lr.filter(([t, v], i) => i > 0 && v === 0 && t > tval + 25e6);
  const te = edges[0][0];
  const o = { x0: 2.2, x1: 19.2, ytop: 4.85, tw0: te - 0.6e6, tw1: te + 21.0e6 };
  // decode the left/right words from DSDIN at SCLK rising edges
  const sc = get('O_sclk').c, dd = get('O_dsdin').c;
  const rises = sc.filter(([t, v], i) => i > 0 && v === 1 && t > te && t < te + 20.5e6).map(([t]) => t);
  const word = (k0) => { let w = 0; for (let k = 0; k < 16; k++) w = (w << 1) | (at(dd, rises[k0 + k] + 1) ? 1 : 0); return w; };
  const wl = word(1), wr = word(33);
  label(0.2, 5.3, `I2S 一帧（LRCK 48.828 kHz，SCLK = 64 × LRCK，MCLK 12.5 MHz）：左声道解出 0x${wl.toString(16).toUpperCase().padStart(4, '0')}，右声道解出 0x${wr.toString(16).toUpperCase().padStart(4, "0")}（与送入的采样逐帧比对一致）`, { fs: 9, ha: 'left', bold: true, color: '#263238' });
  const y = waves([
    { c: get('O_mclk').c, fmt: 'bit', label: 'O_mclk', lw: 0.6, h: 0.55 },
    { c: get('O_sclk').c, fmt: 'bit', label: 'O_sclk', lw: 0.8 },
    { c: lr, fmt: 'bit', label: 'O_lrck', color: '#E65100' },
    { c: dd, fmt: 'bit', label: 'O_dsdin' },
    { c: get('O_ack').c, fmt: 'bit', label: 'O_ack', color: '#2E7D32' }], o);
  taxis(o, y, 2e6, 'μs', 1e6);
  const tx = t => o.x0 + (t - o.tw0) / (o.tw1 - o.tw0) * (o.x1 - o.x0);
  const yb = 4.85 - 0.55 - 0.62 - 0.62 - 0.62 / 2;
  const bracket = (ta, tb, t) => { const xa = tx(ta), xb = tx(tb); line([[xa, yb - 0.36], [xb, yb - 0.36]], { color: '#C62828', lw: 0.9 }); label((xa + xb) / 2, yb - 0.5, t, { fs: 7.5, color: '#C62828' }); };
  bracket(rises[1], rises[17], '左声道 16 位，高位先');
  bracket(rises[33], rises[49], '右声道 16 位');
};

FIGS.chart_follow = () => {
  const W = 20, H = 9.6; canvas(W, H);
  const panel = (rows, x0, x1, title, amax, amin, tmax) => {
    const t0 = rows[0][0], y0 = rows[0][1];
    let ow = rows.map(r => r[2] - y0), yw = rows.map(r => r[1] - y0);
    const unwrap = a => { const o = [a[0]]; for (let i = 1; i < a.length; i++) { let d = a[i] - a[i - 1]; while (d > 180) d -= 360; while (d < -180) d += 360; o.push(o[i - 1] + d); } return o; };
    ow = unwrap(ow.map(v => ((v + 540) % 360) - 180)); yw = unwrap(yw.map(v => ((v + 540) % 360) - 180));
    const tx = t => x0 + (t - t0) / 1000 / tmax * (x1 - x0);
    // angle plot
    const ya0 = 4.6, ya1 = 8.6, ay = v => ya0 + (v - amin) / (amax - amin) * (ya1 - ya0);
    label((x0 + x1) / 2, 9.15, title, { fs: 9.5, bold: true, color: '#263238' });
    rect(x0, ya0, x1 - x0, ya1 - ya0, { fc: '#FAFAFA', ec: '#B0BEC5', lw: 0.8, z: 1 });
    // TURN / AVD shading
    let s = null;
    rows.forEach((r, i) => { const on = r[5] === 4; if (on && s === null) s = r[0]; if ((!on || i === rows.length - 1) && s !== null) { rect(tx(s), ya0, tx(r[0]) - tx(s), ya1 - ya0, { fc: '#F3E5F5', z: 1 }); label((tx(s) + tx(r[0])) / 2, ya1 - 0.2, 'TURN', { fs: 7.5, color: '#6A1B9A' }); s = null; } });
    for (let v = Math.ceil(amin / 30) * 30; v <= amax; v += 30) { line([[x0, ay(v)], [x1, ay(v)]], { color: '#E0E0E0', lw: 0.6, z: 1 }); label(x0 - 0.1, ay(v), `${v}°`, { fs: 7.5, ha: 'right', color: '#546E7A' }); }
    line(rows.map((r, i) => [tx(r[0]), ay(ow[i])]), { color: '#E65100', lw: 1.4, ls: '--', z: 4 });
    line(rows.map((r, i) => [tx(r[0]), ay(yw[i])]), { color: '#1565C0', lw: 1.6, z: 5 });
    // wheel plot
    const yb0 = 1.0, yb1 = 3.9, pmin = -3000, pmax = 6000, py = v => yb0 + (v - pmin) / (pmax - pmin) * (yb1 - yb0);
    rect(x0, yb0, x1 - x0, yb1 - yb0, { fc: '#FAFAFA', ec: '#B0BEC5', lw: 0.8, z: 1 });
    for (let v = -2000; v <= 6000; v += 2000) { line([[x0, py(v)], [x1, py(v)]], { color: '#E0E0E0', lw: 0.6, z: 1 }); label(x0 - 0.1, py(v), `${v}`, { fs: 7.5, ha: 'right', color: '#546E7A' }); }
    const sg = v => v >= 8192 ? v - 16384 : v;
    line(rows.map(r => [tx(r[0]), py(sg(r[3]))]), { color: '#2E7D32', lw: 1.2, z: 4 });
    line(rows.map(r => [tx(r[0]), py(sg(r[4]))]), { color: '#AD1457', lw: 1.2, z: 4 });
    for (let t = 0; t <= tmax + 1e-9; t += 0.5) { const x = x0 + t / tmax * (x1 - x0); label(x, yb0 - 0.25, t.toFixed(1), { fs: 7.5, color: '#546E7A' }); }
    label(x1, yb0 - 0.6, '时间 / s', { fs: 7.5, ha: 'right', color: '#546E7A' });
  };
  const A = D_FOL.filter(r => r[0] >= 49121 && r[0] <= 52120), B = D_FOL.filter(r => r[0] >= 52121 && r[0] <= 55120);
  panel(A, 1.4, 9.4, '(a) 主人方向突然右偏 30°（直行中）', 40, -10, 3);
  panel(B, 11.2, 19.6, '(b) 主人在右后方 175°', 210, -30, 3);
  label(0.45, 6.6, "航向角", { fs: 8.5, color: '#263238', rot: 90 });
  label(0.45, 2.45, "轮子 PWM", { fs: 8.5, color: '#263238', rot: 90 });
  const lg = [['#E65100', '--', '主人方向 θ'], ['#1565C0', null, '车头航向 ψ（陀螺仪）'], ['#2E7D32', null, '左轮 PWM'], ['#AD1457', null, '右轮 PWM']];
  lg.forEach(([c, ls, t], i) => { const x = 2.0 + i * 4.3; line([[x, 0.2], [x + 0.6, 0.2]], { color: c, lw: 1.5, ls }); label(x + 0.75, 0.2, t, { fs: 8, ha: 'left' }); });
};
