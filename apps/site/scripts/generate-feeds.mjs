// Writes public/sitemap.xml and public/blog/rss.xml from static routes + content/blog/*.md.
import { readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const SITE = 'https://healthmcp.cc';
const staticRoutes = [
  { loc: '/', lastmod: '2026-11-27' },
  { loc: '/connect', lastmod: '2026-11-27' },
  { loc: '/privacy', lastmod: '2026-09-08' },
  { loc: '/support', lastmod: '2026-11-17' },
];
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const dir = join(root, 'content/blog');
const posts = readdirSync(dir).filter((f) => f.endsWith('.md')).map((f) => {
  const fm = readFileSync(join(dir, f), 'utf8').match(/^---\n([\s\S]*?)\n---/)?.[1] ?? '';
  const meta = Object.fromEntries(fm.split('\n').map((l) => [l.slice(0, l.indexOf(':')).trim(), l.slice(l.indexOf(':') + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]));
  return { slug: f.replace(/\.md$/, ''), ...meta };
}).filter((p) => p.draft !== 'true').sort((a, b) => b.date.localeCompare(a.date));

const urls = [...staticRoutes];
if (posts.length) {
  urls.push({ loc: '/blog', lastmod: posts[0].updated || posts[0].date });
  for (const p of posts) urls.push({ loc: `/blog/${p.slug}`, lastmod: p.updated || p.date });
}
writeFileSync(join(root, 'public/sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls.map((u) => `<url><loc>${SITE}${u.loc}</loc><lastmod>${u.lastmod}</lastmod></url>`).join('')}</urlset>\n`);

mkdirSync(join(root, 'public/blog'), { recursive: true });
writeFileSync(join(root, 'public/blog/rss.xml'), `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Health MCP Blog</title><link>${SITE}/blog</link><atom:link href="${SITE}/blog/rss.xml" rel="self" type="application/rss+xml"/><description>Guides to connecting Apple Health with AI assistants, privately.</description><language>en</language>${posts.map((p) => `<item><title>${esc(p.title)}</title><link>${SITE}/blog/${p.slug}</link><guid>${SITE}/blog/${p.slug}</guid><pubDate>${new Date(`${p.date}T12:00:00Z`).toUTCString()}</pubDate><description>${esc(p.description)}</description></item>`).join('')}</channel></rss>\n`);
console.log(`feeds: ${urls.length} sitemap URLs, ${posts.length} posts`);
