// Leitura da vitrine pública pelo banco (funções loja_*), só com a chave publicável. Sem SKU, custo, margem nem piso.
const URL_SUPABASE = process.env.NEXT_PUBLIC_SUPABASE_URL
const CHAVE = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

export interface Opcao { ref: string; sku?: string | null; sku_slug?: string | null; variante?: string | null; quantidade: number | null; preco: number; parcela_2x: number; prazo_dias_uteis?: number | null; peso_kg?: number | null }
/** Um SKU = um produto (card da lista). Os nomes `a_partir_de` e `variacoes` ficam por compatibilidade com os blocos antigos. */
export interface Modelo {
  titulo: string; categoria: string; categoria_slug: string; produto_slug: string; foto: string | null; a_partir_de: number
  parcela_2x_a_partir_de: number; sku: string | null; ref: string; quantidade: number | null; variacoes: number
  subcategoria?: string | null; sub?: string | null; prazo_dias_uteis?: number | null; acab?: string[] | null
  familia?: string; tags?: string[] | null; tamanhos?: number
  sku_slug?: string | null; variante?: string | null; impressao?: string | null; formato?: string | null
}
interface SkuLinha {
  ref: string; sku: string | null; sku_slug: string | null; produto_slug: string; titulo: string; categoria: string; categoria_slug: string; foto: string | null
  preco: number | string; parcela_2x: number | string; quantidade: number | null; prazo_dias_uteis: number | null; impressao: string | null; formato: string | null
  variante: string | null; sub: string | null; subcategoria: string | null; acab: string[] | null
}
export interface SkuProduto {
  ref: string; sku: string | null; sku_slug: string; produto_slug: string; variante: string | null; titulo: string; categoria: string; categoria_slug: string
  impressao: string | null; formato: string | null; especificacao: string | null; descricao: string | null; ficha: Ficha | null; acabamentos: string[] | null
  fotos: string[]; prazo_dias_uteis: number | null; quantidade: number | null; preco: number; parcela_2x: number; peso_kg?: number | null; atualizado_em: string
  quantidades: Opcao[]
  irmaos: { produto_slug: string; impressao: string | null; formato: string | null; a_partir_de: number; ref: string; sku_slug: string; quantidade: number | null }[]
  variacoes: { produto_slug: string; titulo: string; impressao: string | null; formato: string | null; a_partir_de: number; foto: string | null; ref: string; sku_slug: string }[]
}
export interface ProdutoResumo {
  produto_slug: string; titulo: string; categoria: string; categoria_slug: string; impressao: string | null; formato: string | null
  foto: string | null; a_partir_de: number; parcela_2x_a_partir_de: number; prazo_dias_uteis: number | null; opcoes: Opcao[]; sku?: string | null
}
export interface Ficha {
  titulo?: string; material?: string | null; material_catalogo?: string | null; gramatura_g?: number | null; codigo_cores?: string | null
  acabamentos_catalogo?: string[] | null; espessura?: string | null; impressao?: string | null; tamanho_final?: string | null
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

const MATERIAIS_LOJA: Record<string, string> = { couche: 'Papel Couchê', offset: 'Papel Offset', sulfite: 'Papel Sulfite', kraft: 'Papel Kraft', supremo: 'Papel Supremo', triplex: 'Papel Triplex', duplex: 'Papel Duplex', bopp: 'BOPP', vinil: 'Vinil', pvc: 'PVC', pet: 'PET', lona: 'Lona', tecido: 'Tecido' }
const ACABAMENTOS_LOJA: Record<string, string> = { brilho: 'Laminação Brilho', fosca: 'Laminação Fosca', uv: 'Verniz UV', 'soft-touch': 'Laminação Soft Touch', 'hot-stamping': 'Hot Stamping', relevo: 'Relevo Seco', holografica: 'Holográfico', padrao: 'Padrão' }
export function materialLegivel(material: string | null | undefined): string | null {
  const value = material?.trim(); if (!value) return null
  const key = value.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/^papel\s+/, '').replace(/\s+/g, '-')
  return MATERIAIS_LOJA[key] ?? (key.startsWith('couche') ? `Papel ${nomeBonito(value)}` : nomeBonito(value))
}
export function acabamentoLegivel(acabamento: string): string {
  const key = acabamento.trim().toLowerCase()
  return ACABAMENTOS_LOJA[key] ?? nomeBonito(acabamento.replace(/-/g, ' '))
}
export function impressaoComCodigo(impressao: string | null | undefined, codigo: string | null | undefined): string | null {
  if (!impressao && !codigo) return null
  if (!codigo) return impressao ?? null
  return impressao ? `${impressao} (${codigo.trim().toLowerCase()})` : codigo.trim().toLowerCase()
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

/** Ordem das impressões: colorido frente (4x0), colorido + preto no verso (4x1), colorido frente e verso (4x4), depois preto e branco. */
export function ordemImpressao(i: string | null | undefined) {
  const t = (i ?? '').toLowerCase()
  return t === 'colorido apenas na frente' ? 1 : t === 'colorido na frente e preto e branco no verso' ? 2 : t === 'colorido frente e verso' ? 3 : t === 'preto e branco apenas na frente' ? 4 : t === 'preto e branco frente e verso' ? 5 : 9
}

export async function produto(slug: string): Promise<Produto | null> {
  const p = await rpc<Produto | null>('loja_produto', { p_slug: slug }, 900)
  if (!p) return null
  const irmaos = [...(p.irmaos ?? [])].sort((a, b) => ordemImpressao(a.impressao) - ordemImpressao(b.impressao) || (a.formato ?? '').localeCompare(b.formato ?? '') || a.a_partir_de - b.a_partir_de)
  const opcoes = [...(p.opcoes ?? [])].sort((a, b) => (a.quantidade ?? 0) - (b.quantidade ?? 0) || a.preco - b.preco)
  return { ...p, categoria: nomeBonito(p.categoria), irmaos, opcoes }
}

export async function slugs() {
  return (await rpc<{ produtos: { s: string; u: string }[]; categorias: string[] }>('loja_slugs', {}, 3600)) ?? { produtos: [], categorias: [] }
}

/** Modelos comerciais (papel/acabamento) com foto real, SKU e preço "a partir de". Substitui os antigos cartões de contagem. */
export async function modelos(categoriasSlug: string[] | null, opts: { termo?: string | null; limite?: number; pagina?: number } = {}) {
  return modelosFiltrados(categoriasSlug, opts)
}

// ---- Fase 12: taxonomia, filtros facetados e busca por sinônimos ----
export interface Subcategoria { slug: string; nome: string; modelos: number; foto?: string | null }
export interface CategoriaArvore { slug: string; nome: string; produtos: number; modelos: number; a_partir_de: number; foto: string | null; subcategorias: Subcategoria[] }
export interface Vertical { id: string; nome: string; descricao: string | null; modelos: number; categorias: CategoriaArvore[] }
export type Filtros = Partial<Record<'sub' | 'tipo' | 'material' | 'gram' | 'acab' | 'formato' | 'prazo' | 'preco', string[]>>
export interface ItemFaceta { valor: string; rotulo: string; n: number }
export type Facetas = Partial<Record<keyof Filtros, ItemFaceta[]>>

export async function arvore(): Promise<Vertical[]> {
  const r = await rpc<{ verticais: Vertical[] }>('loja_arvore', {}, 3600)
  return (r?.verticais ?? []).map((v) => ({ ...v, categorias: v.categorias.map((c) => ({ ...c, nome: nomeBonito(c.nome), a_partir_de: Number(c.a_partir_de) })) }))
}

/** O banco espera {"sub": "slug", ...listas}; "sub" é um valor só. */
function paraBanco(f: Filtros) {
  const o: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(f)) if (v?.length) o[k] = k === 'sub' ? v[0] : v
  return o
}

