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
  return {
    '01_capa': `<img src="${foto}" style="position:absolute;left:90px;top:90px;width:1020px;height:1020px;object-fit:contain;mix-blend-mode:multiply">`.replace('<div class="faixa"></div>', ''),
    '02_medidas': `<div class="pad"><h1>Tamanho real</h1><div class="sub">Medida final depois do corte</div></div>
      <img src="${foto}" style="position:absolute;left:120px;top:250px;width:620px;height:620px;object-fit:contain;mix-blend-mode:multiply">
      <div style="position:absolute;left:775px;top:300px;width:355px" class="card"><div class="rotulo">Tamanho final</div><div class="valor">${c.tamanho_final}</div></div>
      <div style="position:absolute;left:775px;top:520px;width:355px" class="card"><div class="rotulo">Arte com sangria</div><div class="valor" style="font-size:34px">${c.arte}</div></div>
      <div style="position:absolute;left:70px;bottom:70px;right:70px;font-size:30px;color:#444">Monte a arte no tamanho com sangria para o corte não cortar o seu desenho.</div>`,
    '03_especificacoes': `<div class="pad"><h1>Ficha técnica</h1><div class="sub">${c.nome}</div></div>
      <div style="position:absolute;left:70px;top:290px;width:1060px;display:grid;grid-template-columns:1fr 1fr;gap:28px">
      <div class="card" style="background:${CORES.ciano};color:#fff"><div class="rotulo" style="color:#e8f8ff">Quantidades</div><div class="valor">${qs}</div></div>
      <div class="card"><div class="rotulo">Material</div><div class="valor">${c.material}</div></div>
      <div class="card"><div class="rotulo">Impressão</div><div class="valor">${c.impressao}</div></div>
      <div class="card"><div class="rotulo">Acabamento e corte</div><div class="valor" style="font-size:36px">${c.acabamento}</div></div></div>`,
    '04_como_funciona': `<div class="pad"><h1>Como funciona a personalização</h1></div><div style="position:absolute;left:70px;top:260px;width:1060px;display:grid;grid-template-columns:1fr 1fr;gap:28px">` +
      passos.map((p) => `<div class="card" style="min-height:360px"><div style="width:72px;height:72px;border-radius:50%;background:${CORES.magenta};color:#fff;font-size:40px;font-weight:800;display:flex;align-items:center;justify-content:center">${p[0]}</div><div class="valor" style="font-size:36px">${p[1]}</div><div style="font-size:27px;color:#444;margin-top:12px;line-height:1.3">${p[2]}</div></div>`).join('') + '</div>',
    '05_beneficios_nichos': `<div class="pad"><h1>Qualidade de gráfica profissional</h1></div><div style="position:absolute;left:70px;top:260px;width:1060px">
      <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:20px">${['Cores vibrantes em alta definição', 'Corte de precisão', 'Embalagem reforçada'].map((t) => `<div class="card" style="font-size:30px;font-weight:700;min-height:190px">${t}</div>`).join('')}</div>
      <div class="rotulo" style="margin:50px 0 20px">Ideal para</div><div style="display:flex;flex-wrap:wrap;gap:16px">${c.aplicacoes.map((t) => `<span style="background:${CORES.amarelo};padding:16px 28px;border-radius:40px;font-size:30px;font-weight:700">${t}</span>`).join('')}</div></div>`,
  }
}

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
main().catch((e) => { console.error(e.message); process.exit(1) })
