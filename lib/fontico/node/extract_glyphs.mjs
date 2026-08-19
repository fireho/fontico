// Pull already-outlined glyphs out of a provider's own font.
//
// Stroke-based icon sets (Lucide) cannot be filled directly as glyphs — a
// path with fill="none" fills its centreline and produces a blob. The only
// lossless source of expanded outlines is the provider's own font build,
// where the expansion has already been done and tuned. Every JS "stroke to
// fill" package traces a raster and degrades the geometry.
//
// stdin:  { fontPath, codepointsPath, size, names: [] }
// stdout: { glyphs: { name: pathData }, missing: [] }
import fs from 'fs';
import opentype from 'opentype.js';

const job = JSON.parse(fs.readFileSync(0, 'utf8'));
const font = opentype.parse(fs.readFileSync(job.fontPath).buffer);
const codepoints = JSON.parse(fs.readFileSync(job.codepointsPath, 'utf8'));

const size = job.size ?? 24;
const glyphs = {};
const missing = [];

for (const name of job.names) {
  const cp = codepoints[name];
  if (cp === undefined) { missing.push(name); continue; }

  const glyph = font.charToGlyph(String.fromCodePoint(cp));
  if (!glyph || glyph.index === 0) { missing.push(name); continue; }

  // Font space is y-up with the baseline at 0; SVG is y-down in a 0..size
  // box. Shifting by the ascender puts the glyph inside the viewBox.
  const path = glyph.getPath(0, size * (font.ascender / font.unitsPerEm), size);
  glyphs[name] = path.toPathData(3);
}

process.stdout.write(JSON.stringify({ glyphs, missing }));
