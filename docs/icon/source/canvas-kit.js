/*!
 * canvas-kit.js — dependency-free helpers for drawing app icons with Canvas 2D.
 *
 * Conventions
 *  - Every icon is drawn on a 1024×1024 canvas (S). Coordinates are in that space.
 *  - Draw full-bleed and opaque: iOS applies the squircle mask itself. Never pre-round.
 *  - Points are [x, y] arrays. A "pathFn" is (ctx) => { ctx.beginPath(); ... } (no stroke/fill).
 *  - Everything is exposed as globals AND on window.IconKit, so concept code stays short.
 *
 * Index
 *  Basics ........ S, TAU, grad, rgrad, bg2, fill, rng, offscreen, poly
 *  Curves ........ sampleClosed, sampleOpen, bez, resample, fitAll, recordPath, transformPts
 *  Backgrounds ... contours, ridge, graphPaper, grain, bark, granite
 *  Objects ....... startDot, sphere, drawShadowed, shadowLayer, tube, glass
 *  Knots ......... segX, crossOvers, strokeLayer
 *  Paint ......... brush, paintOn
 *  Marks ......... mark, arrowHead, trimEnd, recolorPart, cutAbove, demoMarkPts
 *  Text .......... label
 */
(function (root) {
  'use strict';
  const S = 1024, TAU = Math.PI * 2;

  // ---------------------------------------------------------------- basics
  /** Linear gradient. stops: [[offset, color], ...] */
  function grad(ctx, x0, y0, x1, y1, stops) {
    const g = ctx.createLinearGradient(x0, y0, x1, y1);
    stops.forEach(([o, c]) => g.addColorStop(o, c));
    return g;
  }
  /** Radial gradient centred on (x, y). */
  function rgrad(ctx, x, y, r0, r1, stops) {
    const g = ctx.createRadialGradient(x, y, r0, x, y, r1);
    stops.forEach(([o, c]) => g.addColorStop(o, c));
    return g;
  }
  /** Full-canvas diagonal two-colour background. */
  function bg2(ctx, c0, c1) { ctx.fillStyle = grad(ctx, 0, 0, S, S, [[0, c0], [1, c1]]); ctx.fillRect(0, 0, S, S); }
  /** Full-canvas fill with any style (colour or gradient). */
  function fill(ctx, style) { ctx.fillStyle = style; ctx.fillRect(0, 0, S, S); }
  /** Seeded PRNG (mulberry32) → () => [0, 1). Same seed, same drawing. */
  function rng(seed) {
    return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  }
  /** New S×S offscreen canvas; optional draw(ctx). Returns the canvas. */
  function offscreen(draw) {
    const c = document.createElement('canvas'); c.width = c.height = S;
    if (draw) draw(c.getContext('2d'));
    return c;
  }
  /** Polyline path through pts (beginPath included). */
  function poly(ctx, pts, close = true) {
    ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
    if (close) ctx.closePath();
  }

  // ---------------------------------------------------------------- curves
  const cr = (p0, p1, p2, p3, t) => {
    const t2 = t * t, t3 = t2 * t;
    return [0, 1].map(k => 0.5 * (2 * p1[k] + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3));
  };
  /** Catmull-Rom through control points, closed. `per` samples per segment. */
  function sampleClosed(pts, per = 40) {
    const n = pts.length, out = [];
    for (let i = 0; i < n; i++) for (let s = 0; s < per; s++) out.push(cr(pts[(i - 1 + n) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n], s / per));
    return out;
  }
  /** Catmull-Rom through control points, open (passes through first and last). */
  function sampleOpen(pts, per = 30) {
    const e = [pts[0], ...pts, pts[pts.length - 1]], out = [];
    for (let i = 1; i < e.length - 2; i++) for (let s = 0; s < per; s++) out.push(cr(e[i - 1], e[i], e[i + 1], e[i + 2], s / per));
    out.push(pts[pts.length - 1]);
    return out;
  }
  /** Sample a cubic Bézier (n points, end point excluded). */
  function bez(p0, p1, p2, p3, n = 60) {
    const out = [];
    for (let k = 0; k < n; k++) { const t = k / n, u = 1 - t; out.push([0, 1].map(j => u * u * u * p0[j] + 3 * u * u * t * p1[j] + 3 * u * t * t * p2[j] + t * t * t * p3[j])); }
    return out;
  }
  /** Keep one point every `gap` px of arc length (evenly spaced, needed by brush()). */
  function resample(pts, gap) {
    const out = [pts[0]]; let acc = 0;
    for (let i = 1; i < pts.length; i++) { acc += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); if (acc >= gap) { out.push(pts[i]); acc = 0; } }
    return out;
  }
  /** Scale/centre several point arrays together so their union fits a `box` square at (cx, cy). */
  function fitAll(arrays, box = 600, cx = 512, cy = 520) {
    const all = arrays.flat(), xs = all.map(p => p[0]), ys = all.map(p => p[1]);
    const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
    const k = box / Math.max(x1 - x0, y1 - y0), mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
    return arrays.map(a => a.map(([x, y]) => [cx + (x - mx) * k, cy + (y - my) * k]));
  }
  /** Map points through translate/scale/rotate around (ox, oy). */
  function transformPts(pts, { dx = 0, dy = 0, s = 1, rot = 0, ox = 512, oy = 512 } = {}) {
    const c = Math.cos(rot), si = Math.sin(rot);
    return pts.map(([x, y]) => { const u = (x - ox) * s, v = (y - oy) * s; return [ox + u * c - v * si + dx, oy + u * si + v * c + dy]; });
  }
  /**
   * Record a path written with canvas verbs into a dense point list.
   * build(p) receives a fake ctx with moveTo/lineTo/quadraticCurveTo/bezierCurveTo.
   * Use it to feed a hand-drawn path to brush(), tube(), crossOvers()...
   */
  function recordPath(build, density = 1) {
    const pts = []; let cur = [0, 0];
    const nL = Math.max(2, Math.round(24 * density)), nC = Math.max(4, Math.round(40 * density));
    build({
      count: () => pts.length,
      beginPath() {}, closePath() { if (pts.length) this.lineTo(...pts[0]); },
      moveTo(x, y) { cur = [x, y]; pts.push(cur); },
      lineTo(x, y) { for (let k = 1; k <= nL; k++) pts.push([cur[0] + (x - cur[0]) * k / nL, cur[1] + (y - cur[1]) * k / nL]); cur = [x, y]; },
      quadraticCurveTo(a, b, x, y) { for (let k = 1; k <= nC; k++) { const t = k / nC, u = 1 - t; pts.push([u * u * cur[0] + 2 * u * t * a + t * t * x, u * u * cur[1] + 2 * u * t * b + t * t * y]); } cur = [x, y]; },
      bezierCurveTo(a, b, c, d, e, f) { for (let k = 1; k <= nC; k++) { const t = k / nC, u = 1 - t; pts.push([u * u * u * cur[0] + 3 * u * u * t * a + 3 * u * t * t * c + t * t * t * e, u * u * u * cur[1] + 3 * u * u * t * b + 3 * u * t * t * d + t * t * t * f]); } cur = [e, f]; },
    });
    return pts;
  }

  // ---------------------------------------------------------------- backgrounds
  /** Wobbly concentric topo lines around (cx, cy). */
  function contours(ctx, cx, cy, count, step, color, lw, sy = 0.9, wobble = 1) {
    ctx.save(); ctx.strokeStyle = color; ctx.lineWidth = lw;
    for (let k = 1; k <= count; k++) {
      ctx.beginPath();
      for (let i = 0; i <= 180; i++) {
        const a = i / 180 * TAU;
        const r = k * step + wobble * (Math.sin(3 * a + k * 0.45) * 22 + Math.sin(5 * a - k * 0.3) * 10 + Math.cos(2 * a) * 16);
        const x = cx + Math.cos(a) * r, y = cy + Math.sin(a) * r * sy;
        i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }
      ctx.closePath(); ctx.stroke();
    }
    ctx.restore();
  }
  /** Filled mountain silhouette, baseline baseY, height amp. Layer 2–3 with different seeds. */
  function ridge(ctx, baseY, amp, seed, color) {
    const r = rng(seed), ph = [r() * 6, r() * 6, r() * 6];
    ctx.fillStyle = color; ctx.beginPath(); ctx.moveTo(0, S);
    for (let x = 0; x <= S; x += 6) ctx.lineTo(x, baseY - Math.abs(Math.sin(x / 140 + ph[0])) * amp - Math.sin(x / 61 + ph[1]) * amp * 0.25 - Math.sin(x / 23 + ph[2]) * amp * 0.08);
    ctx.lineTo(S, S); ctx.fill();
  }
  /** Graph paper. `line` must be rgba(...) so major lines can be made stronger. */
  function graphPaper(ctx, bg, line, step = 32, major = 5) {
    fill(ctx, bg);
    const strong = line.replace(/[\d.]+\)$/, m => Math.min(1, parseFloat(m) * 2.2).toFixed(2) + ')');
    for (let i = 0; i * step <= S; i++) {
      ctx.strokeStyle = i % major === 0 ? strong : line; ctx.lineWidth = i % major === 0 ? 2 : 1.2;
      ctx.beginPath(); ctx.moveTo(i * step, 0); ctx.lineTo(i * step, S); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(0, i * step); ctx.lineTo(S, i * step); ctx.stroke();
    }
  }
  /** Fine speckle grain over what is already drawn. amount ≈ 0.03–0.08. Invisible at 29 pt. */
  function grain(ctx, amount = 0.05, seed = 5) {
    const r = rng(seed);
    for (let i = 0; i < 9000; i++) { ctx.fillStyle = r() < 0.5 ? `rgba(0,0,0,${amount})` : `rgba(255,255,255,${amount})`; ctx.fillRect(r() * S, r() * S, 1 + r() * 2, 1 + r() * 2); }
  }
  /** Tree bark texture (heavy; dies at small sizes — say so when you use it). */
  function bark(ctx, seed = 31) {
    fill(ctx, grad(ctx, 0, 0, S, 0, [[0, '#4F4135'], [0.5, '#7A6654'], [1, '#43372C']]));
    const r = rng(seed);
    for (let i = 0; i < 260; i++) {
      ctx.strokeStyle = ['rgba(40,30,22,.5)', 'rgba(160,140,118,.3)', 'rgba(90,75,60,.5)', 'rgba(28,20,14,.6)'][i % 4]; ctx.lineWidth = 2 + r() * 12;
      let xx = r() * S; ctx.beginPath(); ctx.moveTo(xx, -10);
      for (let y = 0; y <= S + 40; y += 40) { xx += (r() - 0.5) * 10; ctx.lineTo(xx, y); }
      ctx.stroke();
    }
    fill(ctx, rgrad(ctx, 512, 512, 280, 760, [[0, 'rgba(0,0,0,0)'], [1, 'rgba(0,0,0,.5)']]));
  }
  /** Speckled granite with lichen spots. */
  function granite(ctx, seed = 12) {
    fill(ctx, rgrad(ctx, 420, 380, 60, 900, [[0, '#B9B6AE'], [1, '#77746C']]));
    const r = rng(seed);
    for (let i = 0; i < 2600; i++) { ctx.fillStyle = ['rgba(40,38,34,.45)', 'rgba(255,255,250,.45)', 'rgba(120,110,100,.4)'][i % 3]; ctx.beginPath(); ctx.arc(r() * S, r() * S, 0.8 + r() * r() * 5, 0, TAU); ctx.fill(); }
    for (let i = 0; i < 9; i++) { const x = r() * S, y = r() * S; for (let j = 0; j < 40; j++) { const a = r() * TAU, d = r() * 50; ctx.fillStyle = i % 3 ? 'rgba(175,185,130,.5)' : 'rgba(215,160,80,.45)'; ctx.beginPath(); ctx.arc(x + Math.cos(a) * d, y + Math.sin(a) * d, 2 + r() * 6, 0, TAU); ctx.fill(); } }
    fill(ctx, rgrad(ctx, 512, 512, 300, 760, [[0, 'rgba(0,0,0,0)'], [1, 'rgba(0,0,0,.35)']]));
  }

  // ---------------------------------------------------------------- objects
  /** Start/anchor dot: filled disc with drop shadow and an inner dot (ring look). */
  function startDot(ctx, x, y, r, inner, fillCol = '#fff', shadow = true) {
    ctx.save();
    if (shadow) { ctx.shadowColor = 'rgba(0,0,0,.35)'; ctx.shadowBlur = 24; ctx.shadowOffsetY = 8; }
    ctx.fillStyle = fillCol; ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill();
    ctx.restore();
    if (inner) { ctx.fillStyle = inner; ctx.beginPath(); ctx.arc(x, y, r * 0.45, 0, TAU); ctx.fill(); }
  }
  /** Shaded bead/ball, light from top-left. */
  function sphere(ctx, x, y, r, light, base, dark) {
    const g = ctx.createRadialGradient(x - r * 0.35, y - r * 0.4, r * 0.05, x, y, r);
    g.addColorStop(0, light); g.addColorStop(0.5, base); g.addColorStop(1, dark);
    ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.35)'; ctx.shadowBlur = r * 0.6; ctx.shadowOffsetY = r * 0.25;
    ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill(); ctx.restore();
  }
  /** Draw an offscreen layer with a drop shadow. */
  function drawShadowed(ctx, img, color = 'rgba(0,0,0,.35)', blur = 30, dy = 14) {
    ctx.save(); ctx.shadowColor = color; ctx.shadowBlur = blur; ctx.shadowOffsetY = dy; ctx.drawImage(img, 0, 0); ctx.restore();
  }
  /**
   * Draw several parts (stroke + arrow + ...) on ONE layer, then cast a single shadow.
   * Shadowing parts one by one makes later parts drop shadows onto earlier ones (e.g. an
   * arrowhead shading its own shaft). The layer inherits ctx's transform, and blur/offset are
   * scaled with it (canvas shadows ignore transforms), so small previews look like the 1024.
   * o = { color='rgba(0,0,0,.3)' | null (no shadow), blur=30, dy=14 }
   */
  function shadowLayer(ctx, draw, o = {}) {
    const m = ctx.getTransform(), k = Math.hypot(m.a, m.b);
    const L = document.createElement('canvas'); L.width = ctx.canvas.width; L.height = ctx.canvas.height;
    const x = L.getContext('2d'); x.setTransform(m); x.lineJoin = 'round'; x.lineCap = 'round';
    draw(x);
    ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0);
    if (o.color !== null) { ctx.shadowColor = o.color || 'rgba(0,0,0,.3)'; ctx.shadowBlur = (o.blur ?? 30) * k; ctx.shadowOffsetY = (o.dy ?? 14) * k; }
    ctx.drawImage(L, 0, 0); ctx.restore();
  }
  /**
   * Shaded 3D tube along any path (light from top-left). Returns an offscreen canvas;
   * draw it with drawShadowed(). c = { dark, base, light, rim?, spec? }.
   * Example copper: { dark:'#5E220D', base:'#C4602F', light:'#F4A56E', spec:'rgba(255,240,222,.95)', rim:'rgba(255,140,80,.3)' }
   * Over/under: split the path into two tubes and draw the "over" part last.
   */
  function tube(pathFn, w, c) {
    return offscreen(x => {
      const st = (lw, color, dx = 0, dy = 0, blur = 0) => {
        x.save(); if (blur) x.filter = `blur(${blur}px)`; x.translate(dx, dy); pathFn(x);
        x.lineCap = 'round'; x.lineJoin = 'round'; x.lineWidth = lw; x.strokeStyle = color; x.stroke(); x.restore();
      };
      st(w, c.dark); x.globalCompositeOperation = 'source-atop';
      st(w * 0.85, c.base, -w * 0.07, -w * 0.09, w * 0.1);
      st(w * 0.45, c.light, -w * 0.14, -w * 0.17, w * 0.12);
      if (c.rim) st(w * 0.22, c.rim, w * 0.26, w * 0.3, w * 0.08);
      if (c.spec) st(w * 0.1, c.spec, -w * 0.2, -w * 0.25, Math.max(2, w * 0.03));
    });
  }
  /**
   * Liquid-Glass style thick glass stroke: refracts (mirrors, blurs, saturates) what is
   * already on ctx along pathFn. Draw the background first, then call glass().
   * o = { w=130, cx=512, cy=520, zoom=1.15, blur=10, tint='rgba(255,255,255,.16)', shadow='rgba(70,0,70,.35)' }
   */
  function glass(ctx, pathFn, o = {}) {
    const w = o.w || 130, cx = o.cx ?? 512, cy = o.cy ?? 520, zoom = o.zoom || 1.15;
    const bg = offscreen(x => x.drawImage(ctx.canvas, 0, 0, S, S));
    const g = offscreen(x => {
      x.lineCap = 'round'; x.lineJoin = 'round';
      pathFn(x); x.lineWidth = w; x.strokeStyle = '#fff'; x.stroke();
      x.globalCompositeOperation = 'source-atop';
      x.save(); x.filter = `blur(${o.blur ?? 10}px) saturate(1.5) brightness(1.2)`; x.translate(cx, cy); x.scale(-zoom, zoom); x.translate(-cx, -cy); x.drawImage(bg, 0, 0); x.restore();
      x.fillStyle = o.tint || 'rgba(255,255,255,.16)'; x.fillRect(0, 0, S, S);
      const st = (lw, color, dx, dy, blur) => { x.save(); x.filter = `blur(${blur}px)`; x.translate(dx, dy); pathFn(x); x.lineWidth = lw; x.strokeStyle = color; x.stroke(); x.restore(); };
      st(w, 'rgba(0,0,0,.22)', w * 0.3, w * 0.34, 14);        // inner shade, bottom-right
      st(w * 0.14, 'rgba(255,255,255,.95)', -w * 0.22, -w * 0.27, 3); // top-left highlight
      st(w * 0.08, 'rgba(255,255,255,.6)', w * 0.3, w * 0.3, 4);      // bottom-right rim
    });
    drawShadowed(ctx, g, o.shadow || 'rgba(70,0,70,.35)', 50, 26);
    ctx.save(); pathFn(ctx); ctx.lineWidth = w + 3; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.strokeStyle = 'rgba(255,255,255,.35)'; ctx.globalCompositeOperation = 'destination-over'; ctx.stroke(); ctx.restore();
  }

  // ---------------------------------------------------------------- knots (over/under)
  /** Do segments ab and cd strictly intersect? */
  function segX(a, b, c, d) {
    const den = (d[1] - c[1]) * (b[0] - a[0]) - (d[0] - c[0]) * (b[1] - a[1]); if (!den) return false;
    const ua = ((d[0] - c[0]) * (a[1] - c[1]) - (d[1] - c[1]) * (a[0] - c[0])) / den;
    const ub = ((b[0] - a[0]) * (a[1] - c[1]) - (b[1] - a[1]) * (a[0] - c[0])) / den;
    return ua > 0 && ua < 1 && ub > 0 && ub < 1;
  }
  /** For a dense closed curve, return [from, to] index ranges that pass OVER, alternating at each crossing. O(n²): keep n ≤ ~800. */
  function crossOvers(pts, half = 14) {
    const n = pts.length, ev = [];
    for (let i = 0; i < n; i++) for (let j = i + 8; j < n; j++) {
      if ((i - j + n) % n < 8) continue;
      if (segX(pts[i], pts[(i + 1) % n], pts[j], pts[(j + 1) % n])) ev.push(i, j);
    }
    ev.sort((a, b) => a - b);
    return ev.filter((_, k) => k % 2 === 1).map(i => [i - half, i + half]);
  }
  /**
   * Stroke a point path on an offscreen layer, cutting a gap under each `overs` range so the
   * curve reads as a knot. o = { lw=72, color, closed=true, overs=[], gap=44, widthFn?(pt,i) }.
   * Example trefoil: pts = fitAll([trefoil])[0]; drawShadowed(ctx, strokeLayer(pts, { lw:60, overs: crossOvers(pts, 20) }));
   */
  function strokeLayer(pts, o = {}) {
    const lw = o.lw || 72, closed = o.closed !== false, n = pts.length;
    return offscreen(x => {
      x.lineCap = 'round'; x.lineJoin = 'round'; x.strokeStyle = o.color || '#FFF4E6';
      if (o.widthFn) { for (let i = 0; i < (closed ? n : n - 1); i++) { x.lineWidth = o.widthFn(pts[i], i); x.beginPath(); x.moveTo(...pts[i]); x.lineTo(...pts[(i + 1) % n]); x.stroke(); } }
      else { poly(x, pts, closed); x.lineWidth = lw; x.stroke(); }
      const slice = (a, b) => { const r = []; for (let i = a; i <= b; i++) r.push(pts[((i % n) + n) % n]); return r; };
      (o.overs || []).forEach(([a, b]) => {
        x.save(); x.globalCompositeOperation = 'destination-out'; x.lineCap = 'butt';
        poly(x, slice(a + 5, b - 5), false); x.lineWidth = lw + (o.gap ?? 44); x.stroke(); x.restore();
        poly(x, slice(a, b), false); x.lineWidth = lw; x.stroke();
      });
    });
  }

  // ---------------------------------------------------------------- paint
  /**
   * Bristle brush along evenly spaced pts (use resample(pts, 4)). Full at start, dries out.
   * o = { color, W: t => width (t in 0..1), seed, bristles=30, dryStart=0.55, blob=true }
   * Example width: t => 18 + 86 * (1 - t) ** 0.6
   */
  function brush(ctx, pts, o) {
    const r = rng(o.seed || 1), n = pts.length, N = o.bristles || 30, dryStart = o.dryStart ?? 0.55, W = o.W;
    const nm = pts.map((p, i) => { const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)], dx = b[0] - a[0], dy = b[1] - a[1], l = Math.hypot(dx, dy) || 1; return [-dy / l, dx / l]; });
    ctx.save(); ctx.strokeStyle = o.color; ctx.fillStyle = o.color; ctx.lineCap = 'round';
    for (let i = 1; i < n; i++) { // solid core
      const t = i / n, k = t < dryStart ? 1 : Math.max(0, 1 - (t - dryStart) / 0.18);
      if (k <= 0) break;
      ctx.lineWidth = W(t) * 0.8 * k; ctx.beginPath(); ctx.moveTo(...pts[i - 1]); ctx.lineTo(...pts[i]); ctx.stroke();
    }
    for (let b = 0; b < N; b++) { // bristles
      const off = (b / (N - 1) - 0.5) * 0.98 + (r() - 0.5) * 0.03, edge = Math.abs(off) * 2;
      const end = dryStart + (0.2 + r() * 0.8) * (1 - dryStart) * (1 - edge * 0.25), bw = 0.7 + r() * 0.8;
      ctx.globalAlpha = 0.75 + r() * 0.25;
      for (let i = 1; i < n; i++) {
        const t = i / n; if (t > end) break;
        if (t > end - 0.2 && r() < (t - (end - 0.2)) * 4) continue;
        const w0 = W((i - 1) / n), w1 = W(t), o0 = off + Math.sin(i * 0.07 + b) * 0.012;
        ctx.lineWidth = Math.max(1, w1 / N * 2.3 * bw);
        ctx.beginPath(); ctx.moveTo(pts[i - 1][0] + nm[i - 1][0] * o0 * w0, pts[i - 1][1] + nm[i - 1][1] * o0 * w0); ctx.lineTo(pts[i][0] + nm[i][0] * o0 * w1, pts[i][1] + nm[i][1] * o0 * w1); ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;
    if (o.blob !== false) { ctx.beginPath(); ctx.arc(pts[0][0], pts[0][1], W(0) * 0.56, 0, TAU); ctx.fill(); }
    ctx.restore();
  }
  /** Draw paint via drawPaint(x) on a layer, weather it (chips + vertical streaks), composite. For painted trail blazes on bark/granite. */
  function paintOn(ctx, drawPaint, seed = 9) {
    const p = offscreen(drawPaint), x = p.getContext('2d'), r = rng(seed);
    x.globalCompositeOperation = 'destination-out';
    for (let i = 0; i < 450; i++) { x.fillStyle = `rgba(0,0,0,${0.3 + r() * 0.7})`; x.beginPath(); x.arc(r() * S, r() * S, r() * r() * 8, 0, TAU); x.fill(); }
    for (let i = 0; i < 110; i++) { x.strokeStyle = 'rgba(0,0,0,.18)'; x.lineWidth = 2 + r() * 4; const xx = r() * S; x.beginPath(); x.moveTo(xx, 0); x.lineTo(xx + (r() - 0.5) * 20, S); x.stroke(); }
    ctx.drawImage(p, 0, 0);
  }

  // ---------------------------------------------------------------- marks (one-stroke symbols)
  /** Chevron arrow head at `tip`, pointing along angle `ang` (radians). */
  function arrowHead(ctx, tip, ang, size, lw) {
    const a1 = ang + Math.PI - 0.8, a2 = ang + Math.PI + 0.8;
    ctx.beginPath(); ctx.moveTo(tip[0] + Math.cos(a1) * size, tip[1] + Math.sin(a1) * size); ctx.lineTo(...tip); ctx.lineTo(tip[0] + Math.cos(a2) * size, tip[1] + Math.sin(a2) * size);
    ctx.lineWidth = lw; ctx.stroke();
  }
  /**
   * Recolour PART of a stroke with clean, outline-following edges.
   * Never stroke the sub-path separately with round caps (blobs at the ends). Instead:
   * drawStroke(x) redraws the WHOLE stroke in the accent colour on an offscreen layer (same
   * transform as ctx), maskFn(x) fills the region to KEEP, and the result is composited back.
   */
  function recolorPart(ctx, drawStroke, maskFn) {
    const o = document.createElement('canvas'); o.width = ctx.canvas.width; o.height = ctx.canvas.height;
    const x = o.getContext('2d'); x.setTransform(ctx.getTransform()); x.lineJoin = 'round'; x.lineCap = 'round';
    drawStroke(x);
    x.globalCompositeOperation = 'destination-in'; x.beginPath(); maskFn(x); x.fill();
    ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.drawImage(o, 0, 0); ctx.restore();
  }
  /**
   * Mask path for recolorPart(): everything ABOVE a cut line from (x0, yL) to (x1, yR).
   * amp > 0 gives a saw-tooth edge (good defaults: period ≈ 0.5·lw, amp ≈ 0.22·lw); amp = 0 a straight cut.
   * Place the line ~0.35·lw below the ends of the recoloured segment. Adds to the current path (no fill).
   */
  function cutAbove(x, yL, yR, { period = 40, amp = 0, x0 = -60, x1 = S + 76 } = {}) {
    x.moveTo(x0, -60); x.lineTo(x1, -60);
    for (let X = x1, i = 0; X >= x0; X -= period / 2, i++) x.lineTo(X, yL + (yR - yL) * ((X - x0) / (x1 - x0)) + (i % 2 ? amp : -amp));
    x.closePath();
  }
  /** Drop `dist` px of arc length from the end of a polyline (used to stop a shaft behind an arrow tip). */
  function trimEnd(pts, dist) {
    const out = pts.slice(); let left = dist;
    while (out.length > 1) {
      const a = out[out.length - 2], b = out[out.length - 1], l = Math.hypot(b[0] - a[0], b[1] - a[1]);
      if (l > left) { const k = (l - left) / l; out[out.length - 1] = [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k]; return out; }
      left -= l; out.pop();
    }
    return out;
  }
  /**
   * Airbnb-Bélo-style mark: one thick stroke along pts, optional start dot, arrow, accent segment.
   * o = { lw=80, color='#FFF4E6', closed=false, shadow='rgba(0,0,0,.3)'|null,
   *       dot=lw*0.92|0, inner='#C9502E'|null, arrow=false, accent: { from, to, color, edge='saw'|'straight'|'round' }? }
   * accent recolours the part of the stroke ABOVE a cut ~0.35·lw below pts[from] and pts[to-1]
   * (e.g. the "peaks"), via recolorPart(): saw-tooth or straight edge that follows the outline.
   * ARROW RULE: a stroke ending in an arrowhead must stop ~0.3 × lineWidth BEHIND the tip,
   * otherwise its round cap (radius lw/2) pokes out in front of the chevron. mark() does this.
   */
  function mark(ctx, pts, o = {}) {
    const lw = o.lw || 80, color = o.color || '#FFF4E6', dot = o.dot ?? lw * 0.92;
    ctx.save(); ctx.lineJoin = 'round'; ctx.lineCap = 'round'; ctx.strokeStyle = color;
    const tip = pts[pts.length - 1], back = pts[Math.max(0, pts.length - 6)];
    shadowLayer(ctx, x => {
      x.strokeStyle = color; poly(x, o.arrow ? trimEnd(pts, lw * 0.3) : pts, !!o.closed); x.lineWidth = lw; x.stroke();
      if (o.arrow) arrowHead(x, tip, Math.atan2(tip[1] - back[1], tip[0] - back[0]), lw * 1.1, lw * 0.8);
    }, { color: o.shadow });
    if (o.accent) {
      const A = o.accent, a = pts[A.from], b = pts[Math.min(pts.length, A.to) - 1];
      if (A.edge === 'round') { poly(ctx, pts.slice(A.from, A.to), false); ctx.lineWidth = lw; ctx.strokeStyle = A.color; ctx.stroke(); }
      else recolorPart(ctx, x => { poly(x, o.arrow ? trimEnd(pts, lw * 0.3) : pts, !!o.closed); x.lineWidth = lw; x.strokeStyle = A.color; x.stroke(); },
        x => cutAbove(x, a[1] + lw * 0.35, b[1] + lw * 0.35, { period: lw * 0.5, amp: A.edge === 'straight' ? 0 : lw * 0.22, x0: Math.min(a[0], b[0]) - lw, x1: Math.max(a[0], b[0]) + lw }));
    }
    if (dot) {
      ctx.fillStyle = color; ctx.beginPath(); ctx.arc(pts[0][0], pts[0][1], dot, 0, TAU); ctx.fill();
      if (o.inner) { ctx.fillStyle = o.inner; ctx.beginPath(); ctx.arc(pts[0][0], pts[0][1], dot * 0.42, 0, TAU); ctx.fill(); }
    }
    ctx.restore();
  }
  /**
   * Example symbol from the LoopHuntr session ("22"): start dot, two peaks, return toward start.
   * Returns { pts, peaks: [from, to] } — pass accent: { from, to, color } to mark() to colour the peaks.
   * Replace with your own app's path; keep the recordPath() pattern (record index marks as you go).
   */
  function demoMarkPts(s = 1, cx = 504, cy = 528, endX = 560) {
    const tf = ([x, y]) => [cx + (x - 512) * s, cy + (y - 540) * s];
    let peaksFrom = 0, peaksTo = 0;
    const pts = recordPath(p => {
      p.moveTo(...tf([360, 780])); p.bezierCurveTo(...tf([250, 760]), ...tf([190, 660]), ...tf([220, 560]));
      peaksFrom = p.count();
      p.lineTo(...tf([390, 330])); p.lineTo(...tf([500, 460])); p.lineTo(...tf([650, 270])); p.lineTo(...tf([820, 540]));
      peaksTo = p.count();
      p.bezierCurveTo(...tf([860, 660]), ...tf([800, 780]), ...tf([660, 780])); p.lineTo(...tf([endX, 780]));
    });
    return { pts, peaks: [peaksFrom - 1, peaksTo] };
  }

  // ---------------------------------------------------------------- text
  /** Text helper. o = { size=32, weight=500, font, color, align, base, tracking } */
  function label(ctx, text, x, y, o = {}) {
    ctx.save(); ctx.font = `${o.weight || 500} ${o.size || 32}px ${o.font || '"SF Mono", ui-monospace, monospace'}`; ctx.fillStyle = o.color || '#1b1d1c';
    ctx.textAlign = o.align || 'left'; ctx.textBaseline = o.base || 'alphabetic';
    if (o.tracking) ctx.letterSpacing = o.tracking + 'px';
    ctx.fillText(text, x, y); ctx.restore();
  }

  const API = {
    S, TAU, grad, rgrad, bg2, fill, rng, offscreen, poly,
    sampleClosed, sampleOpen, bez, resample, fitAll, transformPts, recordPath,
    contours, ridge, graphPaper, grain, bark, granite,
    startDot, sphere, drawShadowed, shadowLayer, tube, glass,
    segX, crossOvers, strokeLayer,
    brush, paintOn,
    arrowHead, trimEnd, recolorPart, cutAbove, mark, demoMarkPts,
    label,
  };
  root.IconKit = API;
  Object.assign(root, API);
})(typeof window !== 'undefined' ? window : globalThis);
