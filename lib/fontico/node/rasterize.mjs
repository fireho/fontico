// Rasterise glyphs out of a built TTF into 1-bit bitmaps.
//
// Reading the font rather than the SVG bodies is deliberate: build_font.mjs
// has already normalised every icon to the em box and put it on a common
// baseline, so bitmaps taken from here inherit the same geometry the PDF
// uses. Rasterising the SVGs separately would re-derive all of that and drift.
//
// opentype.js is already a toolchain dependency, so this needs nothing new —
// it gives us outlines, and a scanline fill turns those into pixels.
//
// stdin:  { ttf, size, glyphs: [{ name, codepoint }] }
// stdout: { glyphs: [{ name, codepoint, width, height, xAdvance,
//                      xOffset, yOffset, bytes: [...] }], yAdvance }
import fs from 'fs';
import opentype from 'opentype.js';

const job = JSON.parse(fs.readFileSync(0, 'utf8'));

// Coverage is sampled this many times per pixel on each axis. 4 is enough to
// place an edge convincingly at 24px and still runs in milliseconds; the
// result is thresholded to one bit regardless, so more buys very little.
const SS = 4;
// Curve subdivision. Flat enough that the error sits well under a subsample.
const CURVE_STEPS = 12;

const lerp = (a, b, t) => a + (b - a) * t;

function cubicAt(x0, y0, x1, y1, x2, y2, x3, y3, t) {
  const ax = lerp(x0, x1, t), ay = lerp(y0, y1, t);
  const bx = lerp(x1, x2, t), by = lerp(y1, y2, t);
  const cx = lerp(x2, x3, t), cy = lerp(y2, y3, t);
  const dx = lerp(ax, bx, t), dy = lerp(ay, by, t);
  const ex = lerp(bx, cx, t), ey = lerp(by, cy, t);
  return { x: lerp(dx, ex, t), y: lerp(dy, ey, t) };
}

function quadAt(x0, y0, x1, y1, x2, y2, t) {
  const ax = lerp(x0, x1, t), ay = lerp(y0, y1, t);
  const bx = lerp(x1, x2, t), by = lerp(y1, y2, t);
  return { x: lerp(ax, bx, t), y: lerp(ay, by, t) };
}

// Path commands to closed polygons. Every contour is implicitly closed: a
// fill has no notion of an open one, and leaving it open drops an edge.
function contoursOf(path) {
  const out = [];
  let cur = null;
  let cx = 0, cy = 0, sx = 0, sy = 0;

  const close = () => {
    if (cur && cur.length > 2) out.push(cur);
    cur = null;
  };

  for (const cmd of path.commands) {
    switch (cmd.type) {
      case 'M':
        close();
        cur = [{ x: cmd.x, y: cmd.y }];
        cx = sx = cmd.x; cy = sy = cmd.y;
        break;
      case 'L':
        if (cur) cur.push({ x: cmd.x, y: cmd.y });
        cx = cmd.x; cy = cmd.y;
        break;
      case 'C':
        for (let i = 1; i <= CURVE_STEPS; i++) {
          cur.push(cubicAt(cx, cy, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y, i / CURVE_STEPS));
        }
        cx = cmd.x; cy = cmd.y;
        break;
      case 'Q':
        for (let i = 1; i <= CURVE_STEPS; i++) {
          cur.push(quadAt(cx, cy, cmd.x1, cmd.y1, cmd.x, cmd.y, i / CURVE_STEPS));
        }
        cx = cmd.x; cy = cmd.y;
        break;
      case 'Z':
        close();
        cx = sx; cy = sy;
        break;
    }
  }
  close();
  return out;
}

function edgesOf(contours) {
  const edges = [];
  for (const c of contours) {
    for (let i = 0; i < c.length; i++) {
      const a = c[i], b = c[(i + 1) % c.length];
      if (a.y !== b.y) edges.push([a.x, a.y, b.x, b.y]);
    }
  }
  return edges;
}

