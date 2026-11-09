// Blog do site (Fase 8): leitura de feeds, filtro de assunto, prompt e conferência do texto gerado.
// Sem dependências de Deno para poder ser testado no Node (npm run test:blog).

export interface ItemFeed { titulo: string; url: string; resumo: string; data: string | null }
export interface CategoriaLoja { slug: string; nome: string }
export interface PostGerado { titulo: string; resumo: string; corpo: string; categorias: CategoriaLoja[]; relevancia: number }

const ENTIDADES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', hellip: '...', ndash: '-', mdash: '-', laquo: '"', raquo: '"', rsquo: "'", lsquo: "'", ldquo: '"', rdquo: '"' }

/** minúsculas e sem acento, para comparar termos */
export function normalizar(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

/** HTML/CDATA de feed -> texto simples, sem o rodapé automático do WordPress */
export function textoLimpo(html: string | null | undefined): string {
  if (!html) return ''
  return html
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<p>\s*O (?:post|conteúdo)[\s\S]*?apareceu? primeiro em[\s\S]*?<\/p>/gi, '')
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#(\d+);/g, (_m, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_m, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&([a-z]+);/gi, (m, n) => ENTIDADES[n.toLowerCase()] ?? m)
    .replace(/\s*(?:The post|O post|O conteúdo) .{0,200}? (?:appeared first on|apareceu primeiro em|aparece primeiro em) .{0,120}$/i, '')
    .replace(/\s+/g, ' ')
    .trim()
}

function tag(bloco: string, nome: string): string | null {
  const m = bloco.match(new RegExp(`<${nome}(?:\\s[^>]*)?>([\\s\\S]*?)</${nome}>`, 'i'))
  return m ? m[1] : null
}

/** Lê RSS 2.0 ou Atom. Devolve no máximo `max` itens com título, link, resumo e data ISO. */
export function lerFeed(xml: string, max = 30): ItemFeed[] {
  const blocos = xml.match(/<item[\s>][\s\S]*?<\/item>/gi) ?? xml.match(/<entry[\s>][\s\S]*?<\/entry>/gi) ?? []
  const out: ItemFeed[] = []
  for (const b of blocos.slice(0, max)) {
    const titulo = textoLimpo(tag(b, 'title'))
    let url = textoLimpo(tag(b, 'link'))
    if (!url) url = b.match(/<link[^>]*href="([^"]+)"/i)?.[1] ?? ''
    const resumo = textoLimpo(tag(b, 'description') ?? tag(b, 'summary') ?? tag(b, 'content:encoded') ?? tag(b, 'content')).slice(0, 2000)
    const bruta = textoLimpo(tag(b, 'pubDate') ?? tag(b, 'published') ?? tag(b, 'updated') ?? tag(b, 'dc:date'))
    const d = bruta ? new Date(bruta) : null
    if (!titulo || !/^https?:\/\//i.test(url)) continue
    out.push({ titulo: titulo.slice(0, 300), url: url.slice(0, 600), resumo, data: d && !isNaN(d.getTime()) ? d.toISOString() : null })
  }
  return out
}

/** Itens da NewsAPI (/v2/everything) no mesmo formato do feed */
export function itensNewsApi(j: unknown): (ItemFeed & { fonte: string })[] {
  const arts = ((j as { articles?: unknown[] })?.articles ?? []) as { title?: string; url?: string; description?: string; publishedAt?: string; source?: { name?: string } }[]
  return arts.filter((a) => a.title && a.url && a.title !== '[Removed]').map((a) => ({
    titulo: textoLimpo(a.title).slice(0, 300), url: String(a.url).slice(0, 600), resumo: textoLimpo(a.description).slice(0, 2000),
    data: a.publishedAt ?? null, fonte: (a.source?.name ?? 'NewsAPI').slice(0, 80),
  }))
}

/** Filtro barato antes do modelo: precisa de um termo do setor e nenhum termo proibido. */
export function filtroAssunto(texto: string, setor: string[], proibidos: string[]): { ok: boolean; motivo?: string } {
  const t = ` ${normalizar(texto).replace(/[^a-z0-9&-]+/g, ' ')} `
  const proibido = proibidos.find((p) => t.includes(` ${normalizar(p)}`))
  if (proibido) return { ok: false, motivo: `assunto fora do setor (${proibido})` }
  if (!setor.some((s) => t.includes(` ${normalizar(s)}`))) return { ok: false, motivo: 'sem termo do setor gráfico' }
  return { ok: true }
}

export function slugBlog(titulo: string): string {
  const s = normalizar(titulo).replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
  if (s.length <= 80) return s
  const corte = s.slice(0, 81)
  return corte.slice(0, corte.lastIndexOf('-') > 20 ? corte.lastIndexOf('-') : 80)
}

