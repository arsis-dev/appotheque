// Renders film.html frame by frame. Usage:
//   node render.mjs stills 1.5 6 10.5 18.5    -> stills/t-*.png and stills/sheet.png
//   node render.mjs draft                     -> out/draft.mp4 (15 fps, half size)
//   node render.mjs full                      -> out/video.mp4 (60 fps, then blended to 30 fps) + out/sfx.json
// THEME=…, FONT=… and APP=… pick a variant of the film; OUT=out/<name> renders into its own folder.
import { chromium } from 'playwright';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const here = new URL('.', import.meta.url).pathname;
const [mode = 'stills', ...args] = process.argv.slice(2);
const FILM = process.env.FILM ?? 'film.html', OUT = join(here, process.env.OUT ?? 'out');
// CHROMIUM points at a specific browser; otherwise the cached headless shell is used when present, else Playwright's own.
const cached = join(homedir(), 'Library/Caches/ms-playwright/chromium_headless_shell-1223/chrome-headless-shell-mac-arm64/chrome-headless-shell');
const executablePath = process.env.CHROMIUM ?? (existsSync(cached) ? cached : undefined);
const browser = await chromium.launch({ executablePath, args: ['--allow-file-access-from-files'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
const query = new URLSearchParams(Object.entries({ theme: process.env.THEME, font: process.env.FONT, app: process.env.APP }).filter(([, v]) => v)).toString();
const variant = [process.env.THEME, process.env.FONT, process.env.APP].filter(Boolean).join('-');
await page.goto('file://' + join(here, FILM) + (query ? `?${query}` : ''));
await page.evaluate(() => window.ready);
const duration = await page.evaluate(() => window.DURATION);

// canvas.toDataURL() comes back blank in the headless shell: capture the page after the frame is painted instead.
const frame = async t => {
  await page.evaluate(t => new Promise(r => { window.seek(t); requestAnimationFrame(() => requestAnimationFrame(r)); }), t);
  return page.screenshot({ type: 'png', clip: { x: 0, y: 0, width: 1920, height: 1080 } });
};
const ffmpeg = a => execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...a], { stdio: 'inherit' });

if (mode === 'stills') {
  const dir = join(here, 'stills', FILM.replace('.html', '') + (variant ? '-' + variant : '')); mkdirSync(dir, { recursive: true });
  const times = args.length ? args.map(Number) : [1.5, 6.5, 11, 15.5, 20];
  const files = [];
  for (const t of times) { const f = join(dir, `t-${t.toFixed(2)}.png`); writeFileSync(f, await frame(t)); files.push(f); }
  // Contact sheet: two columns at half size.
  const inputs = files.flatMap(f => ['-i', f]);
  const cols = 2, rows = Math.ceil(files.length / cols);
  const layout = files.map((_, i) => `${(i % cols) * 960}_${Math.floor(i / cols) * 540}`).join('|');
  const scaled = files.map((_, i) => `[${i}:v]scale=960:540[s${i}]`).join(';');
  ffmpeg([...inputs, '-filter_complex', `${scaled};${files.map((_, i) => `[s${i}]`).join('')}xstack=inputs=${files.length}:layout=${layout}:fill=black`, join(dir, 'sheet.png')]);
  console.log(join(dir, 'sheet.png'), rows);
} else {
  const draft = mode === 'draft';
  const fps = draft ? 15 : 60;
  const dir = join(here, 'frames', FILM.replace('.html', '') + (variant ? '-' + variant : '')); rmSync(dir, { recursive: true, force: true }); mkdirSync(dir, { recursive: true });
  const n = Math.round(duration * fps);
  for (let i = 0; i < n; i++) {
    writeFileSync(join(dir, `f${String(i).padStart(5, '0')}.png`), await frame(i / fps));
    if (i % 60 === 0) process.stdout.write(`${i}/${n}\r`);
  }
  mkdirSync(OUT, { recursive: true });
  writeFileSync(join(OUT, 'sfx.json'), JSON.stringify(await page.evaluate(() => window.SFX)));
  writeFileSync(join(OUT, 'music.json'), JSON.stringify(await page.evaluate(() => ({ duration: window.DURATION, ...(window.MUSIC ?? {}) }))));
  const out = join(OUT, draft ? 'draft.mp4' : 'video.mp4');
  // Full render: 60 fps blended pairwise into 30 fps for a light motion blur.
  const vf = draft ? 'scale=960:540' : 'tmix=frames=2:weights=1 1,framestep=2,format=yuv420p';
  ffmpeg(['-framerate', String(fps), '-i', join(dir, 'f%05d.png'), '-vf', vf, '-c:v', 'libx264', '-preset', 'slow', '-crf', draft ? '26' : '16',
    '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', out]);
  console.log(out);
}
await browser.close();
