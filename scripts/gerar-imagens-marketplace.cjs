// Gera o carrossel de 5 imagens (1200x1200, JPEG) de um anúncio de marketplace a partir de uma foto base.
//   node scripts/gerar-imagens-marketplace.cjs <config.json> <saida_dir>
// config.json: { slug, foto (caminho local), nome, material, impressao, acabamento, tamanho_final, arte, prazo_dias, quantidades[], aplicacoes[] }
// Regras de compliance: sem telefone, WhatsApp, URL, QR Code, SKU nem nome de fornecedor nas imagens (o teste abaixo reprova).
// A foto 01 é fundo branco puro, sem texto, produto ocupando ~85% do quadro.
const { chromium } = require('playwright')
const fs = require('node:fs')
const path = require('node:path')

const CORES = { ciano: '#00AEEF', magenta: '#FF0066', amarelo: '#FFD600', preto: '#171717' }
const PROIBIDO = /(https?:\/\/|www\.|\.com|whats|zap|\(\d{2}\)|\d{4,5}-\d{4}|sku)/i

const base = (corpo) => `<!doctype html><html><head><meta charset="utf-8"><style>
*{box-sizing:border-box;margin:0;padding:0}body{width:1200px;height:1200px;background:#fff;font-family:Inter,Montserrat,Arial,sans-serif;color:${CORES.preto};overflow:hidden;position:relative}
.faixa{position:absolute;left:0;top:0;width:100%;height:14px;background:linear-gradient(90deg,${CORES.ciano} 0 33%,${CORES.magenta} 33% 66%,${CORES.amarelo} 66%)}
h1{font-size:58px;font-weight:800;line-height:1.1;letter-spacing:-1px}.sub{font-size:30px;color:#555;margin-top:10px}
.pad{padding:70px 70px}.card{border-radius:28px;padding:34px;background:#f4f6f8}.rotulo{font-size:24px;font-weight:700;color:#777;text-transform:uppercase;letter-spacing:1px}.valor{font-size:44px;font-weight:800;margin-top:10px;line-height:1.15}
</style></head><body><div class="faixa"></div>${corpo}</body></html>`

