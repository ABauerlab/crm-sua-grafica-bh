import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const input = await req.json();
    if (!input.orcamentoId || !Number.isFinite(Number(input.total))) return json({ error: 'orcamento_e_total_obrigatorios' }, 422);
    const providerUrl = Deno.env.get('PAGAMENTO_PROVIDER_URL');
    const providerToken = Deno.env.get('PAGAMENTO_PROVIDER_TOKEN');
    if (!providerUrl || !providerToken) return json({ error: 'provedor_de_pagamento_nao_configurado' }, 503);
    const response = await fetch(providerUrl, { method: 'POST', headers: { Authorization: `Bearer ${providerToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ reference: input.orcamentoId, amount: Number(input.total), expiresInHours: 24, description: `Orçamento ${input.numero ?? input.orcamentoId}` }) });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || !result.url) return json({ error: 'provedor_de_pagamento_falhou', status: response.status }, 502);
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const expiration = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const update = await supabase.from('orcamentos').update({ pagamento_url: result.url, pagamento_gerado_em: new Date().toISOString(), pagamento_expira_em: expiration }).eq('id', input.orcamentoId);
    if (update.error) return json({ error: 'falha_ao_atualizar_pagamento', detail: update.error.message }, 500);
    return json({ orcamentoId: input.orcamentoId, pagamentoUrl: result.url, expiraEm: expiration });
  } catch (error) {
    return json({ error: 'payload_invalido', detail: String(error) }, 400);
  }
});