export async function facetas(categoriasSlug: string[] | null, termo: string | null, f: Filtros = {}) {
  const r = await rpc<{ total: number; facetas: Facetas }>('loja_facetas_sku', { p_categorias: categoriasSlug, p_termo: termo, p_filtros: paraBanco(f) }, 900)
  return { total: r?.total ?? 0, facetas: r?.facetas ?? {} }
}

/** Facetas da loja inteira (pré-calculadas no banco; usadas na home). */
export async function facetasHome() {
  const r = await rpc<{ total: number; facetas: Facetas }>('loja_facetas_home', {}, 900)
  return { total: r?.total ?? 0, facetas: r?.facetas ?? {} }
}

/** Lista de SKUs (cada um é um produto, com foto, preço e URL próprios). Mantém o formato de `Modelo` para os componentes. */
export async function modelosFiltrados(categoriasSlug: string[] | null, opts: { termo?: string | null; filtros?: Filtros; ordem?: string; limite?: number; pagina?: number } = {}) {
  const limite = opts.limite ?? 24
  const r = await rpc<{ total: number; itens: SkuLinha[] }>('loja_sku_lista', {
    p_categorias: categoriasSlug, p_termo: opts.termo ?? null, p_filtros: paraBanco(opts.filtros ?? {}), p_ordem: opts.ordem ?? 'relevancia',
    p_limite: limite, p_offset: ((opts.pagina ?? 1) - 1) * limite,
  }, 900)
  const modelos: Modelo[] = (r?.itens ?? []).map((i) => ({
    titulo: i.titulo, categoria: nomeBonito(i.categoria), categoria_slug: i.categoria_slug, produto_slug: i.produto_slug, foto: i.foto,
    a_partir_de: Number(i.preco), parcela_2x_a_partir_de: Number(i.parcela_2x), sku: i.sku, ref: i.ref, quantidade: i.quantidade, variacoes: 0,
    subcategoria: i.subcategoria, sub: i.sub, prazo_dias_uteis: i.prazo_dias_uteis, acab: i.acab,
    sku_slug: i.sku_slug, variante: i.variante, impressao: i.impressao, formato: i.formato,
  }))
  return { total: r?.total ?? 0, modelos }
}

