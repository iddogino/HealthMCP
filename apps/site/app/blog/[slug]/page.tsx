import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { APP_STORE_URL, pageMeta } from '@/lib/seo';
import { formatDate, getPost, posts, renderMarkdown } from '@/lib/posts';

type Props = { params: Promise<{ slug: string }> };

export const dynamicParams = false;

export function generateStaticParams() {
  return posts.map((p) => ({ slug: p.slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const post = getPost((await params).slug);
  if (!post) return {};
  const meta = pageMeta(`/blog/${post.slug}`, post.title, post.description);
  const images = post.image ? [{ url: post.image, alt: post.imageAlt ?? post.title }] : meta.openGraph?.images;
  return { ...meta, openGraph: { ...meta.openGraph, type: 'article', publishedTime: post.date, modifiedTime: post.updated ?? post.date, authors: [post.author], images }, twitter: { ...meta.twitter, images: post.image ? [post.image] : meta.twitter?.images } };
}

export default async function BlogPost({ params }: Props) {
  const post = getPost((await params).slug);
  if (!post) notFound();
  const url = `https://healthmcp.cc/blog/${post.slug}`;
  const jsonLd = {
    '@context': 'https://schema.org',
    '@graph': [
      { '@type': 'BlogPosting', headline: post.title, description: post.description, datePublished: post.date, dateModified: post.updated ?? post.date, author: { '@type': 'Person', name: post.author }, publisher: { '@id': 'https://healthmcp.cc/#org' }, mainEntityOfPage: url, url, image: post.image ? new URL(post.image, 'https://healthmcp.cc').href : 'https://healthmcp.cc/og.png' },
      { '@type': 'BreadcrumbList', itemListElement: [
        { '@type': 'ListItem', position: 1, name: 'Home', item: 'https://healthmcp.cc/' },
        { '@type': 'ListItem', position: 2, name: 'Blog', item: 'https://healthmcp.cc/blog' },
        { '@type': 'ListItem', position: 3, name: post.title, item: url },
      ] },
    ],
  };
  return <main className="guide wrap article">
    <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
    <nav className="breadcrumbs" aria-label="Breadcrumb"><a href="/blog">Blog</a></nav>
    <h1>{post.title}</h1>
    <p className="article-meta">By {post.author} · <time dateTime={post.date}>{formatDate(post.date)}</time>{post.updated && post.updated !== post.date ? <> · Updated <time dateTime={post.updated}>{formatDate(post.updated)}</time></> : null}</p>
    {post.image ? <img className="article-hero" src={post.image} alt={post.imageAlt ?? ''} /> : null}
    <div className="article-body" dangerouslySetInnerHTML={{ __html: renderMarkdown(post.body) }} />
    <aside className="article-cta"><strong>Bring Apple Health to your assistant, privately.</strong><p>Health MCP encrypts your data on your iPhone with a key only you hold. Free on the App Store.</p><a className="cta" href={APP_STORE_URL}>Get Health MCP</a> <a className="text-link" href="/connect">Setup guide</a></aside>
  </main>;
}
