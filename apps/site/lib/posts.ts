/// <reference types="vite/client" />
import { marked } from 'marked';

export type Post = {
  slug: string;
  title: string;
  description: string;
  date: string;
  updated?: string;
  author: string;
  image?: string;
  imageAlt?: string;
  draft?: boolean;
  body: string;
};

const files = import.meta.glob('../content/blog/*.md', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;

export function parsePost(slug: string, raw: string): Post {
  const m = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) throw new Error(`Post ${slug} is missing frontmatter`);
  const meta: Record<string, string> = {};
  for (const line of m[1].split('\n')) {
    const i = line.indexOf(':');
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2');
  }
  for (const k of ['title', 'description', 'date']) if (!meta[k]) throw new Error(`Post ${slug} is missing "${k}"`);
  return {
    slug,
    title: meta.title,
    description: meta.description,
    date: meta.date,
    updated: meta.updated || undefined,
    author: meta.author || 'Iddo Gino',
    image: meta.image || undefined,
    imageAlt: meta.imageAlt || undefined,
    draft: meta.draft === 'true',
    body: m[2],
  };
}

export const posts: Post[] = Object.entries(files)
  .map(([path, raw]) => parsePost(path.split('/').pop()!.replace(/\.md$/, ''), raw))
  .filter((p) => !p.draft)
  .sort((a, b) => b.date.localeCompare(a.date));

export const getPost = (slug: string) => posts.find((p) => p.slug === slug);

export const renderMarkdown = (md: string) => marked.parse(md, { async: false, gfm: true }) as string;

export const formatDate = (d: string) =>
  new Date(`${d}T00:00:00Z`).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
