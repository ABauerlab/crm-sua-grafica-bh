import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  try {
    const input = await req.json();
    const calculo = input.calculo;
    if (!calculo || calculo.origem !== 'calcular_preco') {
      return json({ error: 'preco_deve_vir_de_calcular_preco' }, 422);
    }
    if (!Number.isFinite(Number(calculo.piso)) || !Number.isFinite(Number(calculo.custoTotal))) {
      return json({ error: 'piso_e_custo_obrigatorios' }, 422);
    }
    const total = Number(input.total);
    const piso = Number(calculo.piso);
    if (!Number.isFinite(total) || total < piso) {
      return json({ error: 'total_abaixo_do_piso' }, 422);
    }
    if (!Array.isArray(input.itens) || input.itens.length === 0) {
      return json({ error: 'orcamento_sem_itens' }, 422);
    }

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const validadeHoras = Number(input.validadeHoras || 48);
    const { data: orcamento, error: orcamentoError } = await supabase.from('orcamentos').insert({
      contato_id: input.contatoId ?? null,
      pedido_id: input.pedidoId ?? null,
      subtotal: Number(input.subtotal || 0),
      valor_arte: Number(input.valorArte || 0),
      valor_frete: Number(input.valorFrete || 0),
      total,
      data_prevista: input.dataPrevista ?? null,
      validade_horas: validadeHoras,
      regra_preco: calculo.regra ?? null,
      confianca_preco: calculo.confianca ?? null,
      margem_percentual: calculo.margemPercentual ?? null,
      custo_total: Number(calculo.custoTotal),
      piso_aplicado: piso,
      fornecedor_ref: calculo.fornecedorRef ?? null,
      avisos: input.avisos ?? [],
    }).select('id, numero, status, subtotal, valor_arte, valor_frete, total, data_prevista, valido_ate, avisos').single();
    if (orcamentoError) return json({ error: 'falha_ao_criar_orcamento', detail: orcamentoError.message }, 500);

    const rows = input.itens.map((item: Record<string, unknown>) => ({
      orcamento_id: orcamento.id,
      sku: String(item.sku ?? ''),
      descricao: String(item.descricao ?? ''),
      especificacao: item.especificacao ?? {},
      quantidade: Number(item.quantidade),
      valor_unitario: Number(item.valorUnitario),
      valor_total: Number(item.valorTotal),
      sku_fornecedor: item.skuFornecedor ?? null,
      custo_unitario: item.custoUnitario ?? null,
      custo_total: item.custoTotal ?? null,
    }));
    const { error: itemError } = await supabase.from('orcamento_itens').insert(rows);
    if (itemError) {
      await supabase.from('orcamentos').delete().eq('id', orcamento.id);
      return json({ error: 'falha_ao_criar_itens', detail: itemError.message }, 500);
    }
    return json({ ...orcamento, itens: input.itens.map((item: Record<string, unknown>) => ({ ...item, skuFornecedor: undefined, custoUnitario: undefined, custoTotal: undefined })) });
  } catch (error) {
    return json({ error: 'payload_invalido', detail: String(error) }, 400);
  }
});
