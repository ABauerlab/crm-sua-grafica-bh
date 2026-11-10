// Gera ecommerce/public/og-image.jpg (1200x630): logo, slogan e fotos reais de produtos sobre as cores da marca.
// Uso: node scripts/gerar-og-image.cjs  (precisa de internet para baixar as fotos públicas da vitrine)
const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')
const BASE = 'https://bhlosshvwmlyzhbghsrc.supabase.co'
const CHAVE = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || ''
async function fotos() {
  if (!CHAVE) return []
  const out = []
  for (const c of ['cartoes-de-visita', 'panfletos-flyers-e-folhetos', 'sacolas-e-sacos']) {
    const r = await fetch(`${BASE}/rest/v1/rpc/loja_modelos`, { method: 'POST', headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_categorias: [c], p_limite: 1 }) })
    const m = ((await r.json()).modelos || [])[0]
    if (m && m.foto) out.push(`${BASE}/storage/v1/object/public/${m.foto}`)
  }
  return out
}
;(async () => {
  const simbolo = fs.readFileSync(path.join(__dirname, '../ecommerce/public/marca/simbolo.svg'), 'utf8')
  const fs3 = await fotos()
  const html = `<html><body style="margin:0;width:1200px;height:630px;background:#0b0b0f;font-family:Arial Black,Arial,sans-serif;color:#fff;position:relative;overflow:hidden">
  <div style="position:absolute;right:-120px;top:-140px;width:520px;height:520px;border-radius:50%;background:#00A6D6;opacity:.75"></div>
  <div style="position:absolute;right:60px;top:200px;width:460px;height:460px;border-radius:50%;background:#E6007E;opacity:.75;mix-blend-mode:screen"></div>
  <div style="position:absolute;right:300px;top:-60px;width:300px;height:300px;border-radius:50%;background:#FFD500;opacity:.85;mix-blend-mode:screen"></div>
  <div style="position:absolute;left:64px;top:56px;display:flex;align-items:center;gap:18px"><div style="width:86px">${simbolo}</div><div style="font-size:40px;line-height:.95;font-weight:900">SUA<br>GRÁFICA<br><span style="font-weight:600">BH®</span></div></div>
  <div style="position:absolute;left:64px;top:290px;width:560px;font-size:58px;line-height:1.02;font-weight:900">Impressão de qualidade para o <span style="color:#E6007E">seu negócio</span><span style="color:#FFD500">.</span></div>
  <div style="position:absolute;left:64px;bottom:52px;font-size:26px;color:#ffffffcc;font-family:Arial,sans-serif">Pix na hora · 2x sem juros · Retirada na Praça Sete, BH</div>
  ${fs3.map((u, i) => `<img src="${u}" style="position:absolute;width:250px;height:250px;object-fit:cover;border-radius:22px;box-shadow:0 18px 40px #0008;right:${70 + i * 150}px;top:${150 + (i % 2) * 150}px;transform:rotate(${[-6, 4, -3][i]}deg);border:6px solid #fff">`).join('')}
  </body></html>`
  const b = await chromium.launch()
  const p = await b.newPage({ viewport: { width: 1200, height: 630 } })
  await p.setContent(html, { waitUntil: 'networkidle' })
  await p.screenshot({ path: path.join(__dirname, '../ecommerce/public/og-image.jpg'), type: 'jpeg', quality: 88 })
  await b.close()
  console.log('og-image.jpg gerada com', fs3.length, 'fotos')
})()
