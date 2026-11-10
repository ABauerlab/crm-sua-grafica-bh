// Leitura da vitrine pública pelo banco (funções loja_*), só com a chave publicável. Sem SKU, custo, margem nem piso.
const URL_SUPABASE = process.env.NEXT_PUBLIC_SUPABASE_URL
const CHAVE = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

export interface Opcao { ref: string; sku?: string | null; quantidade: number | null; preco: number; parcela_2x: number; peso_kg?: number | null }
export interface Modelo {
  titulo: string; categoria: string; categoria_slug: string; produto_slug: string; foto: string | null; a_partir_de: number
  parcela_2x_a_partir_de: number; sku: string | null; ref: string; quantidade: number | null; variacoes: number
}
export interface ProdutoResumo {
  produto_slug: string; titulo: string; categoria: string; categoria_slug: string; impressao: string | null; formato: string | null
  foto: string | null; a_partir_de: number; parcela_2x_a_partir_de: number; prazo_dias_uteis: number | null; opcoes: Opcao[]; sku?: string | null
}
export interface Ficha {
  titulo?: string; material?: string | null; espessura?: string | null; impressao?: string | null; tamanho_final?: string | null
  arte_com_sangria?: string | null; acabamento?: string | null; observacoes?: string[]
}
export interface Produto {
  produto_slug: string; titulo: string; categoria: string; categoria_slug: string; impressao: string | null; formato: string | null
  especificacao: string | null; descricao: string | null; ficha: Ficha | null; acabamentos: string[] | null; fotos: string[]
  prazo_dias_uteis: number | null; a_partir_de: number; ate: number; opcoes: Opcao[]; atualizado_em: string
  sku?: string | null; irmaos: { produto_slug: string; impressao: string | null; formato: string | null; a_partir_de: number }[]
  variacoes: { produto_slug: string; titulo: string; impressao: string | null; formato: string | null; a_partir_de: number; foto: string | null }[]
}
export interface CategoriaResumo { slug: string; nome: string; produtos: number; a_partir_de: number; foto: string | null }

export async function rpc<T>(fn: string, args: Record<string, unknown> = {}, revalidar = 3600): Promise<T | null> {
  if (!URL_SUPABASE || !CHAVE) return null
  try {
    const res = await fetch(`${URL_SUPABASE}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
      next: { revalidate: revalidar },
    })
    if (!res.ok) return null
    return (await res.json()) as T
  } catch {
    return null
  }
}

const MINUSCULAS = new Set(['e', 'de', 'da', 'do', 'das', 'dos', 'em', 'com', 'para', 'a', 'o'])
/** "PANFLETOS, FLYERS E FOLHETOS" -> "Panfletos, Flyers e Folhetos" */
export function nomeBonito(s: string) {
  return s.toLowerCase().split(' ').map((p, i) => (i > 0 && MINUSCULAS.has(p) ? p : p.charAt(0).toUpperCase() + p.slice(1))).join(' ')
}

/** Caminho do Storage público -> URL. */
export function fotoUrl(caminho: string | null | undefined): string | null {
  return caminho && URL_SUPABASE ? `${URL_SUPABASE}/storage/v1/object/public/${caminho}` : null
}

export async function categorias(): Promise<CategoriaResumo[]> {
  const r = await rpc<CategoriaResumo[]>('loja_categorias')
  return (r ?? []).map((c) => ({ ...c, nome: nomeBonito(c.nome), a_partir_de: Number(c.a_partir_de) }))
}

export async function buscar(termo: string | null, categoria: string | null = null, limite = 24) {
  const r = await rpc<{ total: number; produtos: ProdutoResumo[] }>('loja_buscar', { p_termo: termo, p_limite: limite, p_categoria: categoria }, 900)
  return { total: r?.total ?? 0, produtos: (r?.produtos ?? []).map((p) => ({ ...p, categoria: nomeBonito(p.categoria) })) }
}

export async function produto(slug: string): Promise<Produto | null> {
  const p = await rpc<Produto | null>('loja_produto', { p_slug: slug }, 900)
  return p ? { ...p, categoria: nomeBonito(p.categoria) } : null
}

export async function slugs() {
  return (await rpc<{ produtos: { s: string; u: string }[]; categorias: string[] }>('loja_slugs', {}, 3600)) ?? { produtos: [], categorias: [] }
}

/** Modelos comerciais (papel/acabamento) com foto real, SKU e preço "a partir de". Substitui os antigos cartões de contagem. */
export async function modelos(categoriasSlug: string[] | null, opts: { termo?: string | null; limite?: number; pagina?: number } = {}) {
  const limite = opts.limite ?? 24
  const r = await rpc<{ total: number; modelos: Modelo[] }>('loja_modelos', {
    p_categorias: categoriasSlug, p_termo: opts.termo ?? null, p_limite: limite, p_offset: ((opts.pagina ?? 1) - 1) * limite,
  }, 900)
  return { total: r?.total ?? 0, modelos: (r?.modelos ?? []).map((m) => ({ ...m, categoria: nomeBonito(m.categoria), a_partir_de: Number(m.a_partir_de), parcela_2x_a_partir_de: Number(m.parcela_2x_a_partir_de) })) }
}
