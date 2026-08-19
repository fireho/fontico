// Assemble normalised SVG bodies into a TTF.
//
// stdin: { fontName, size, output, glyphs: [{ name, codepoint, svg }] }
import fs from 'fs';
import { Readable } from 'stream';
import { SVGIcons2SVGFontStream } from 'svgicons2svgfont';
import svg2ttf from 'svg2ttf';

const job = JSON.parse(fs.readFileSync(0, 'utf8'));

// 1000 upm with the full em above the baseline keeps icons aligned with text
// instead of drifting against it.
const UPM = 1000;

const stream = new SVGIcons2SVGFontStream({
  fontName: job.fontName,
  fontHeight: UPM,
  ascent: UPM,
  descent: 0,
  normalize: true,
  centerHorizontally: false,
  log: () => {}
});

let svgFont = '';
stream.on('data', (chunk) => { svgFont += chunk; });
stream.on('error', (err) => {
  process.stderr.write(`svgicons2svgfont: ${err.message}\n`);
  process.exit(1);
});
stream.on('finish', () => {
  const ttf = svg2ttf(svgFont, { copyright: job.copyright ?? '' });
  fs.writeFileSync(job.output, Buffer.from(ttf.buffer));

  // Report empty glyphs rather than shipping invisible icons silently.
  // svgicons2svgfont emits d="" rather than omitting the attribute, so an
  // absent-d check alone misses exactly the case that matters.
  const empty = [...svgFont.matchAll(/<glyph glyph-name="([^"]+)"[^>]*\/>/g)]
    .filter((m) => !/\sd="[^"]+"/.test(m[0]))
    .map((m) => m[1]);
  process.stdout.write(JSON.stringify({ bytes: fs.statSync(job.output).size, empty }));
});

for (const glyph of job.glyphs) {
  const readable = Readable.from([glyph.svg]);
  readable.metadata = {
    unicode: [String.fromCodePoint(glyph.codepoint)],
    name: glyph.name
  };
  stream.write(readable);
}
stream.end();