function paginas(c, fotoB64) {
  const foto = `data:image/jpeg;base64,${fotoB64}`
  const qs = c.quantidades.map((q) => q.toLocaleString('pt-BR')).join(' · ')
  const passos = [['1', 'Faça seu pedido', 'Escolha a quantidade e finalize a compra com segurança.'], ['2', 'Envie sua arte ou logo', 'Depois da compra, mande o arquivo (PDF, CDR, AI, PNG em alta ou Canva) pelo chat do pedido.'],
    ['3', 'Conferência técnica', 'Nossa equipe revisa medidas, sangria e resolução para a impressão sair nítida.'], ['4', 'Produção e envio', `Produção em ${c.prazo_dias} dias úteis, com embalagem reforçada.`]]
  const grade = (itens, cols, top = 250) => `<div style="position:absolute;left:70px;right:70px;top:${top}px;bottom:70px;display:grid;grid-template-columns:repeat(${cols},1fr);grid-auto-rows:1fr;gap:26px">${itens}</div>`
  const [lw, lh] = c.tamanho_mm || [41.5, 44]
  const esc = Math.min(430 / lw, 400 / lh) // pixels por mm no esquema (cabe no quadro)
  const cw = c.cota_w || c.tamanho_final.split(' x ')[0] + ' cm'
  const ch = c.cota_h || c.tamanho_final.split(' x ')[1]
  const W = lw * esc, H = lh * esc
  const esquema = `<svg width="640" height="640" viewBox="0 0 640 640" xmlns="http://www.w3.org/2000/svg">
    <rect x="${(640 - W) / 2 + 30}" y="${(640 - H) / 2 - 20}" width="${W}" height="${H}" rx="10" fill="${c.furo ? '#C69C6D' : '#E9EEF2'}" stroke="${c.furo ? '#8a6a43' : '#9aa6b2'}" stroke-width="3"/>
    ${c.furo ? `<circle cx="${(640 - W) / 2 + 30 + W / 2}" cy="${(640 - H) / 2 - 20 + 46}" r="17" fill="#fff" stroke="#8a6a43" stroke-width="3"/>` : ''}
    <g stroke="${CORES.magenta}" stroke-width="4" fill="${CORES.magenta}" font-family="Inter,Arial" font-weight="800" font-size="30">
      <line x1="${(640 - W) / 2 + 30}" y1="${(640 - H) / 2 - 20 + H + 40}" x2="${(640 - W) / 2 + 30 + W}" y2="${(640 - H) / 2 - 20 + H + 40}"/>
      <line x1="${(640 - W) / 2 + 30}" y1="${(640 - H) / 2 - 20 + H + 26}" x2="${(640 - W) / 2 + 30}" y2="${(640 - H) / 2 - 20 + H + 54}"/><line x1="${(640 - W) / 2 + 30 + W}" y1="${(640 - H) / 2 - 20 + H + 26}" x2="${(640 - W) / 2 + 30 + W}" y2="${(640 - H) / 2 - 20 + H + 54}"/>
      <text x="${(640 - W) / 2 + 30 + W / 2}" y="${(640 - H) / 2 - 20 + H + 90}" text-anchor="middle" stroke="none">${cw}</text>
      <line x1="${(640 - W) / 2 - 10}" y1="${(640 - H) / 2 - 20}" x2="${(640 - W) / 2 - 10}" y2="${(640 - H) / 2 - 20 + H}"/>
      <line x1="${(640 - W) / 2 - 24}" y1="${(640 - H) / 2 - 20}" x2="${(640 - W) / 2 + 4}" y2="${(640 - H) / 2 - 20}"/><line x1="${(640 - W) / 2 - 24}" y1="${(640 - H) / 2 - 20 + H}" x2="${(640 - W) / 2 + 4}" y2="${(640 - H) / 2 - 20 + H}"/>
      <text transform="translate(${(640 - W) / 2 - 30},${(640 - H) / 2 - 20 + H / 2}) rotate(-90)" text-anchor="middle" stroke="none">${ch}</text></g></svg>`
  const card = (r, v, extra = '') => `<div class="card" style="display:flex;flex-direction:column;justify-content:center;${extra}"><div class="rotulo">${r}</div><div class="valor">${v}</div></div>`
  return {
    '01_capa': `<img src="${foto}" style="position:absolute;left:90px;top:90px;width:1020px;height:1020px;object-fit:contain;mix-blend-mode:multiply">`,
    '02_medidas': `<div class="pad"><h1>Tamanho final</h1><div class="sub">Medida final depois do corte (esquema em escala)</div></div>
      <div style="position:absolute;left:40px;top:250px">${esquema}</div>
      <div style="position:absolute;left:700px;top:270px;width:430px;display:flex;flex-direction:column;gap:26px">
        ${card('Tamanho final', c.tamanho_final.replace(' x ', ' × '), 'min-height:190px')}
        ${card('Arte com sangria', c.arte.replace(' x ', ' × '), 'min-height:190px')}
        <img src="${foto}" style="width:430px;height:300px;object-fit:contain;mix-blend-mode:multiply"></div>
      <div style="position:absolute;left:70px;right:70px;bottom:60px;font-size:32px;color:#333;font-weight:600">Monte a arte no tamanho com sangria: assim o corte não come o seu desenho.</div>`,
    '03_especificacoes': `<div class="pad"><h1>Ficha técnica</h1><div class="sub">${c.nome}</div></div>` + grade(
      `<div class="card" style="background:${CORES.ciano};color:#fff;display:flex;flex-direction:column;justify-content:center"><div class="rotulo" style="color:#e8f8ff">Quantidades disponíveis</div><div class="valor" style="font-size:50px">${qs}</div></div>` +
      card('Material', c.material) + card('Impressão', c.impressao) + card('Acabamento e corte', c.acabamento, 'font-size:38px'), 2),
    '04_como_funciona': `<div class="pad"><h1>Como funciona a personalização</h1><div class="sub">Do pedido à entrega, sem complicação</div></div>` + grade(
      passos.map((q) => `<div class="card" style="display:flex;flex-direction:column;justify-content:center"><div style="width:84px;height:84px;border-radius:50%;background:${CORES.magenta};color:#fff;font-size:48px;font-weight:800;display:flex;align-items:center;justify-content:center">${q[0]}</div><div class="valor" style="font-size:40px">${q[1]}</div><div style="font-size:30px;color:#333;margin-top:14px;line-height:1.3">${q[2]}</div></div>`).join(''), 2),
    '05_beneficios_nichos': `<div class="pad"><h1>Qualidade de gráfica profissional</h1><div class="sub">Impressão e acabamento que valorizam a sua marca</div></div>` + grade(
      ['Cores vibrantes em alta definição', c.corte || 'Corte de precisão', 'Embalagem reforçada'].map((t, i) => `<div class="card" style="display:flex;align-items:center;font-size:40px;font-weight:800;border-left:14px solid ${[CORES.ciano, CORES.magenta, CORES.amarelo][i]}">${t}</div>`).join('') +
      `<div class="card" style="background:#fff8d6"><div class="rotulo">Ideal para</div><div style="display:flex;flex-wrap:wrap;gap:12px;margin-top:16px">${c.aplicacoes.map((t) => `<span style="background:${CORES.amarelo};padding:12px 22px;border-radius:40px;font-size:28px;font-weight:700">${t}</span>`).join('')}</div></div>`, 1),
  }
}

