// Gera os dois banners do checkout (identidade da Sua Gráfica BH): Pix, cartão em até 2x sem juros e entrega grátis na região central.
//   ecommerce/public/banners/checkout-desktop.jpg  (1920x420)   ecommerce/public/banners/checkout-celular.jpg  (1080x620)
// Uso: node scripts/gerar-banner-checkout.cjs   (Playwright; não precisa de internet)
const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')
const simbolo = fs.readFileSync(path.join(__dirname, '../ecommerce/public/marca/simbolo.svg'), 'utf8').replace(/id="01colo/g, 'id="b1colo').replace(/#01colo/g, '#b1colo')

const css = (w, h, m) => `
*{box-sizing:border-box;margin:0}
body{width:${w}px;height:${h}px;overflow:hidden;font-family:Inter,Arial,sans-serif;color:#fff;position:relative;
 background:radial-gradient(ellipse at ${m ? '85% 12%' : '82% 50%'}, #9b0057 0%, #4a0230 38%, #0b0b0f 78%)}
.pontos{position:absolute;inset:0;background-image:radial-gradient(rgba(255,255,255,.07) 1.5px,transparent 1.6px);background-size:34px 34px}
.marca{position:absolute;display:flex;align-items:center;gap:${m ? 16 : 14}px;font-weight:900;letter-spacing:-.5px}
.marca svg{width:${m ? 74 : 58}px;height:auto}.marca b{font-size:${m ? 34 : 28}px;line-height:.95}.marca em{font-style:normal;color:#FFD500}
h1{position:absolute;font-weight:900;letter-spacing:-2px;line-height:1.02}
h1 span{color:#FFD500}
.chips{position:absolute;display:flex;gap:14px;flex-wrap:wrap}
.chip{display:flex;align-items:center;gap:10px;background:rgba(255,255,255,.12);border:1.5px solid rgba(255,255,255,.22);border-radius:999px;font-weight:700;padding:${m ? '14px 24px' : '11px 22px'};font-size:${m ? 27 : 23}px;backdrop-filter:blur(2px)}
.ic{width:${m ? 30 : 26}px;height:${m ? 30 : 26}px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:${m ? 18 : 15}px;font-weight:900;color:#0b0b0f}
.c{position:absolute;border-radius:50%;mix-blend-mode:screen}
.cartao{position:absolute;border-radius:26px;background:linear-gradient(135deg,#00A6D6,#1F2A86 60%,#E6007E);box-shadow:0 26px 60px rgba(0,0,0,.55);padding:26px;display:flex;flex-direction:column;justify-content:space-between;color:#fff}
.cartao .chip2{width:64px;height:48px;border-radius:10px;background:linear-gradient(135deg,#FFD500,#e6bf00)}
.cartao .num{font-size:30px;letter-spacing:5px;font-weight:700;opacity:.92}
.selo{position:absolute;background:#FFD500;color:#0b0b0f;font-weight:900;border-radius:22px;box-shadow:0 16px 40px rgba(0,0,0,.45);text-align:center;line-height:1}
.pix{position:absolute;background:#32BCAD;color:#04221f;font-weight:900;border-radius:20px;box-shadow:0 16px 40px rgba(0,0,0,.4);padding:14px 26px;font-size:38px;letter-spacing:1px}
`
const desktop = `<html><style>${css(1920, 420, false)}</style><body><div class="pontos"></div>
<div class="c" style="width:420px;height:420px;right:-60px;top:-120px;background:#00A6D6;opacity:.55"></div>
<div class="c" style="width:340px;height:340px;right:330px;top:180px;background:#FFD500;opacity:.35"></div>
<div class="marca" style="left:80px;top:34px">${simbolo}<b>SUA<br>GRÁFICA <em>BH</em></b></div>
<h1 style="left:80px;top:128px;font-size:76px">Pague no Pix ou em até<br><span>2x sem juros</span> no cartão</h1>
<div class="chips" style="left:80px;top:318px"><div class="chip"><span class="ic" style="background:#32BCAD">✓</span>Pix aprova na hora</div><div class="chip"><span class="ic" style="background:#FFD500">★</span>Entrega grátis na região central de BH</div></div>
<div class="cartao" style="right:230px;top:70px;width:430px;height:270px;transform:rotate(-7deg)"><div class="chip2"></div><div class="num">•••• •••• •••• 2026</div><div style="font-weight:800;font-size:22px;letter-spacing:1px">SUA GRÁFICA BH</div></div>
<div class="selo" style="right:150px;top:48px;padding:20px 28px;font-size:58px;transform:rotate(6deg)">2x<div style="font-size:21px;margin-top:6px">SEM JUROS</div></div>
<div class="pix" style="right:90px;top:278px;transform:rotate(-4deg)">PIX</div>
</body></html>`

const celular = `<html><style>${css(1080, 620, true)}</style><body><div class="pontos"></div>
<div class="c" style="width:560px;height:560px;right:-190px;top:-200px;background:#00A6D6;opacity:.5"></div>
<div class="c" style="width:360px;height:360px;left:-120px;bottom:-140px;background:#FFD500;opacity:.3"></div>
<div class="marca" style="left:54px;top:42px">${simbolo}<b>SUA<br>GRÁFICA <em>BH</em></b></div>
<div class="selo" style="right:54px;top:34px;padding:18px 26px;font-size:62px;transform:rotate(5deg)">2x<div style="font-size:20px;margin-top:5px">SEM JUROS</div></div>
<h1 style="left:54px;top:160px;font-size:84px;width:960px">Pague no Pix ou em até<br><span>2x sem juros</span></h1>
<div class="chips" style="left:54px;top:410px;width:980px"><div class="chip"><span class="ic" style="background:#32BCAD">✓</span>Pix aprova na hora</div><div class="chip"><span class="ic" style="background:#FFD500">★</span>Entrega grátis na região central de BH</div></div>
<div style="position:absolute;left:54px;bottom:38px;font-size:24px;color:#ffffffb3;font-weight:600">Cartão de crédito em até 2x sem juros · Pix com aprovação na hora</div>
</body></html>`

;(async () => {
  const b = await chromium.launch()
  for (const [html, w, h, nome] of [[desktop, 1920, 420, 'checkout-desktop'], [celular, 1080, 620, 'checkout-celular']]) {
    const p = await b.newPage({ viewport: { width: w, height: h } })
    await p.setContent(html, { waitUntil: 'load' })
    await p.screenshot({ path: path.join(__dirname, `../ecommerce/public/banners/${nome}.jpg`), type: 'jpeg', quality: 90 })
    await p.close()
  }
  await b.close()
  console.log('banners do checkout gerados')
})()
