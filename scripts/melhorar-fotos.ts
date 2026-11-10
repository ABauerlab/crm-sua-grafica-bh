// Auditoria e melhoria das fotos da loja (bucket público `loja-produtos`). Manual, NÃO faz parte do npm test.
// Varre todas as imagens, mede a resolução e, nas pequenas, guarda o original em `originais/` e reenvia a versão melhorada
// NO MESMO caminho (as URLs da loja não mudam). Sem foto nenhuma não há o que melhorar: a vitrine já tem foto em 100% dos produtos.
//
// Preparo: npm i --no-save sharp
// Uso (PowerShell):
//   $env:SUPABASE_URL="https://xxxx.supabase.co"; $env:SUPABASE_SERVICE_ROLE_KEY="..."
//   node --experimental-strip-types scripts/melhorar-fotos.ts --dry-run            (só mede e gera fotos-relatorio.csv)
//   node --experimental-strip-types scripts/melhorar-fotos.ts --minimo 800         (melhora quem tem lado maior < 800 px)
// Honestidade técnica: ampliar com Lanczos + nitidez suaviza e deixa a foto mais limpa, mas NÃO inventa detalhe.
// Para foto realmente nova e nítida, o caminho é baixar a imagem original maior da origem (script de extração) ou usar um ampliador por IA.
import { writeFileSync } from 'node:fs'

const SB = (process.env.SUPABASE_URL ?? '').replace(/\/+$/, '')
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
const BUCKET = 'loja-produtos'
const args = process.argv.slice(2)
const dry = args.includes('--dry-run')
const minimo = Number(args[args.indexOf('--minimo') + 1]) || 800
const limite = Number(args[args.indexOf('--limite') + 1]) || Infinity
if (!SB || !KEY) { console.error('Informe SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY.'); process.exit(1) }
const sharp = (await import('sharp').catch(() => { console.error('Rode: npm i --no-save sharp'); process.exit(1) })).default
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` }

async function listar(prefixo: string): Promise<string[]> {
  const out: string[] = []
  for (let off = 0; ; off += 1000) {
    const r = await fetch(`${SB}/storage/v1/object/list/${BUCKET}`, { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefix: prefixo, limit: 1000, offset: off }) })
    if (!r.ok) throw new Error(`listar ${prefixo}: ${r.status}`)
    const itens = (await r.json()) as { name: string; id: string | null }[]
    out.push(...itens.filter((i) => i.id).map((i) => `${prefixo}/${i.name}`))
    if (itens.length < 1000) return out
  }
}

async function melhorar(buf: Buffer): Promise<Buffer> {
  const m = await sharp(buf).metadata()
  const lado = Math.max(m.width ?? 1, m.height ?? 1)
  const alvo = Math.min(1600, Math.max(1000, lado * 2))
  for (const q of [90, 82, 72, 62]) {
    const out = await sharp(buf).rotate().flatten({ background: '#ffffff' })
      .resize({ width: alvo, height: alvo, fit: 'inside', kernel: 'lanczos3' })
      .median(1).sharpen({ sigma: 1.1, m1: 0.8, m2: 2.2 }).jpeg({ quality: q, mozjpeg: true }).toBuffer()
    if (out.length <= 300 * 1024) return out
  }
  return sharp(buf).resize({ width: 1000, height: 1000, fit: 'inside' }).sharpen().jpeg({ quality: 60 }).toBuffer()
}

const linhas = ['arquivo,largura,altura,bytes,acao']
let medidas = 0, pequenas = 0, melhoradas = 0
const prefixos = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, '0'))
for (const p of prefixos) {
  for (const arq of await listar(p)) {
    if (medidas >= limite) break
    medidas++
    try {
      const r = await fetch(`${SB}/storage/v1/object/public/${BUCKET}/${arq}`)
      const buf = Buffer.from(await r.arrayBuffer())
      const m = await sharp(buf).metadata()
      const lado = Math.max(m.width ?? 0, m.height ?? 0)
      let acao = 'ok'
      if (lado < minimo) {
        pequenas++
        acao = dry ? 'pequena' : 'melhorada'
        if (!dry) {
          const up = (caminho: string, corpo: Buffer, tipo: string) => fetch(`${SB}/storage/v1/object/${BUCKET}/${caminho}`, { method: 'POST', headers: { ...H, 'Content-Type': tipo, 'x-upsert': 'true' }, body: corpo })
          const bk = await up(`originais/${arq}`, buf, r.headers.get('content-type') ?? 'image/jpeg')
          if (!bk.ok) throw new Error(`backup ${bk.status}`)
          const novo = await melhorar(buf)
          const ok = await up(arq, novo, 'image/jpeg')
          if (!ok.ok) throw new Error(`upload ${ok.status}`)
          melhoradas++
        }
      }
      linhas.push(`${arq},${m.width},${m.height},${buf.length},${acao}`)
    } catch (e) {
      linhas.push(`${arq},,,,erro: ${(e as Error).message}`)
    }
  }
  if (medidas % 200 === 0) console.log(`${medidas} medidas, ${pequenas} pequenas`)
}
writeFileSync('fotos-relatorio.csv', linhas.join('\n'))
console.log(`Fim. ${medidas} imagens, ${pequenas} abaixo de ${minimo}px, ${melhoradas} melhoradas. Relatório: fotos-relatorio.csv${dry ? ' (dry-run: nada alterado)' : ''}`)
