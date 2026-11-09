import type { MetadataRoute } from 'next'
import { SITE } from '@/lib/site'
import { slugs } from '@/lib/vitrine'

export const revalidate = 3600

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const s = await slugs()
  return [
    ...['', '/categorias', '/ajuda'].map((p) => ({ url: `${SITE.url}${p}`, changeFrequency: 'weekly' as const, priority: p ? 0.7 : 1 })),
    ...s.categorias.map((c) => ({ url: `${SITE.url}/categoria/${c}`, changeFrequency: 'weekly' as const, priority: 0.8 })),
    ...s.produtos.map((p) => ({ url: `${SITE.url}/produto/${p.s}`, lastModified: p.u, changeFrequency: 'weekly' as const, priority: 0.6 })),
  ]
}
