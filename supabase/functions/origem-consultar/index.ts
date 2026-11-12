import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'

// Conferência ao vivo de um SKU na origem logada (Chrome persistente na VPS). Dono ou service role.
// Entrada: { sku }. Saída ao agente: só o essencial e sem custo, fornecedor nem endereço da origem.
// Modo (app_settings.origem.modo): 'observar' (só registra) ou 'atualizar' (custo e prazo SÓ SOBEM no catálogo; queda apenas registra).

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  if (!(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)
  let sku = ''
  try { sku = String((await req.json()).sku ?? '').trim().toUpperCase() } catch { return json({ error: 'Corpo inválido.' }, 400) }
  if (!/^[A-Z0-9\-_]{2,40}$/.test(sku)) return json({ error: 'Informe o sku.' }, 400)

  const { data: seg } = await db.from('app_segredos').select('chave, valor').in('chave', ['origem_api_url', 'origem_api_token'])
  const url = seg?.find((s) => s.chave === 'origem_api_url')?.valor
  const token = seg?.find((s) => s.chave === 'origem_api_token')?.valor
  const { data: cfgRow } = await db.from('app_settings').select('value').eq('key', 'origem').maybeSingle()
  const modo = String((cfgRow?.value as { modo?: string } | null)?.modo ?? 'observar')
  if (!url || !token) return json({ ok: false, status: 'inconclusivo', motivo: 'origem_nao_configurada' })

  // Sem sessão logada na VPS: responde na hora (a Laura segue sem a conferência)
  const { data: sess } = await db.from('origem_sessao').select('logado').eq('id', true).maybeSingle()
  if (sess?.logado !== true) return json({ ok: false, status: 'inconclusivo', motivo: 'sessao_expirada' })

  const { data: info } = await db.rpc('origem_caminho_do_sku', { p_sku: sku })
  if (!info?.ok) return json({ ok: false, status: 'inconclusivo', motivo: info?.motivo ?? 'sem_pagina_mapeada' })

  let dados: Record<string, unknown> | null = null
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 60000)
    const res = await fetch(`${url}/consultar`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ caminho: info.caminho }), signal: ctl.signal })
    clearTimeout(t)
    const j = await res.json().catch(() => ({}))
    if (!res.ok || !j.ok) {
      await db.rpc('origem_registrar', { p_sku: sku, p_caminho: info.caminho, p_status: 'erro', p_custo: info.custo, p_detalhe: { erro: j.error ?? `http_${res.status}` } })
      return json({ ok: false, status: 'inconclusivo', motivo: j.error === 'sessao_expirada' ? 'sessao_expirada' : 'origem_indisponivel' })
    }
    dados = j
  } catch (e) {
    console.error('Falha ao consultar a origem:', (e as Error).message)
    return json({ ok: false, status: 'inconclusivo', motivo: 'origem_indisponivel' })
  }

  // Aplica a leitura ao catálogo (custo e prazo só sobem; tamanho final de embalagens é gravado) e registra a consulta
  const aplicar = modo === 'atualizar'
  const { data: res } = await db.rpc('origem_aplicar', { p_sku: sku, p_dados: dados, p_aplicar: aplicar })
  const status = String(res?.status ?? 'inconclusivo')
  const imagens = ((dados?.imagens as { src: string }[] | undefined) ?? []).map((i) => i.src)
  const foto = imagens.find((u) => u.toUpperCase().includes(sku)) ?? null
  await db.rpc('origem_registrar', {
    p_sku: sku, p_caminho: info.caminho, p_status: status, p_custo: Number(info.custo),
    p_detalhe: { custo_origem: res?.custo_origem, aplicado: res?.aplicado, motivo: res?.motivo, prazo_origem: res?.prazo_origem, prazo_catalogo: res?.prazo_catalogo, tamanho_final: res?.tamanho_final,
      ficha: dados?.ficha, valor_servico: dados?.valor_servico, acabamentos: dados?.acabamentos, quantidades: dados?.quantidades, foto_url: foto, imagens: imagens.slice(0, 12), cache: dados?.cache },
  })

  // Resposta ao agente: sem valores de custo, sem endereço da origem, sem URL de imagem
  return json({ ok: true, status, custo_atualizado: res?.aplicado === true, tamanho_final: res?.tamanho_final ?? null, prazo_dias_uteis_origem: res?.prazo_origem ?? null, tem_foto: !!foto })
})
})
