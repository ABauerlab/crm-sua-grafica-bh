// Gera os anúncios de marketplace (título de busca, descrição em tópicos, preço com comissão e prazo de fabricação)
// a partir da vitrine e da view catalogo_marketplace. Saída: CSV local (ignorado pelo git; tem SKU interno para o Bling).
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/enrich-marketplace-ads.ts [mercado_livre] [limite]
// Os textos são determinísticos (sem custo de IA); dá para refinar depois com um modelo, mantendo as mesmas regras.
import { writeFileSync } from 'node:fs'
import { descricaoMarketplace, tituloMarketplace } from '../supabase/functions/_shared/bling.ts'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!url || !key) { console.error('Defina SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY.'); process.exit(1) }
const canal = process.argv[2] ?? 'mercado_livre'
const limite = Number(process.argv[3] ?? 50000)

async function pagina(desde: number) {
  const res = await fetch(`${url}/rest/v1/catalogo_marketplace?select=sku,ref,titulo,categoria,quantidade,ncm,unidade,peso_frete_kg,embalagem_cm,marketplaces&order=sku&offset=${desde}&limit=1000`,
    { headers: { apikey: key!, Authorization: `Bearer ${key}` } })
  if (!res.ok) throw new Error(`catalogo_marketplace: ${res.status}`)
  return res.json() as Promise<any[]>
}
async function fichas(refs: string[]) {
  const res = await fetch(`${url}/rest/v1/ecommerce_products?select=ref,cores_rotulo,formato_rotulo,ficha&ref=in.(${refs.join(',')})`, { headers: { apikey: key!, Authorization: `Bearer ${key}` } })
  return new Map(((await res.json()) as any[]).map((x) => [x.ref, x]))
}
const csv = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`
const linhas = [['sku', 'titulo_anuncio', 'descricao', 'preco', 'prazo_fabricacao_dias', 'ncm', 'unidade', 'peso_kg', 'embalagem_cm', 'categoria'].join(',')]
for (let desde = 0; desde < limite; desde += 1000) {
  const lote = await pagina(desde)
  if (!lote.length) break
  const f = await fichas(lote.map((x) => x.ref))
  for (const x of lote) {
    const e = f.get(x.ref) ?? {}
    const m = x.marketplaces?.[canal]
    if (!m) continue
    const p = { titulo: x.titulo, categoria: x.categoria, quantidade: x.quantidade, impressao: e.cores_rotulo, formato: e.formato_rotulo,
      material: e.ficha?.material, espessura: e.ficha?.espessura, acabamento: e.ficha?.acabamento, prazo_dias: m.prazo_fabricacao_dias, observacoes: e.ficha?.observacoes }
    linhas.push([x.sku, tituloMarketplace(p), descricaoMarketplace(p), m.preco, m.prazo_fabricacao_dias, x.ncm, x.unidade, x.peso_frete_kg, x.embalagem_cm, x.categoria].map(csv).join(','))
  }
  if (lote.length < 1000) break
}
const arquivo = `marketplace-anuncios-${canal}.csv`
writeFileSync(arquivo, '﻿' + linhas.join('\n'))
console.log(`${linhas.length - 1} anúncios em ${arquivo}`)
