import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    const input = await req.json();
    if (!input.orcamentoId || !input.documento) return json({ error: 'orcamento_e_documento_obrigatorios' }, 422);
    const rendererUrl = Deno.env.get('RENDERER_URL');
    if (!rendererUrl) return json({ error: 'renderer_nao_configurado' }, 503);
    const render = await fetch(`${rendererUrl.replace(/\/$/, '')}/orcamento/pdf`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(Deno.env.get('RENDERER_TOKEN') ? { Authorization: `Bearer ${Deno.env.get('RENDERER_TOKEN')}` } : {}) }, body: JSON.stringify(input.documento) });
    if (!render.ok) return json({ error: 'renderer_falhou', status: render.status }, 502);
    const pdf = new Uint8Array(await render.arrayBuffer());
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const path = `orcamentos/${input.orcamentoId}/orcamento-v${Number(input.versao || 1)}.pdf`;
    const upload = await supabase.storage.from('orcamentos').upload(path, pdf, { contentType: 'application/pdf', upsert: true });
    if (upload.error) return json({ error: 'falha_ao_salvar_pdf', detail: upload.error.message }, 500);
    const update = await supabase.from('orcamentos').update({ pdf_storage_path: path, pdf_gerado_em: new Date().toISOString(), pdf_versao: Number(input.versao || 1) }).eq('id', input.orcamentoId);
    if (update.error) return json({ error: 'falha_ao_atualizar_orcamento', detail: update.error.message }, 500);
    return json({ orcamentoId: input.orcamentoId, storagePath: path, mimeType: 'application/pdf' });
  } catch (error) {
    return json({ error: 'payload_invalido', detail: String(error) }, 400);
  }
});
