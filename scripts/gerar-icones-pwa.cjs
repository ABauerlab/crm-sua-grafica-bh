// Gera os ícones do PWA a partir do símbolo oficial (public/favicon.svg, brand kit v1.0). Uso: node scripts/gerar-icones-pwa.cjs
const { chromium } = require('playwright')
const fs = require('node:fs')
const path = require('node:path')

const svg = fs.readFileSync(path.join(__dirname, '../public/favicon.svg'), 'utf8').replace(/<title>.*?<\/title>/, '')
const out = path.join(__dirname, '../public/icons')
// fundo branco do brand kit; "maskable" deixa o símbolo na zona segura central (60%) para qualquer recorte
const jobs = [
  ...[48, 72, 96, 128, 144, 152, 192, 256, 384, 512].map((s) => ({ nome: `icon-${s}.png`, s, escala: 0.7 })),
  { nome: 'apple-touch-icon.png', s: 180, escala: 0.7 }, // iOS: sem transparência
  { nome: 'icon-maskable-512.png', s: 512, escala: 0.56 },
  { nome: 'icon-maskable-192.png', s: 192, escala: 0.56 },
  { nome: 'badge-96.png', s: 96, escala: 0.8, mono: true }, // selo da notificação: só a silhueta
]

;(async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  for (const j of jobs) {
    const lado = Math.round(j.s * j.escala)
    const marca = j.mono ? svg.replace(/fill="#[0-9A-Fa-f]{6}"/g, 'fill="#000"') : svg
    const html = `<body style="margin:0;background:${j.mono ? 'transparent' : '#ffffff'};width:${j.s}px;height:${j.s}px;display:flex;align-items:center;justify-content:center">
      <div style="width:${lado}px;height:${lado}px">${marca.replace('<svg ', '<svg width="100%" height="100%" ')}</div></body>`
    await page.setViewportSize({ width: j.s, height: j.s })
    await page.setContent(html)
    await page.screenshot({ path: path.join(out, j.nome), omitBackground: !!j.mono })
  }
  await browser.close()
  console.log(`${jobs.length} ícones gerados em public/icons`)
})()
