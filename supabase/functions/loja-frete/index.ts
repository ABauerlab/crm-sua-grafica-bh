// E-commerce Fase 9: frete do site. Público (limite no banco e na loja). Resolve o CEP (bairro e cidade, em cache),
// diz se a entrega é grátis (só nos bairros ativos de zonas_frete_gratis) e cota o envio para o Brasil no SuperFrete.
// Sem SUPERFRETE_TOKEN o envio nacional fica "a confirmar pelo WhatsApp": nunca inventa valor. Logs sem dados pessoais.
import { corsHeaders, json, serviceClient } from '../_shared/http.ts'
import { cepLimpo, corpoSuperFrete, juntarPacotes, lerEnderecoCep, opcoesEnvio, pacoteValido, type Pacote } from '../_shared/loja-frete.ts'

const ORIGEM = Deno.env.get('SUPERFRETE_CEP_ORIGEM') ?? '30160040' // balcão da Praça Sete (endereço público)

async function buscarCep(db: ReturnType<typeof serviceClient>, cep: string) {
  const { data: c } = await db.from('cep_bairros').select('cep, logradouro, bairro, cidade, uf').eq('cep', cep).maybeSingle()
  if (c) return c
  for (const url of [`https://viacep.com.br/ws/${cep}/json/`, `https://brasilapi.com.br/api/cep/v1/${cep}`]) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(4000) })
      if (!r.ok) continue
      const e = lerEnderecoCep(cep, await r.json().catch(() => null))
      if (!e) continue
      await db.from('cep_bairros').upsert({ ...e, fonte: url.includes('viacep') ? 'viacep' : 'brasilapi', atualizado_em: new Date().toISOString() })
      return e
    } catch { /* tenta a próxima fonte */ }
  }
  return null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const body = await req.json().catch(() => null) as { cep?: string; itens?: { ref: string; quantidade: number }[]; arte?: string } | null
  const cep = cepLimpo(body?.cep)
  if (!cep) return json({ error: 'CEP inválido.' }, 400)
  const itens = Array.isArray(body?.itens) ? body!.itens!.slice(0, 10).map((i) => ({ ref: String(i?.ref ?? ''), quantidade: Math.trunc(Number(i?.quantidade ?? 1)) })) : []
  if (!itens.length) return json({ error: 'Carrinho vazio.' }, 400)

  const db = serviceClient()
  const endereco = await buscarCep(db, cep)
  if (!endereco) return json({ error: 'Não encontramos esse CEP. Confira os números.' }, 404)

  const { data: base, error } = await db.rpc('loja_frete_base', { p_itens: itens, p_arte: body?.arte ?? 'pronta', p_cep: cep })
  if (error) { console.error('loja-frete: base falhou', error.code); return json({ error: 'Não foi possível calcular o frete agora.' }, 500) }
  const b = base as { ok: boolean; erro?: string; frete?: Record<string, unknown>; pacotes?: Pacote[] | null }
  if (!b.ok) return json({ error: 'Um dos produtos do carrinho não está mais disponível.' }, 409)

  const frete = b.frete ?? {}
  const grandeBh = frete.grande_bh === true
  const resposta: Record<string, unknown> = {
    ok: true,
    endereco: { cep, logradouro: endereco.logradouro, bairro: endereco.bairro, cidade: endereco.cidade, uf: endereco.uf },
    frete_gratis: frete.frete_gratis === true,
    regiao_central: frete.regiao_central === true,
    falta_para_frete_gratis: frete.falta_para_frete_gratis ?? null,
    pedido_minimo_frete_gratis: frete.pedido_minimo_frete_gratis ?? null,
    grande_bh: grandeBh,
    envio: { disponivel: false, motivo: null as string | null, opcoes: [] as unknown[] },
  }

  // Fora da Grande BH: envio nacional pelo SuperFrete
  if (!grandeBh) {
    const token = Deno.env.get('SUPERFRETE_TOKEN')
    const envio = resposta.envio as { disponivel: boolean; motivo: string | null; opcoes: unknown[] }
    if (!token) envio.motivo = 'a_confirmar'
    else if (!b.pacotes?.length) envio.motivo = 'dimensao_desconhecida'
    else {
      const pacote = juntarPacotes(b.pacotes)
      if (!pacoteValido(pacote)) envio.motivo = 'pacote_grande'
      else {
        try {
          const r = await fetch('https://api.superfrete.com/api/v0/calculator', {
            method: 'POST', signal: AbortSignal.timeout(8000),
            headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json', 'User-Agent': Deno.env.get('SUPERFRETE_USER_AGENT') ?? 'SuaGraficaBH Loja' },
            body: JSON.stringify(corpoSuperFrete(ORIGEM, cep, pacote)),
          })
          if (!r.ok) { console.error('loja-frete: SuperFrete respondeu', r.status); envio.motivo = 'indisponivel' }
          else {
            const opcoes = opcoesEnvio(await r.json().catch(() => null))
            envio.opcoes = opcoes
            envio.disponivel = opcoes.length > 0
            if (!opcoes.length) envio.motivo = 'indisponivel'
          }
        } catch { console.error('loja-frete: SuperFrete sem resposta'); envio.motivo = 'indisponivel' }
      }
    }
  }
  return json(resposta)
})
