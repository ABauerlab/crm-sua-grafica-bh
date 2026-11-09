// Leitura da vitrine pública (public.ecommerce_products): só a chave publicável, sem SKU, custo, margem nem piso.
export interface ItemVitrine {
  ref: string
  produto_slug: string
  categoria: string
  categoria_slug: string
  titulo: string
  cores_rotulo: string | null
  formato_rotulo: string | null
  quantidade: number | null
  preco: number
  parcela_2x: number
  prazo_dias_uteis: number | null
}

const MINUSCULAS = new Set(['e', 'de', 'da', 'do', 'das', 'dos', 'em', 'com', 'para', 'a', 'o'])
/** "PANFLETOS, FLYERS E FOLHETOS" -> "Panfletos, Flyers e Folhetos" */
export function nomeBonito(s: string) {
  return s.toLowerCase().split(' ').map((p, i) => (i > 0 && MINUSCULAS.has(p) ? p : p.charAt(0).toUpperCase() + p.slice(1))).join(' ')
}

export interface CategoriaResumo { slug: string; nome: string; aPartirDe: number; produtos: number }

const URL_SUPABASE = process.env.NEXT_PUBLIC_SUPABASE_URL
const CHAVE = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

async function rest<T>(caminho: string, revalidar = 3600): Promise<T | null> {
  if (!URL_SUPABASE || !CHAVE) return null
  try {
    const res = await fetch(`${URL_SUPABASE}/rest/v1/${caminho}`, {
      headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}` },
      next: { revalidate: revalidar },
    })
    if (!res.ok) return null
    return (await res.json()) as T
  } catch {
    return null
  }
}

/** Categorias com o menor preço ("a partir de"). Lê só colunas leves e agrupa no servidor do site. */
export async function categorias(): Promise<CategoriaResumo[]> {
  const mapa = new Map<string, CategoriaResumo & { slugs: Set<string> }>()
  for (let pagina = 0; pagina < 25; pagina++) {
    const de = pagina * 1000
    const linhas = await rest<Pick<ItemVitrine, 'categoria' | 'categoria_slug' | 'produto_slug' | 'preco'>[]>(
      `ecommerce_products?select=categoria,categoria_slug,produto_slug,preco&ativo=is.true&order=categoria_slug&offset=${de}&limit=1000`)
    if (!linhas?.length) break
    for (const l of linhas) {
      const c = mapa.get(l.categoria_slug) ?? { slug: l.categoria_slug, nome: nomeBonito(l.categoria), aPartirDe: Infinity, produtos: 0, slugs: new Set<string>() }
      c.aPartirDe = Math.min(c.aPartirDe, Number(l.preco))
      c.slugs.add(l.produto_slug)
      c.produtos = c.slugs.size
      mapa.set(l.categoria_slug, c)
    }
    if (linhas.length < 1000) break
  }
  return [...mapa.values()].map(({ slugs: _s, ...c }) => c).sort((a, b) => b.produtos - a.produtos)
}
