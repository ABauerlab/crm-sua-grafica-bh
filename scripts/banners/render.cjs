const { chromium } = require('playwright')
const fs = require('fs'), path = require('path')
;(async () => {
  const b = await chromium.launch()
  fs.mkdirSync('../../ecommerce/public/banners', { recursive: true })
  for (const f of fs.readdirSync('html')) {
    const m = f.match(/^(.*)-(desk|mob)\.html$/)
    const [w, h] = m[2] === 'desk' ? [1920, 640] : [1000, 800]
    const ctx = await b.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 1 })
    const p = await ctx.newPage()
    await p.goto('file://' + path.resolve('html', f))
    await p.waitForLoadState('networkidle')
    await p.waitForTimeout(300)
    await p.screenshot({ path: `../../ecommerce/public/banners/${m[1]}-${m[2] === 'desk' ? 'desktop' : 'celular'}.jpg`, type: 'jpeg', quality: 88 })
    await ctx.close()
  }
  await b.close()
})()
