import type { Metadata } from 'next';
import { pageMeta } from '@/lib/seo';
import { formatDate, posts } from '@/lib/posts';

export const metadata: Metadata = pageMeta('/blog', 'Blog', 'Guides to connecting Apple Health with AI assistants over MCP, privately, plus notes on health data, encryption and setup.');

export default function Blog() {
  return <main className="guide wrap blog-index">
    <p className="eyebrow">THE HEALTH MCP BLOG</p>
    <h1>Guides and notes.</h1>
    <p className="lead">How to bring Apple Health into your AI assistant without giving up control of your data.</p>
    {posts.length === 0 ? <p>The first guides are on their way.</p> : <ul className="post-list">
      {posts.map((p) => <li key={p.slug}><a href={`/blog/${p.slug}`}><h2>{p.title}</h2><p>{p.description}</p><time dateTime={p.date}>{formatDate(p.date)}</time></a></li>)}
    </ul>}
  </main>;
}
