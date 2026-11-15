// Bling v3: montagem dos corpos de contato e produto, leitura do código de autorização e texto de erro. Funções puras (testadas em Node).

/** Pendências que impedem o envio. As demais (CPF, endereço, e-mail...) seguem como aviso: o operador completa no Bling antes de emitir a nota. */
export function bloqueios(pendencias: string[]): string[] {
  return pendencias.filter((p) => ['pedido_nao_pago', 'pedido_nao_encontrado', 'nome', 'ncm_de_item'].includes(p))
}

function limpar(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(limpar)
  if (v && typeof v === 'object') {
    const o: Record<string, unknown> = {}
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
      const l = limpar(x)
      if (l === null || l === undefined || l === '') continue
      if (typeof l === 'object' && !Array.isArray(l) && Object.keys(l as object).length === 0) continue
      o[k] = l
    }
    return o
  }
  return v
}

/** O Bling quer DDD + número (10 ou 11 dígitos), sem o 55 do país. Número que não fecha com isso não vai (o operador completa no Bling). */
export function celularBling(bruto: unknown): string | undefined {
  let n = String(bruto ?? '').replace(/\D/g, '')
  if ((n.length === 12 || n.length === 13) && n.startsWith('55')) n = n.slice(2)
  return n.length === 10 || n.length === 11 ? n : undefined
}

export function corpoContato(c: Record<string, any>): Record<string, unknown> {
  const celular = celularBling(c.celular)
  return limpar({
    nome: String(c.nome ?? '').slice(0, 120),
    codigo: c.codigo,
    situacao: 'A',
    numeroDocumento: c.numeroDocumento,
    tipo: c.tipo === 'J' ? 'J' : 'F',
    indicadorIe: c.indicadorIe ?? 9,
    ie: c.ie,
    celular,
    email: c.email,
    endereco: c.endereco,
  }) as Record<string, unknown>
}

export function corpoProduto(item: Record<string, any>): Record<string, unknown> {
  const ncm = String(item.ncm ?? '').replace(/\D/g, '')
  return limpar({
    nome: String(item.descricao ?? item.codigo).slice(0, 120),
    codigo: String(item.codigo),
    preco: Number(item.valor) || 0,
    tipo: 'P',
    situacao: 'A',
    formato: 'S',
    unidade: item.unidade ?? 'UN',
    tributacao: { origem: Number(item.origem ?? 0), ncm: ncm.length === 8 ? ncm : undefined },
  }) as Record<string, unknown>
}

/** Aceita o endereço completo para onde o Bling redirecionou (…?code=…&state=…) ou só o código colado. */
export function extrairCodigo(texto: string): { code: string; state?: string } | null {
  const t = texto.trim()
  if (!t) return null
  const m = t.match(/[?&]code=([^&#\s]+)/)
  if (m) return { code: decodeURIComponent(m[1]), state: t.match(/[?&]state=([^&#\s]+)/)?.[1] }
  return /^[A-Za-z0-9_\-.]{16,}$/.test(t) ? { code: t } : null
}

export function textoErroBling(r: { status: number; data: any }): string {
  const e = r.data?.error
  const campos = Array.isArray(e?.fields) ? e.fields.map((f: any) => f?.msg ?? f?.element).filter(Boolean).join('; ') : ''
  const base = e?.description || e?.message || e?.type || r.data?.erro || r.data?.message || `HTTP ${r.status}`
  return `${base}${campos ? ` (${campos})` : ''}`.replace(/\s+/g, ' ').slice(0, 220)
}
