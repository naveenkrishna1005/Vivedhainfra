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
// Safety net: never publish a page whose inline script cannot even be parsed (Vercel then keeps the previous deployment).
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
try { new Script(scripts[scripts.length - 1][1]); } catch (e) { fail('inline script has a syntax error: ' + e.message); }
mkdirSync('dist', { recursive: true });
writeFileSync('dist/index.html', html);
for (const f of readdirSync('.')) if (/^google[0-9a-f]+\.html$/.test(f)) copyFileSync(f, 'dist/' + f); // keep Search Console verification file
console.log('[build] dist/index.html written' + (url && key ? ' with Supabase configured' : ' (Supabase not configured)'));
