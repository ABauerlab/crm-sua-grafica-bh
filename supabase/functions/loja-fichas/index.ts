// E-commerce Fase 2: lê a ficha técnica pública de cada produto na origem interna, traduz para linguagem de balcão,
// guarda a foto (JPEG leve, nome neutro, bucket público loja-produtos) e aplica na vitrine (loja_ficha_gravar).
// Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role. Uma página a cada 2 s; nada de log com conteúdo ou origem.
import { Image } from 'https://deno.land/x/imagescript@1.3.0/mod.ts'
import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { fichaBalcao, lerFicha, marcasDaOrigem } from '../_shared/ficha-origem.ts'
import { nomeArquivoNeutro, processarImagem, sha256Hex } from '../_shared/fotos.ts'
import { conferirMarca } from '../_shared/marca.ts'

const UA = 'Mozilla/5.0 (compatible; SuaGraficaBH-catalogo/1.0)'
const decode = { decode: (d: Uint8Array) => Image.decode(d) }
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function baixar(url: string, binario: boolean): Promise<Response> {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), 20000)
  try {
    return await fetch(url, { headers: { 'User-Agent': UA, Accept: binario ? 'image/*' : 'text/html' }, signal: ctl.signal, redirect: 'follow' })
  } finally {
    clearTimeout(t)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const fromCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!fromCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const [{ data: fotosCfg }, { data: cfgRow }] = await Promise.all([
    db.from('app_settings').select('value').eq('key', 'fotos').maybeSingle(),
    db.from('app_settings').select('value').eq('key', 'loja_fichas').maybeSingle(),
  ])
  const base = String((fotosCfg?.value as { origem_base?: string } | null)?.origem_base ?? '')
  const cfg = (cfgRow?.value ?? {}) as { ligado?: boolean; por_execucao?: number; intervalo_ms?: number; verificar_marca?: boolean }
  if (!base) return json({ error: 'Origem do catálogo não configurada.' }, 400)
  if (cfg.ligado === false) return json({ ok: true, desligado: true })
  const host = new URL(base).hostname
  const raiz = `https://${host.startsWith('www.') ? host : `www.${host}`}`
  const marcas = marcasDaOrigem(base)
  const intervalo = Math.max(1500, cfg.intervalo_ms ?? 2000)
  const gemini = cfg.verificar_marca === false ? undefined : Deno.env.get('GEMINI_API_KEY')

  const { data: lote, error } = await db.rpc('loja_fichas_pegar', { p_n: Math.min(cfg.por_execucao ?? 20, 30) })
  if (error) return json({ error: 'Não foi possível pegar o lote.' }, 500)
  const itens = (lote ?? []) as { chave: string; caminho: string; imagem_origem: string | null }[]
  const inicio = Date.now()
  let ok = 0, falhas = 0
  for (const [i, it] of itens.entries()) {
    if (Date.now() - inicio > 110_000) {
      // perto do limite de tempo: devolve o resto para a fila
      await db.from('loja_fichas').update({ status: 'pendente' }).in('chave', itens.slice(i).map((x) => x.chave))
      break
    }
    if (i > 0) await espera(intervalo)
    try {
      const res = await baixar(raiz + it.caminho, false)
      if (!res.ok) throw new Error(`página ${res.status}`)
      const ficha = lerFicha(await res.text(), marcas)
      if (!ficha.material && !ficha.titulo) throw new Error('ficha não encontrada na página')
      const balcao = fichaBalcao(ficha, marcas)
      const { sobre: _sobre, ref: _ref, ...fichaSemTexto } = ficha
      let foto: string | null = null
      let marcaOk: boolean | null = null
      if (it.imagem_origem) {
        const img = await baixar(it.imagem_origem, true)
        if (img.ok) {
          const p = await processarImagem(new Uint8Array(await img.arrayBuffer()), decode)
          if ('bytes' in p) {
            const v = await conferirMarca(p.bytes, gemini)
            marcaOk = v.limpa
            if (v.limpa !== false) {
              const nome = nomeArquivoNeutro(await sha256Hex(p.bytes))
              const up = await db.storage.from('loja-produtos').upload(nome, p.bytes, { contentType: 'image/jpeg', upsert: true, cacheControl: '31536000' })
              if (!up.error) foto = nome
            }
          }
        }
      }
      await db.rpc('loja_ficha_gravar', { p_chave: it.chave, p_ficha: fichaSemTexto, p_balcao: balcao, p_foto: foto, p_marca_ok: marcaOk, p_erro: null })
      ok++
    } catch (e) {
      falhas++
      await db.rpc('loja_ficha_gravar', { p_chave: it.chave, p_ficha: null, p_balcao: null, p_foto: null, p_marca_ok: null, p_erro: e instanceof Error ? e.message : 'erro' })
    }
  }
  console.log(`loja-fichas: ${ok} ok, ${falhas} com erro, ${itens.length} no lote`)
  return json({ ok: true, processados: ok, erros: falhas, lote: itens.length })
})
