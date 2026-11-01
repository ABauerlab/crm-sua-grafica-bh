// Varre o menu da origem (categorias e subcategorias) e monta o mapa código (SKU) -> imagem, para saber a cobertura real.
// Rede, manual, NÃO faz parte do npm test. A origem nunca fica no repositório:
//   FOTOS_ORIGEM_BASE=https://... node scripts/fotos-mapear-origem.ts /caminho/saida.json
// Respeita: 1 requisição por segundo, tempo limite de 15 s, User-Agent identificável, sem paralelismo. Não guarda preço nem custo.
import { writeFileSync, existsSync, readFileSync } from 'node:fs'
import { lerCartoes, LIMITES } from '../supabase/functions/_shared/fotos.ts'

const base = (process.env.FOTOS_ORIGEM_BASE ?? '').replace(/\/+$/, '')
const saida = process.argv[2]
if (!base || !saida) { console.error('Uso: FOTOS_ORIGEM_BASE=https://... node scripts/fotos-mapear-origem.ts saida.json'); process.exit(1) }
let ultimo = 0
async function req(url: string, init?: RequestInit): Promise<Response> {
  const e = LIMITES.intervaloOrigemMs - (Date.now() - ultimo); if (e > 0) await new Promise((r) => setTimeout(r, e)); ultimo = Date.now()
  return fetch(url, { ...init, headers: { 'User-Agent': LIMITES.userAgent, ...(init?.headers ?? {}) }, signal: AbortSignal.timeout(LIMITES.timeoutOrigemMs) })
}
interface Item { codigo: string; caminho: string; imagem: string }
const estado: { topos: string[]; feitos: Record<string, Item[]> } = existsSync(saida) ? JSON.parse(readFileSync(saida, 'utf8')) : { topos: [], feitos: {} }
if (!estado.topos.length) {
  const home = await (await req(base + '/')).text()
  estado.topos = [...new Set([...home.matchAll(/listServico\('[^']*',\s*'([^'\/]+)(?:\/[^']*)?'\)/g)].map((m) => m[1]))]
}
console.log(`categorias do menu: ${estado.topos.length}`)
for (const topo of estado.topos) {
  if (estado.feitos[topo]) continue
  const itens: Item[] = []
  const vistos = new Set<string>()
  try {
    for (let pagina = 0; pagina < 400; pagina++) {
      const r = await req(base + '/home/CategoriaPaginada', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: `categoria=${encodeURIComponent(topo)}&pagina=${pagina}` })
      if (!r.ok) break
      const j = await r.json() as { cardsHomepage?: string[] }
      const cards = j.cardsHomepage ?? []
      if (!cards.length) break
      let novos = 0
      for (const c of lerCartoes(cards.join('\n'))) {
        if (vistos.has(c.codigo + c.imagem)) continue
        vistos.add(c.codigo + c.imagem); novos++
        itens.push({ codigo: c.codigo, caminho: c.caminho, imagem: c.imagem })
      }
      if (!novos) break
    }
  } catch (e) { console.error(`erro em ${topo}: ${(e as Error).message}`); continue }
  estado.feitos[topo] = itens
  writeFileSync(saida, JSON.stringify(estado))
  console.log(`${topo}: ${itens.length} itens (${new Set(itens.map((i) => i.imagem)).size} imagens)`)
}
const todos = Object.values(estado.feitos).flat()
console.log(`TOTAL: ${todos.length} itens, ${new Set(todos.map((i) => i.codigo)).size} códigos, ${new Set(todos.map((i) => i.imagem)).size} imagens distintas`)