export function promptPost(p: { titulo: string; resumo: string; fonte: string }, categorias: CategoriaLoja[]): string {
  return [
    'Você escreve para o blog da Sua Gráfica BH, gráfica de Belo Horizonte que vende impressos (cartões de visita, panfletos, adesivos, banners, embalagens, brindes e muito mais) pelo site e pelo WhatsApp.',
    'Leia a notícia abaixo, que é só a PAUTA. Responda SOMENTE em JSON com as chaves:',
    '{"relevancia": 0-10, "motivo": "curto", "titulo": "...", "resumo": "...", "corpo": "...", "categorias": ["slug", ...]}',
    'relevancia: quanto o assunto interessa a donos de pequenos negócios que compram impressos, embalagens e comunicação visual (10 = muito). Política, economia geral, esporte, crime, programas sociais e fofoca = 0.',
    'Regras do texto (só se relevancia >= 7; senão devolva os textos vazios):',
    '- Escreva com SUAS palavras em português do Brasil, tom simples e próximo. Nunca copie frases da fonte.',
    '- titulo: até 90 caracteres, sem clickbait. resumo: 1 ou 2 frases, até 220 caracteres.',
    '- corpo: 4 a 6 parágrafos curtos em markdown simples (pode usar "## " para 1 ou 2 subtítulos e "- " para listas). Explique a notícia e depois dê dicas práticas de como um pequeno negócio pode aproveitar a ideia com materiais impressos.',
    '- Cite a fonte no texto de forma natural (ex.: "segundo a ' + p.fonte + '").',
    '- Quando falar de um tipo de produto da lista abaixo, marque assim: [[slug|texto do link]]. Use no máximo 4 marcações e só slugs da lista. Não escreva nenhum endereço de site.',
    '- Nunca fale de preço, prazo, desconto, frete ou promoção. Não invente dados nem números que não estejam na pauta.',
    '- Não use travessão. Não use emoji.',
    '- categorias: 2 a 4 slugs da lista que combinam com o texto.',
    '',
    'Categorias da loja (slug: nome):',
    categorias.map((c) => `${c.slug}: ${c.nome}`).join('\n'),
    '',
    `PAUTA (fonte: ${p.fonte})`,
    `Título: ${p.titulo}`,
    `Resumo: ${p.resumo.slice(0, 1500)}`,
  ].join('\n')
}

/** Trechos de 10 palavras seguidas iguais à fonte indicam cópia. */
export function pareceCopia(texto: string, fonte: string, n = 10): boolean {
  const palavras = (s: string) => normalizar(s).replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(Boolean)
  const f = palavras(fonte)
  if (f.length < n) return false
  const trechos = new Set<string>()
  for (let i = 0; i + n <= f.length; i++) trechos.add(f.slice(i, i + n).join(' '))
  const t = palavras(texto)
  for (let i = 0; i + n <= t.length; i++) if (trechos.has(t.slice(i, i + n).join(' '))) return true
  return false
}

function semTravessao(s: string): string {
  return s.replace(/\s*[—–]\s*/g, ', ').replace(/,\s*,/g, ',')
}

/** Confere o JSON do modelo e devolve o post pronto (links internos montados aqui) ou o motivo da recusa. */
export function validarPost(
  bruto: unknown,
  o: { categorias: CategoriaLoja[]; fonteNome: string; fonteResumo: string; bloqueados: string[]; relevanciaMinima: number },
): { ok: true; post: PostGerado } | { ok: false; motivo: string; relevancia?: number } {
  const r = (bruto ?? {}) as Record<string, unknown>
  const relevancia = Number(r.relevancia)
  if (!Number.isFinite(relevancia)) return { ok: false, motivo: 'resposta do modelo ilegível' }
  if (relevancia < o.relevanciaMinima) return { ok: false, motivo: `pouco relevante (${relevancia}): ${String(r.motivo ?? '').slice(0, 120)}`, relevancia }
  const titulo = semTravessao(String(r.titulo ?? '').trim())
  const resumo = semTravessao(String(r.resumo ?? '').trim())
  let corpo = semTravessao(String(r.corpo ?? '').replace(/\r/g, '').trim())
  if (titulo.length < 15 || titulo.length > 110) return { ok: false, motivo: 'título fora do tamanho', relevancia }
  if (resumo.length < 40 || resumo.length > 300) return { ok: false, motivo: 'resumo fora do tamanho', relevancia }
  if (/https?:\/\/|www\./i.test(corpo + resumo + titulo)) return { ok: false, motivo: 'texto com endereço de site', relevancia }
  const mapa = new Map(o.categorias.map((c) => [c.slug, c.nome]))
  corpo = corpo.replace(/\[\[([a-z0-9-]+)\|([^\]]{1,80})\]\]/g, (_m, slug: string, txt: string) => (mapa.has(slug) ? `[${txt.trim()}](/categoria/${slug})` : txt.trim()))
  corpo = corpo.replace(/\[\[|\]\]/g, '')
  const paragrafos = corpo.split(/\n{2,}/).filter((p) => p.trim() && !p.trim().startsWith('## '))
  if (paragrafos.length < 3 || corpo.length < 700) return { ok: false, motivo: 'texto curto demais', relevancia }
  if (corpo.length > 7000) return { ok: false, motivo: 'texto longo demais', relevancia }
  if (!normalizar(corpo).includes(normalizar(o.fonteNome))) return { ok: false, motivo: 'texto sem crédito à fonte', relevancia }
  const tudo = normalizar(`${titulo} ${resumo} ${corpo}`)
  const bloqueado = o.bloqueados.find((b) => b && tudo.includes(normalizar(b)))
  if (bloqueado) return { ok: false, motivo: 'termo bloqueado no texto', relevancia }
  if (/\bR\$\s*\d|\bdesconto\b|\bpromo[cç][aã]o\b/i.test(corpo)) return { ok: false, motivo: 'texto fala de preço ou promoção', relevancia }
  if (pareceCopia(corpo, o.fonteResumo)) return { ok: false, motivo: 'trecho copiado da fonte', relevancia }
  const cats = [...new Set((Array.isArray(r.categorias) ? r.categorias : []).map(String))].filter((s) => mapa.has(s)).slice(0, 4)
  if (!cats.length) return { ok: false, motivo: 'sem categoria da loja relacionada', relevancia }
  return { ok: true, post: { titulo, resumo, corpo, relevancia, categorias: cats.map((slug) => ({ slug, nome: mapa.get(slug)! })) } }
}
