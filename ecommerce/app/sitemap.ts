import type { MetadataRoute } from 'next'
import { SITE } from '@/lib/site'
import { skuSlugs, slugs } from '@/lib/vitrine'
import { slugsBlog } from '@/lib/blog'

export const revalidate = 3600

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  // 1 SKU = 1 página; um arquivo só (limite do sitemap é 50 mil URLs), buscado em lotes de 5 mil
  const [s, posts, ...lotes] = await Promise.all([slugs(), slugsBlog(), ...[0, 1, 2, 3, 4, 5, 6, 7].map((i) => skuSlugs(i * 5000, 5000))])
  const skus = lotes.flat()
  return [
    ...['', '/categorias', '/departamentos', '/ajuda', '/blog'].map((p) => ({ url: `${SITE.url}${p}`, changeFrequency: 'weekly' as const, priority: p ? 0.7 : 1 })),
    ...s.categorias.map((c) => ({ url: `${SITE.url}/categoria/${c}`, changeFrequency: 'weekly' as const, priority: 0.8 })),
    ...posts.map((p) => ({ url: `${SITE.url}/blog/${p.s}`, lastModified: p.u, changeFrequency: 'monthly' as const, priority: 0.5 })),
    ...skus.map((p) => ({ url: `${SITE.url}/produto/${p.s}`, lastModified: p.u, changeFrequency: 'weekly' as const, priority: 0.6 })),
  ]
}
