// Teste real de 15 produtos de categorias diferentes (rede). Não faz parte do npm test.
// A origem NUNCA fica no repositório: informe pela variável de ambiente.  FOTOS_ORIGEM_BASE=https://... node scripts/fotos-live.ts
import { Image } from 'imagescript'
import { escolherCartoes, lerCartoes, LIMITES, processarImagem, slugCategoria } from '../supabase/functions/_shared/fotos.ts'

const base = (process.env.FOTOS_ORIGEM_BASE ?? '').replace(/\/+$/, '')
if (!base) { console.error('Defina FOTOS_ORIGEM_BASE.'); process.exit(1) }
const grupos = ['CARTÕES DE VISITA', 'ADESIVOS', 'POSTAIS', 'PASTAS', 'PLACAS', 'LINHA DE ATACADO', 'PANFLETOS, FLYERS E FOLHETOS', 'SACOLAS E SACOS', 'REVISTA', 'CONVITES',
  'AGENDAS, CADERNOS E APOSTILAS', 'BLOCOS, COMANDAS, RECEITUÁRIOS E TALÕES', 'CANECA, COPOS E TAÇAS', 'BANDEIRAS', 'CREDENCIAIS']
let ultimo = 0
async function get(url: string): Promise<Response> {
  const e = LIMITES.intervaloOrigemMs - (Date.now() - ultimo); if (e > 0) await new Promise((r) => setTimeout(r, e)); ultimo = Date.now()
  return fetch(url, { headers: { 'User-Agent': LIMITES.userAgent }, signal: AbortSignal.timeout(LIMITES.timeoutOrigemMs) })
}
const cache = new Map<string, { bytes: number[]; ms: number }>()
let chamadasOrigem = 0
async function foto(grupo: string) {
  const t0 = Date.now()
  if (cache.has(grupo)) return { ...cache.get(grupo)!, via: 'cache', ms: Date.now() - t0 }
  chamadasOrigem++
  const pg = await get(`${base}/produto/categoria/${slugCategoria(grupo)}`)
  if (!pg.ok) return { bytes: [], via: `HTTP ${pg.status}`, ms: Date.now() - t0 }
  const cs = lerCartoes(await pg.text()); if (!cs.length) return { bytes: [], via: 'sem cartões', ms: Date.now() - t0 }
  const { itens } = escolherCartoes(cs, null, 10)
  const tam: number[] = []
  for (const c of itens) {
    if (tam.length >= 3) break
    chamadasOrigem++
    const r = await get(c.imagem); if (!r.ok) continue
    const p = await processarImagem(new Uint8Array(await r.arrayBuffer()), { decode: (d) => Image.decode(d) })
    if (!('descartada' in p)) tam.push(p.tamanho)
  }
  cache.set(grupo, { bytes: tam, ms: 0 })
  return { bytes: tam, via: 'busca', ms: Date.now() - t0 }
}
console.log('grupo | via | imagens | KB por imagem | ms')
let maior = 0
for (const g of grupos) { const r = await foto(g); maior = Math.max(maior, ...r.bytes); console.log(`${g} | ${r.via} | ${r.bytes.length} | ${r.bytes.map((b) => Math.round(b / 1024)).join(', ')} | ${r.ms}`) }
const antes = chamadasOrigem
console.log('--- segunda rodada (cache)')
for (const g of grupos) { const r = await foto(g); console.log(`${g} | ${r.via} | ${r.ms} ms`) }
console.log(`chamadas à origem: primeira rodada ${antes}, segunda rodada +${chamadasOrigem - antes}; maior imagem ${Math.round(maior / 1024)} KB (teto ${LIMITES.tetoBytes / 1024} KB)`)
