import type { Metadata } from 'next';

export const APP_STORE_URL = 'https://apps.apple.com/app/health-mcp-private-sync/id6809625249';

const ogImage = { url: '/og.png', width: 1200, height: 630, alt: 'Health MCP — Your health. Your context. Your key.' };

export function pageMeta(path: string, title: string, description: string): Metadata {
  return {
    title,
    description,
    alternates: { canonical: path },
    openGraph: { type: 'website', siteName: 'Health MCP', url: path, title: `${title} — Health MCP`, description, images: [ogImage] },
    twitter: { card: 'summary_large_image', title: `${title} — Health MCP`, description, images: [ogImage.url] },
  };
}

export const siteMeta = { ogImage };
