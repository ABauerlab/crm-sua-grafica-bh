import type { MetadataRoute } from 'next'
import { SITE } from '@/lib/site'
// Versão inicial: páginas fixas. Produtos e categorias entram no sitemap na Fase 10.
export default function sitemap(): MetadataRoute.Sitemap {
  return ['', '/categorias', '/ajuda'].map((p) => ({ url: `${SITE.url}${p}`, changeFrequency: 'weekly', priority: p ? 0.7 : 1 }))
}
