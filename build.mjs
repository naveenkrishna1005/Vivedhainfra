// Build step for Vercel: injects the PUBLIC Supabase URL and publishable/anon key into index.html.
// Only these two public values are ever read. Never add the service_role key, a secret key or the database password here.
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, readdirSync, existsSync } from 'node:fs';
import { Script } from 'node:vm';

const url = (process.env.SUPABASE_URL || '').trim().replace(/\/$/, '');
const key = (process.env.SUPABASE_ANON_KEY || '').trim();
const production = process.env.VERCEL_ENV === 'production';
const fail = (m) => { console.error('\n[build] ' + m + '\n'); process.exit(1); };
const jwtRole = (k) => { try { return JSON.parse(Buffer.from(k.split('.')[1], 'base64url').toString()).role; } catch { return null; } };

if (key && (/^sb_secret_/.test(key) || jwtRole(key) === 'service_role'))
  fail('SUPABASE_ANON_KEY looks like a SECRET / service_role key. Use only the public publishable or anon key.');
if (url && !/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(url))
  fail('SUPABASE_URL must look like https://<project-ref>.supabase.co');
if (!url || !key) {
  if (production) fail('Set SUPABASE_URL and SUPABASE_ANON_KEY in Vercel (Settings > Environment Variables) for Production.');
  console.warn('[build] Supabase variables missing: the reviews section will show "not connected" mode.');
}

let html = readFileSync('index.html', 'utf8');

if (url && key) {
  if (!html.includes('%%SUPABASE_URL%%')) fail('index.html has no %%SUPABASE_URL%% placeholder.');
  html = html.replaceAll('%%SUPABASE_URL%%', url).replaceAll('%%SUPABASE_ANON_KEY%%', key);
}

// Validate every inline classic JavaScript block. External scripts, ES modules and
// non-JavaScript data blocks (for example application/ld+json) are intentionally skipped.
const scriptTags = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)];
for (let i = 0; i < scriptTags.length; i++) {
  const attrs = scriptTags[i][1];
  const code = scriptTags[i][2];
  if (/\bsrc\s*=/.test(attrs)) continue;
  const type = attrs.match(/\btype\s*=\s*["']([^"']+)["']/i)?.[1]?.trim().toLowerCase() || '';
  if (type === 'module' || (type && !['text/javascript', 'application/javascript'].includes(type))) continue;
  try {
    new Script(code, { filename: `index.html inline script ${i + 1}` });
  } catch (e) {
    fail(`inline script ${i + 1} has a syntax error: ${e.message}`);
  }
}

// Add each favicon reference that is missing, without suppressing the other icon links
// when index.html already contains one favicon reference.
const iconLinks = [
  ['favicon.ico', '<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">'],
  ['favicon-32x32.png', '<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">'],
  ['favicon-16x16.png', '<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png">'],
  ['apple-touch-icon.png', '<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">'],
  ['site.webmanifest', '<link rel="manifest" href="/site.webmanifest">'],
];
const presentLinks = iconLinks.filter(([file]) => existsSync(file));
const existingLinkTags = [...html.matchAll(/<link\b[^>]*>/gi)].map((match) => match[0]);
const missingLinks = presentLinks.filter(([file]) => {
  return !existingLinkTags.some((tag) => {
    const href = tag.match(/\bhref\s*=\s*["']([^"']+)["']/i)?.[1];
    if (!href) return false;
    try {
      return new URL(href, 'https://vivedhainfra.com').pathname === `/${file}`;
    } catch {
      return false;
    }
  });
});

if (missingLinks.length) {
  if (!/<\/head\s*>/i.test(html)) fail('index.html has no </head> to add favicon links to.');
  html = html.replace(/<\/head\s*>/i, missingLinks.map(([, tag]) => tag).join('\n') + '\n</head>');
}

mkdirSync('dist', { recursive: true });
writeFileSync('dist/index.html', html);

// Copy every favicon asset that exists, including the Android launcher icons referenced by the manifest.
const iconFiles = [
  'favicon.ico',
  'favicon-16x16.png',
  'favicon-32x32.png',
  'apple-touch-icon.png',
  'android-chrome-192x192.png',
  'android-chrome-512x512.png',
  'site.webmanifest',
];
for (const file of iconFiles) {
  if (existsSync(file)) copyFileSync(file, `dist/${file}`);
}

// Keep the existing Google Search Console verification-file behavior unchanged.
for (const file of readdirSync('.')) {
  if (/^google[0-9a-f]+\.html$/.test(file)) copyFileSync(file, `dist/${file}`);
}

console.log('[build] dist/index.html written' + (url && key ? ' with Supabase configured' : ' (Supabase not configured)'));
