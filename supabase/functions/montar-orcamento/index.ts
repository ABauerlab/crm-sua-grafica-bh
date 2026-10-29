import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const input = await req.json(); const calculo = input.calculo;
    if (!calculo || calculo.origem !== 'calcular_preco') return json({ error: 'preco_deve_vir_de_calcular_preco' }, 422);
    const piso = Number(calculo.piso); const total = Number(input.total);
    if (!Number.isFinite(piso) || !Number.isFinite(Number(calculo.custoTotal))) return json({ error: 'piso_e_custo_obrigatorios' }, 422);
    if (!Number.isFinite(total) || total < piso) return json({ error: 'total_abaixo_do_piso' }, 422);
    if (!Array.isArray(input.itens) || input.itens.length === 0) return json({ error: 'orcamento_sem_itens' }, 422);
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: orcamento, error } = await supabase.from('orcamentos').insert({ contact_id: input.contactId ?? null, conversation_id: input.conversationId ?? null, order_id: input.orderId ?? null, status: 'rascunho', entrega: input.entrega ?? null, bairro: input.bairro ?? null, cep: input.cep ?? null, metodo_previsto: input.metodoPrevisto ?? null, arte_modo: input.arteModo ?? 'nenhuma', arte_valor: Number(input.valorArte || 0), frete_valor: Number(input.valorFrete || 0), desconto_valor: Number(input.desconto || 0), subtotal: Number(input.subtotal || 0), total, validade_ate: input.validoAte ?? new Date(Date.now() + Number(input.validadeHoras || 48) * 3600000).toISOString(), regra_preco: calculo.regra ?? null, confianca_preco: calculo.confianca ?? null, margem_liquida_pct: calculo.margemPercentual ?? null, lucro_liquido: calculo.lucroLiquido ?? null, validade_horas: Number(input.validadeHoras || 48), custo_total: Number(calculo.custoTotal), piso_aplicado: piso, fornecedor_ref: calculo.fornecedorRef ?? null, avisos: input.avisos ?? [] }).select('id, numero, status, subtotal, total, validade_ate, pdf_path, link_pagamento, avisos').single();
    if (error) return json({ error: 'falha_ao_criar_orcamento', detail: error.message }, 500);
    const rows = input.itens.map((item: Record<string, unknown>) => ({ orcamento_id: orcamento.id, sku: String(item.sku ?? ''), descricao: String(item.descricao ?? ''), quantidade: Number(item.quantidade), preco_unitario: Number(item.valorUnitario), regra_preco: calculo.regra ?? null, confianca_preco: calculo.confianca ?? null, margem_liquida_pct: calculo.margemPercentual ?? null, preco_mercado_id: item.precoMercadoId ?? null, consulta_mercado_id: item.consultaMercadoId ?? null, mercado_mediana: item.mercadoMediana ?? null, fontes_mercado: item.fontesMercado ?? null, nao_competitivo: item.naoCompetitivo ?? false, piso: item.piso ?? piso, piso_duro: item.pisoDuro ?? piso, lucro_liquido: item.lucroLiquido ?? null, especificacao: item.especificacao ?? {}, valor_total: Number(item.valorTotal), sku_fornecedor: item.skuFornecedor ?? null, custo_unitario: item.custoUnitario ?? null, custo_total: item.custoTotal ?? null }));
    const itemResult = await supabase.from('orcamento_itens').insert(rows);
    if (itemResult.error) { await supabase.from('orcamentos').delete().eq('id', orcamento.id); return json({ error: 'falha_ao_criar_itens', detail: itemResult.error.message }, 500); }
    return json({ ...orcamento, itens: input.itens.map((item: Record<string, unknown>) => ({ descricao: item.descricao, especificacao: item.especificacao, quantidade: item.quantidade, valorUnitario: item.valorUnitario, valorTotal: item.valorTotal })) });
  } catch (error) { return json({ error: 'payload_invalido', detail: String(error) }, 400); }
});