/** Página de um SKU. O fim da URL é a ref estável (12 caracteres hexadecimais); o resto é só texto para leitura e busca. */
export const REF_DA_URL = /-([a-f0-9]{12})$/
export async function skuProduto(slug: string): Promise<SkuProduto | null> {
  const ref = REF_DA_URL.exec(slug)?.[1]
  if (!ref) return null
  const p = await rpc<SkuProduto | null>('loja_sku_produto', { p_ref: ref }, 900)
  if (!p) return null
  const quantidades = [...(p.quantidades ?? [])].sort((a, b) => (a.quantidade ?? 0) - (b.quantidade ?? 0) || Number(a.preco) - Number(b.preco))
  const irmaos = [...(p.irmaos ?? [])].sort((a, b) => ordemImpressao(a.impressao) - ordemImpressao(b.impressao) || (a.formato ?? '').localeCompare(b.formato ?? '') || Number(a.a_partir_de) - Number(b.a_partir_de))
  return { ...p, categoria: nomeBonito(p.categoria), preco: Number(p.preco), parcela_2x: Number(p.parcela_2x), quantidades, irmaos }
}

/** Link antigo (produto agrupado): devolve o SKU mais barato do grupo, para redirecionar. */
export async function skuDoProdutoAntigo(produtoSlug: string): Promise<string | null> {
  const r = await rpc<string | null>('loja_sku_do_produto', { p_produto_slug: produtoSlug }, 3600)
  return r ? r.split('|')[1] ?? null : null
}

/** Sitemap: todos os SKUs, em páginas. */
export async function skuSlugs(offset: number, limite = 5000) {
  return (await rpc<{ s: string; u: string }[]>('loja_sku_slugs', { p_offset: offset, p_limite: limite }, 3600)) ?? []
}

/** "papel grosso aveludado" -> { termo: null, filtros: { gram: ['encorpado'], acab: ['soft-touch'] } } */
export async function interpretarBusca(termo: string): Promise<{ termo: string | null; filtros: Filtros }> {
  const r = await rpc<{ termo: string | null; filtros: Filtros }>('loja_interpretar_busca', { p_termo: termo }, 3600)
  return r ?? { termo, filtros: {} }
}

export interface FamiliaTamanho { produto_slug: string; tamanho: string; impressao: string | null; a_partir_de: number; quantidade: number | null; prazo_dias_uteis: number | null; ref: string }
export interface Familia { familia: string; titulo: string; categoria: string; categoria_slug: string; subcategoria: string | null; sub: string | null; foto: string | null; tags: string[] | null; tamanhos: FamiliaTamanho[] }

/** Uma opção (ex.: "Banners Front Light 240g") com a lista de tamanhos disponíveis. */
export async function familia(id: string): Promise<Familia | null> {
  if (!/^[a-f0-9]{32}$/.test(id)) return null
  const r = await rpc<Familia | null>('loja_familia', { p_familia: id }, 900)
  return r ? { ...r, categoria: nomeBonito(r.categoria), tamanhos: r.tamanhos.map((t) => ({ ...t, a_partir_de: Number(t.a_partir_de) })).sort((a, b) => Number(/metro/i.test(a.tamanho)) - Number(/metro/i.test(b.tamanho))) } : null
}

/** "Colorido Apenas na Frente" -> "Colorido na frente" (rótulo curto para o card). */
export function impressaoCurta(i: string | null | undefined): string | null {
  const t = (i ?? '').trim().toLowerCase()
  if (!t) return null
  const mapa: Record<string, string> = {
    'colorido apenas na frente': 'Colorido na frente', 'colorido frente e verso': 'Colorido frente e verso',
    'colorido na frente e preto e branco no verso': 'Colorido + P&B no verso', 'preto e branco apenas na frente': 'P&B na frente', 'preto e branco frente e verso': 'P&B frente e verso',
  }
  return mapa[t] ?? (i as string)
}

/** Texto do card sem espaços duplos nem pontas soltas. */
export const limparTitulo = (t: string) => t.replace(/\(\s*\)/g, '').replace(/\s+/g, ' ').replace(/^[\s,.-]+|[\s,.-]+$/g, '')