// Add a horizontal span's contribution, splitting it across the pixels it
// partially covers so edges land between pixels rather than on one side.
function addSpan(cov, w, row, xa, xb, weight) {
  const lo = Math.max(0, xa), hi = Math.min(w, xb);
  if (hi <= lo) return;
  for (let px = Math.floor(lo); px < Math.ceil(hi); px++) {
    const l = Math.max(lo, px), r = Math.min(hi, px + 1);
    if (r > l) cov[row + px] += (r - l) * weight;
  }
}

// Scanline fill with the nonzero winding rule, which is what TrueType uses —
// even-odd would punch holes in any glyph whose contours overlap.
function coverage(edges, x0, y0, w, h) {
  const cov = new Float64Array(w * h);
  const weight = 1 / SS;

  for (let py = 0; py < h; py++) {
    for (let s = 0; s < SS; s++) {
      const sy = y0 + py + (s + 0.5) / SS;
      const hits = [];
      for (const [ex0, ey0, ex1, ey1] of edges) {
        const lo = Math.min(ey0, ey1), hi = Math.max(ey0, ey1);
        if (sy < lo || sy >= hi) continue;
        hits.push({ x: ex0 + ((sy - ey0) / (ey1 - ey0)) * (ex1 - ex0), dir: ey1 > ey0 ? 1 : -1 });
      }
      if (hits.length < 2) continue;
      hits.sort((a, b) => a.x - b.x);

      let wind = 0;
      for (let i = 0; i < hits.length - 1; i++) {
        wind += hits[i].dir;
        if (wind !== 0) addSpan(cov, w, py * w, hits[i].x - x0, hits[i + 1].x - x0, weight);
      }
    }
  }
  return cov;
}

// GFXfont bitmaps are one continuous MSB-first bitstream with no padding
// between rows — drawBitmap's row-aligned layout is a different format, and
// mixing them up shears the glyph.
function pack(cov, w, h) {
  const bytes = [];
  let acc = 0, n = 0;
  for (let i = 0; i < w * h; i++) {
    acc = (acc << 1) | (cov[i] > 0.5 ? 1 : 0);
    if (++n === 8) { bytes.push(acc & 0xff); acc = 0; n = 0; }
  }
  if (n) bytes.push((acc << (8 - n)) & 0xff);
  return bytes;
}

const font = opentype.parse(new Uint8Array(fs.readFileSync(job.ttf)).buffer);
const size = job.size;
const scale = size / font.unitsPerEm;
const out = [];

for (const g of job.glyphs) {
  const glyph = font.charToGlyph(String.fromCodePoint(g.codepoint));
  // getPath flips y so it grows downward from the baseline, which is the
  // direction GFXglyph's yOffset is measured in too.
  const contours = contoursOf(glyph.getPath(0, 0, size));
  const edges = edgesOf(contours);
  const advance = Math.round((glyph.advanceWidth ?? font.unitsPerEm) * scale);

  if (!edges.length) {
    out.push({ ...g, width: 0, height: 0, xAdvance: advance, xOffset: 0, yOffset: 0, bytes: [], blank: true });
    continue;
  }

  // Tight box: a GFXglyph stores only the inked area and offsets it, so
  // whitespace costs nothing in flash.
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [ex0, ey0, ex1, ey1] of edges) {
    minX = Math.min(minX, ex0, ex1); maxX = Math.max(maxX, ex0, ex1);
    minY = Math.min(minY, ey0, ey1); maxY = Math.max(maxY, ey0, ey1);
  }
  const x0 = Math.floor(minX), y0 = Math.floor(minY);
  const w = Math.max(1, Math.ceil(maxX) - x0);
  const h = Math.max(1, Math.ceil(maxY) - y0);

  const cov = coverage(edges, x0, y0, w, h);
  const bytes = pack(cov, w, h);
  const inked = cov.some((v) => v > 0.5);

  out.push({
    ...g,
    width: w, height: h, xAdvance: advance, xOffset: x0, yOffset: y0,
    bytes, blank: !inked
  });
}

process.stdout.write(JSON.stringify({ glyphs: out, yAdvance: Math.round(size * 1.2) }));
