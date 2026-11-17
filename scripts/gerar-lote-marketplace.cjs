// Gera as imagens de todas as famílias do lote (dados públicos de especificação, sem custo nem SKU).
//   node scripts/gerar-lote-marketplace.cjs <familias.json> <saida_dir> [limite]
// familias.json vem de public.marketplace_familias_publico(). As fotos base saem do bucket público loja-produtos.
const { chromium } = require('playwright')
const fs = require('node:fs')
const path = require('node:path')
const { gerarImagens } = require('./gerar-imagens-marketplace.cjs')

const BASE = process.env.SUPABASE_URL || 'https://bhlosshvwmlyzhbghsrc.supabase.co'
const APLICACOES = {
  'CARTÕES DE VISITA': ['Profissionais', 'Lojas', 'Clínicas', 'Eventos', 'Autônomos'], ADESIVOS: ['Embalagens', 'Delivery', 'Lojas', 'Brindes', 'E-commerce'],
  TAGS: ['Lojas de roupa', 'Brechós', 'Artesanato', 'Presentes', 'E-commerce'], 'WIND BANNER': ['Lojas', 'Eventos', 'Feiras', 'Calçadas', 'Promoções'],
}
const titulo = (f) => (f.ficha?.titulo || `${f.categoria} ${f.descricao || ''}`).replace(/\s+/g, ' ').trim()
function tamanho(f) {
  const t = f.ficha?.tamanho_final || f.formato || ''
  const m = t.match(/([\d.,]+)\s*x\s*([\d.,]+)\s*(mm|cm|m)\b/i)
  if (!m) return null
  const k = { mm: 1, cm: 10, m: 1000 }[m[3].toLowerCase()]
  const w = parseFloat(m[1].replace(',', '.')) * k, h = parseFloat(m[2].replace(',', '.')) * k
  const fmt = (mm) => (mm >= 1000 ? `${(mm / 1000).toString().replace('.', ',')} m` : `${(mm / 10).toString().replace('.', ',')} cm`)
  return { mm: [w, h], cw: fmt(w), ch: fmt(h), texto: t }
}
async function main() {
  const [arq, out, lim] = process.argv.slice(2)
  const fams = JSON.parse(fs.readFileSync(arq, 'utf8')).slice(0, Number(lim || 9999))
  fs.mkdirSync(path.join(out, '_fotos'), { recursive: true })
  const browser = await chromium.launch()
  let ok = 0
  const falhas = []
  for (const f of fams) {
    try {
      const fotoPath = path.join(out, '_fotos', `${f.codigo_pai}.jpg`)
      if (!fs.existsSync(fotoPath)) {
        const r = await fetch(`${BASE}/storage/v1/object/public/${f.foto}`)
        if (!r.ok) throw new Error(`foto ${r.status}`)
        fs.writeFileSync(fotoPath, Buffer.from(await r.arrayBuffer()))
      }
      const t = tamanho(f)
      const fi = f.ficha || {}
      await gerarImagens(browser, {
        foto: fotoPath, nome: titulo(f).slice(0, 70), material: [fi.material, fi.espessura].filter(Boolean).join(' ') || f.descricao || '-',
        impressao: fi.impressao || f.cores || '-', acabamento: fi.acabamento || 'Corte reto de precisão', prazo_dias: (f.prazo || 3) + 2,
        tamanho_final: t ? t.texto : (f.formato || '-'), arte: fi.arte_com_sangria || t?.texto || '-', tamanho_mm: t ? t.mm : [100, 100], cota_w: t?.cw, cota_h: t?.ch,
        furo: /furo/i.test(`${fi.acabamento} ${f.descricao}`) || f.categoria === 'TAGS', corte: f.categoria === 'TAGS' ? 'Corte a laser de precisão' : 'Corte de precisão', quantidades: f.quantidades, aplicacoes: APLICACOES[f.categoria] || ['Lojas', 'Escritórios', 'Eventos', 'Delivery', 'E-commerce'],
      }, path.join(out, f.codigo_pai))
      ok++
    } catch (e) { falhas.push(`${f.codigo_pai}: ${e.message}`) }
  }
  await browser.close()
  console.log(`${ok} famílias geradas; falhas: ${falhas.length}`)
  falhas.forEach((x) => console.log(x))
}
main()
