import { corsHeaders, json, requireOwnerOrServer, requireStaff, serviceClient } from '../_shared/http.ts'
import { cepLimpo, lerEnderecoCep } from '../_shared/loja-frete.ts'

// Completa rua, bairro, cidade, UF e código IBGE do contato a partir do CEP (ViaCEP). Só preenche o que está vazio.
// Chamada pelo CRM (atendente logado) ou pelo servidor. Não guarda conteúdo de mensagem em log.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const staff = await requireStaff(req, db)
  if (!staff && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  let input: { contact_id?: string }
  try { input = await req.json() } catch { return json({ error: 'Corpo da requisição inválido.' }, 400) }
  if (!input.contact_id) return json({ error: 'Informe o contato.' }, 400)

  const { data: ct } = await db.from('contacts').select('id, cep, logradouro, bairro, municipio, uf, codigo_ibge').eq('id', input.contact_id).maybeSingle()
  if (!ct) return json({ error: 'Contato não encontrado.' }, 404)
  const cep = cepLimpo(ct.cep)
  if (!cep) return json({ error: 'O contato ainda não tem um CEP válido.' }, 400)

  let e = null as ReturnType<typeof lerEnderecoCep>
  const { data: cache } = await db.from('cep_bairros').select('cep, logradouro, bairro, cidade, uf, codigo_ibge').eq('cep', cep).maybeSingle()
  if (cache?.codigo_ibge) e = cache
  else {
    try {
      const r = await fetch(`https://viacep.com.br/ws/${cep}/json/`, { signal: AbortSignal.timeout(5000) })
      if (r.ok) e = lerEnderecoCep(cep, await r.json().catch(() => null))
    } catch { /* usa o cache, se houver */ }
    if (e) await db.from('cep_bairros').upsert({ ...e, fonte: 'viacep', atualizado_em: new Date().toISOString() })
    else if (cache) e = cache
  }
  if (!e) return json({ error: 'Não achei esse CEP. Confira com o cliente.' }, 404)

  const vazio = (v: unknown) => !String(v ?? '').trim()
  const patch: Record<string, string> = {}
  if (vazio(ct.logradouro) && e.logradouro) patch.logradouro = e.logradouro
  if (vazio(ct.bairro) && e.bairro) patch.bairro = e.bairro
  if (vazio(ct.municipio) && e.cidade) patch.municipio = e.cidade
  if (vazio(ct.uf) && e.uf) patch.uf = e.uf
  if (vazio(ct.codigo_ibge) && e.codigo_ibge) patch.codigo_ibge = e.codigo_ibge
  if (Object.keys(patch).length) {
    const { error } = await db.from('contacts').update(patch).eq('id', ct.id)
    if (error) return json({ error: 'Não foi possível salvar o endereço.' }, 500)
  }
  return json({ ok: true, preenchidos: Object.keys(patch) })
})