async function gerarImagens(browser, c, out) {
  const fotoB64 = fs.readFileSync(c.foto).toString('base64')
  fs.mkdirSync(out, { recursive: true })
  const page = await browser.newPage({ viewport: { width: 1200, height: 1200 }, deviceScaleFactor: 1 })
  for (const [nome, corpo] of Object.entries(paginas(c, fotoB64))) {
    const texto = corpo.replace(/<img[^>]*>/g, '')
    if (PROIBIDO.test(texto.replace(/<[^>]+>/g, ' '))) throw new Error(`Imagem ${nome} contém texto proibido (contato, URL ou SKU).`)
    await page.setContent(nome === '01_capa' ? base(corpo).replace('<div class="faixa"></div>', '') : base(corpo))
    await page.screenshot({ path: path.join(out, `${nome}.jpg`), type: 'jpeg', quality: 86 })
  }
  await page.close()
}
module.exports = { gerarImagens }

async function main() {
  const [cfgPath, out] = process.argv.slice(2)
  const c = JSON.parse(fs.readFileSync(cfgPath, 'utf8'))
  const fotoB64 = fs.readFileSync(c.foto).toString('base64')
  fs.mkdirSync(out, { recursive: true })
  const paginasHtml = paginas(c, fotoB64)
  const browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1200, height: 1200 }, deviceScaleFactor: 1 })
  for (const [nome, corpo] of Object.entries(paginasHtml)) {
    const texto = corpo.replace(/<img[^>]*>/g, '')
    if (PROIBIDO.test(texto.replace(/<[^>]+>/g, ' '))) throw new Error(`Imagem ${nome} contém texto proibido (contato, URL ou SKU).`)
    await page.setContent(nome === '01_capa' ? base(corpo).replace('<div class="faixa"></div>', '') : base(corpo))
    await page.screenshot({ path: path.join(out, `${nome}.jpg`), type: 'jpeg', quality: 88 })
  }
  await browser.close()
  console.log(`5 imagens em ${out}`)
}
if (require.main === module) main().catch((e) => { console.error(e.message); process.exit(1) })
