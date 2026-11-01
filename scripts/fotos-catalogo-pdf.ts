// Reserva: extrai as imagens do catálogo em PDF do dono e sugere o grupo de cada página. Rede NÃO é usada na extração.
// Requer poppler-utils (pdftotext, pdfimages). O PDF fica FORA do repositório.
//   1) extrair:  node scripts/fotos-catalogo-pdf.ts extrair  catalogo.pdf grupos.json saida/
//   2) enviar:   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/fotos-catalogo-pdf.ts enviar saida/
// grupos.json = lista dos grupos do catálogo (["TAGS","CARDÁPIOS",...]). As imagens enviadas entram como PENDENTES e marcadas para revisão:
// o dono aprova em Catálogo > Fotos antes de qualquer envio ao cliente.
import { execFileSync } from 'node:child_process'
import { mkdirSync, readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { Image } from 'imagescript'
import { nomeArquivoNeutro, normalizar, processarImagem, sha256Hex } from '../supabase/functions/_shared/fotos.ts'

const [modo, a, b, c] = process.argv.slice(2)
const lib = { decode: (d: Uint8Array) => Image.decode(d) }
const sh = (cmd: string, args: string[]) => execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 1 << 28 })

/** Sugere o grupo pela maior sobreposição de palavras entre o texto da página e o nome do grupo (palavras de 4+ letras). */
export function sugerirGrupo(texto: string, grupos: string[]): { grupo: string | null; pontos: number } {
  const alvo = ` ${normalizar(texto)} `
  let melhor: { grupo: string | null; pontos: number } = { grupo: null, pontos: 0 }
  for (const g of grupos) {
    const palavras = normalizar(g).split(' ').filter((p) => p.length >= 4)
    if (!palavras.length) continue
    const pontos = palavras.filter((p) => alvo.includes(` ${p}`) || alvo.includes(` ${p.replace(/s$/, '')}`)).length / palavras.length
    if (pontos > melhor.pontos || (pontos === melhor.pontos && pontos > 0 && g.length > (melhor.grupo?.length ?? 0))) melhor = { grupo: g, pontos }
  }
  return melhor
}

if (modo === 'extrair') {
  const [pdf, gruposJson, saida] = [a, b, c]
  if (!pdf || !gruposJson || !saida) throw new Error('Uso: extrair catalogo.pdf grupos.json saida/')
  const grupos: string[] = JSON.parse(readFileSync(gruposJson, 'utf8'))
  mkdirSync(saida, { recursive: true })
  const paginas = Number(/Pages:\s+(\d+)/.exec(sh('pdfinfo', [pdf]))?.[1] ?? 0)
  const manifesto: { pagina: number; titulo: string; grupo: string | null; confianca: number; arquivos: string[] }[] = []
  const vistos = new Set<string>()
  for (let p = 1; p <= paginas; p++) {
    const texto = sh('pdftotext', ['-f', String(p), '-l', String(p), '-layout', pdf, '-'])
    const linhas = texto.split('\n').map((l) => l.trim()).filter(Boolean)
    const sug = sugerirGrupo(linhas.slice(0, 6).join(' '), grupos)
    const tmp = join(saida, `_p${p}`); mkdirSync(tmp, { recursive: true })
    sh('pdfimages', ['-png', '-f', String(p), '-l', String(p), pdf, join(tmp, 'i')])
    const arquivos: string[] = []
    for (const f of readdirSync(tmp)) {
      const p2 = await processarImagem(new Uint8Array(readFileSync(join(tmp, f))), lib)
      if ('descartada' in p2 || Math.min(p2.largura, p2.altura) < 300) continue   // elementos gráficos pequenos do catálogo não servem
      const hash = await sha256Hex(p2.bytes)
      if (vistos.has(hash)) continue
      vistos.add(hash)
      const rel = nomeArquivoNeutro(hash)
      mkdirSync(join(saida, rel.split('/')[0]), { recursive: true })
      writeFileSync(join(saida, rel), p2.bytes)
      arquivos.push(rel)
    }
    if (arquivos.length) manifesto.push({ pagina: p, titulo: linhas.slice(0, 3).join(' | '), grupo: sug.grupo, confianca: Number(sug.pontos.toFixed(2)), arquivos })
  }
  writeFileSync(join(saida, 'manifesto.json'), JSON.stringify(manifesto, null, 1))
  const sem = manifesto.filter((m) => !m.grupo).length
  console.log(`${manifesto.length} páginas com imagens aproveitáveis, ${manifesto.reduce((n, m) => n + m.arquivos.length, 0)} imagens; ${sem} páginas sem grupo sugerido (revise manifesto.json)`)
} else if (modo === 'enviar') {
  const dir = a
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!dir || !url || !key || !existsSync(join(dir, 'manifesto.json'))) throw new Error('Uso: SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... enviar saida/')
  const manifesto: { grupo: string | null; arquivos: string[] }[] = JSON.parse(readFileSync(join(dir, 'manifesto.json'), 'utf8'))
  const h = { apikey: key, Authorization: `Bearer ${key}` }
  let n = 0
  for (const m of manifesto) {
    if (!m.grupo) continue
    for (const rel of m.arquivos) {
      const bytes = readFileSync(join(dir, rel))
      const up = await fetch(`${url}/storage/v1/object/produto-fotos/${rel}`, { method: 'POST', headers: { ...h, 'Content-Type': 'image/jpeg', 'x-upsert': 'true' }, body: bytes })
      if (!up.ok) { console.error('falha ao subir', rel, up.status); continue }
      const hash = rel.split('/')[1].replace('.jpg', '')
      const r = await fetch(`${url}/rest/v1/rpc/foto_registrar`, { method: 'POST', headers: { ...h, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_grupo: m.grupo, p_url_origem: null, p_arquivo: rel, p_largura: null, p_altura: null, p_bytes: bytes.length, p_hash: hash, p_aproximada: true, p_ordem: 50, p_baixa_qualidade: false, p_fonte: 'catalogo_pdf', p_sku: null }) })
      if (r.ok) n++
    }
  }
  console.log(`${n} imagens enviadas como pendentes (aprove em Catálogo > Fotos)`)
} else {
  console.error('Modo: extrair | enviar')
  process.exit(1)
}
