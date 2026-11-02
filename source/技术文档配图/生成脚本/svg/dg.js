// SVG port of the matplotlib helpers in dg.py: same coordinates (units, y up), same API.
const UNIT = 70;                 // CSS px per unit (rendered at device scale 2)
const PT = UNIT / 44.64;         // 1 pt in px (1 unit = 0.62 in = 44.64 pt)
const C = {
  sens: '#E3F2FD', fpga: '#FFF3E0', fpgabg: '#FFFBF3', act: '#E8F5E9', mcu: '#F3E5F5',
  gray: '#F5F5F5', yellow: '#FFF9C4', red: '#FFEBEE', blue: '#E1F5FE', edge: '#37474F',
  arrow: '#455A64', accent: '#E65100', green: '#2E7D32', purple: '#6A1B9A', blued: '#1565C0'
};
const FONT = "'Microsoft YaHei','微软雅黑',sans-serif";
const NS = 'http://www.w3.org/2000/svg';
let SVG, W_, H_, LAYERS;

function canvas(w, h) {
  W_ = w; H_ = h;
  SVG = document.createElementNS(NS, 'svg');
  SVG.setAttribute('width', w * UNIT); SVG.setAttribute('height', h * UNIT);
  SVG.setAttribute('viewBox', `0 0 ${w * UNIT} ${h * UNIT}`);
  const bg = document.createElementNS(NS, 'rect');
  bg.setAttribute('width', w * UNIT); bg.setAttribute('height', h * UNIT); bg.setAttribute('fill', '#fff');
  SVG.appendChild(bg);
  LAYERS = {};
  document.body.appendChild(SVG);
}
function layer(z) {
  if (!LAYERS[z]) {
    const g = document.createElementNS(NS, 'g'); LAYERS[z] = g;
    const keys = Object.keys(LAYERS).map(Number).sort((a, b) => a - b);
    for (const k of keys) SVG.appendChild(LAYERS[k]);
  }
  return LAYERS[z];
}
const X = x => x * UNIT, Y = y => (H_ - y) * UNIT;
function el(tag, attrs, z = 2) {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
  layer(z).appendChild(e);
  return e;
}
function dash(ls, lw) {
  if (ls === '--') return `${5 * lw * PT},${3 * lw * PT}`;
  if (ls === ':') return `${1 * lw * PT},${2.2 * lw * PT}`;
  return null;
}

// text block: lines centred on their own centre; ha/va relative to (x, y) in units
function text(x, y, t, o = {}) {
  const fs = (o.fs || 10) * PT, lh = fs * (o.ls || 1.35);
  const lines = String(t).split('\n');
  const ha = o.ha || 'center', va = o.va || 'center';
  const anchor = ha === 'left' ? 'start' : ha === 'right' ? 'end' : 'middle';
  const blockH = (lines.length - 1) * lh + fs;
  let cy = Y(y);                                  // centre of block
  if (va === 'bottom') cy -= blockH / 2;
  if (va === 'top') cy += blockH / 2;
  const g = el('g', {}, o.z || 6);
  if (o.rot) g.setAttribute('transform', `rotate(${-o.rot} ${X(x)} ${Y(y)})`);
  const tx = document.createElementNS(NS, 'text');
  tx.setAttribute('font-family', o.family || FONT);
  tx.setAttribute('font-size', fs);
  tx.setAttribute('fill', o.color || '#212121');
  tx.setAttribute('text-anchor', anchor);
  tx.setAttribute('style', 'white-space:pre');
  if (o.bold) tx.setAttribute('font-weight', 'bold');
  lines.forEach((ln, i) => {
    const s = document.createElementNS(NS, 'tspan');
    s.setAttribute('x', X(x));
    s.setAttribute('y', cy - (lines.length - 1) * lh / 2 + i * lh);
    s.setAttribute('dominant-baseline', 'central');
    s.setAttribute('xml:space', 'preserve');
    s.textContent = ln;
    tx.appendChild(s);
  });
  g.appendChild(tx);
  if (o.bbox) {                                   // white label background
    const b = tx.getBBox();
    const r = document.createElementNS(NS, 'rect');
    const p = 0.6 * PT * 1.6;
    r.setAttribute('x', b.x - p); r.setAttribute('y', b.y - p);
    r.setAttribute('width', b.width + 2 * p); r.setAttribute('height', b.height + 2 * p);
    r.setAttribute('fill', '#fff'); r.setAttribute('fill-opacity', '0.88');
    g.insertBefore(r, tx);
  }
  return g;
}

function box(x, y, w, h, t, o = {}) {
  const ec = o.ec || C.edge, r = (o.r === undefined ? 0.12 : o.r) * UNIT, lw = o.lw || 1.2;
  el('rect', {
    x: X(x), y: Y(y + h), width: w * UNIT, height: h * UNIT, rx: r, ry: r,
    fill: o.fc || '#FFFFFF', stroke: ec, 'stroke-width': lw * PT, 'stroke-dasharray': dash(o.ls, lw)
  }, o.z || 2);
  if (t) {
    const ha = o.ha || 'center', va = o.va || 'center';
    const tx = ha === 'center' ? x + w / 2 : x + 0.15;
    const ty = va === 'center' ? y + h / 2 : y + h - 0.15;
    text(tx, ty, t, { fs: o.fs || 10, color: o.tc || '#212121', bold: o.bold, ha, va: va === 'center' ? 'center' : 'top', z: (o.z || 2) + 1 });
  }
  return [x, y, w, h];
}

function diamond(cx, cy, w, h, t, o = {}) {
  const pts = [[cx - w / 2, cy], [cx, cy + h / 2], [cx + w / 2, cy], [cx, cy - h / 2]];
  el('polygon', { points: pts.map(p => `${X(p[0])},${Y(p[1])}`).join(' '), fill: o.fc || C.yellow, stroke: C.edge, 'stroke-width': 1.2 * PT }, 2);
  text(cx, cy, t, { fs: o.fs || 9, ls: 1.3, z: 3 });
}

function head(p1, p2, color, ms, lw) {
  const dx = X(p2[0]) - X(p1[0]), dy = Y(p2[1]) - Y(p1[1]);
  const L = Math.hypot(dx, dy) || 1, ux = dx / L, uy = dy / L;
  const hl = 0.45 * ms * PT, hw = 0.2 * ms * PT;
  const tx = X(p2[0]), ty = Y(p2[1]);
  const bx = tx - ux * hl, by = ty - uy * hl;
  el('polygon', { points: `${tx},${ty} ${bx - uy * hw},${by + ux * hw} ${bx + uy * hw},${by - ux * hw}`, fill: color }, 4);
  return [bx, by];
}

function arrow(p1, p2, o = {}) {
  const color = o.color || C.arrow, lw = o.lw || 1.3, ms = o.ms || 11, style = o.style || '-|>';
  let a = [X(p1[0]), Y(p1[1])], b = [X(p2[0]), Y(p2[1])];
  if (style.endsWith('|>')) b = head(p1, p2, color, ms, lw);
  if (style.startsWith('<|')) a = head(p2, p1, color, ms, lw);
  el('line', { x1: a[0], y1: a[1], x2: b[0], y2: b[1], stroke: color, 'stroke-width': lw * PT, 'stroke-dasharray': dash(o.ls, lw) }, o.z || 4);
  if (o.text) {
    const toff = o.toff || [0, 0.12];
    const mx = (p1[0] + p2[0]) / 2 + toff[0], my = (p1[1] + p2[1]) / 2 + toff[1];
    text(mx, my, o.text, { fs: o.fs || 8, ha: o.tha || 'center', va: 'bottom', color: o.tc || '#37474F', bbox: true, ls: 1.2, z: (o.z || 4) + 1 });
  }
}

function poly(pts, o = {}) {
  const color = o.color || C.arrow, lw = o.lw || 1.3;
  const d = pts.slice(0, -1).map(p => `${X(p[0])},${Y(p[1])}`).join(' ');
  el('polyline', { points: d, fill: 'none', stroke: color, 'stroke-width': lw * PT, 'stroke-dasharray': dash(o.ls, lw) }, 4);
  arrow(pts[pts.length - 2], pts[pts.length - 1], { color, lw, style: o.style || '-|>', ls: o.ls });
  if (o.text && o.tpos) text(o.tpos[0], o.tpos[1], o.text, { fs: o.fs || 8, ha: o.tha || 'center', color: '#37474F', bbox: true, z: 6 });
}

function line(pts, o = {}) {
  el('polyline', {
    points: pts.map(p => `${X(p[0])},${Y(p[1])}`).join(' '), fill: 'none', stroke: o.color || C.arrow,
    'stroke-width': (o.lw || 1) * PT, 'stroke-dasharray': dash(o.ls, o.lw || 1), 'stroke-opacity': o.alpha
  }, o.z || 4);
}

function label(x, y, t, o = {}) {
  return text(x, y, t, { fs: o.fs || 9, color: o.color || '#37474F', ha: o.ha || 'center', va: o.va || 'center', bold: o.bold, z: o.z || 6, rot: o.rotation, family: o.family, bbox: o.bbox });
}

function rect(x, y, w, h, o = {}) {
  el('rect', { x: X(x), y: Y(y + h), width: w * UNIT, height: h * UNIT, fill: o.fc || 'none', stroke: o.ec || 'none', 'stroke-width': (o.lw || 0) * PT, 'fill-opacity': o.alpha, 'stroke-dasharray': dash(o.ls, o.lw || 1) }, o.z || 2);
}
function polygon(pts, o = {}) {
  el('polygon', { points: pts.map(p => `${X(p[0])},${Y(p[1])}`).join(' '), fill: o.fc || 'none', stroke: o.ec || 'none', 'stroke-width': (o.lw || 0) * PT, 'fill-opacity': o.alpha, 'stroke-dasharray': dash(o.ls, o.lw || 1) }, o.z || 2);
}
function circle(cx, cy, r, o = {}) {
  el('circle', { cx: X(cx), cy: Y(cy), r: r * UNIT, fill: o.fc || '#fff', stroke: o.ec || C.edge, 'stroke-width': (o.lw || 1.2) * PT }, o.z || 3);
}
function image(href, x, y, w, h, z = 3) {
  el('image', { href, x: X(x), y: Y(y + h), width: w * UNIT, height: h * UNIT, preserveAspectRatio: 'none' }, z);
}
function connector(x, y, t) { circle(x, y, 0.3); label(x, y, t, { fs: 9, bold: true, color: '#212121' }); }
