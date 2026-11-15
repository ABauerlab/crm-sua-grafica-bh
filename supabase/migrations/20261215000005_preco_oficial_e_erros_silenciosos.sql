-- 15/11/2026: o preço vendido tem que ser SEMPRE o da planilha oficial e erro não interrompe o dono.
-- 1) buscar_produto nunca mostra SKU sem preço de planilha (9 SKUs legados caíam na fórmula antiga) e montar_orcamento recusa esse SKU
--    com orientação de oferecer o produto mais próximo.
-- 2) alerta_criar: erros de agente, ferramenta, workflow e follow-up entram só no resumo de 2 h (nunca na hora). O vigia de silêncio (chave silencio:) continua imediato.
-- 3) O alerta de orçamento alto sai: orçamento alto é pedido grande. (Aplicado em produção; esta migration repete de forma idempotente.)
do $mig$
declare d text; a1 text; a2 text; a3 text := 'v_grav text := case when lower(coalesce(p_gravidade, ''''))';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'buscar_produto';
  if position('preco_oficial_obrigatorio' in d) = 0 then
    a1 := 'where c.sku is not null and c.vendavel' || chr(10);
    if position(a1 in d) = 0 then raise exception 'âncora da busca não encontrada'; end if;
    execute replace(d, a1, 'where c.sku is not null and c.vendavel and c.preco_venda is not null /* preco_oficial_obrigatorio */' || chr(10));
  end if;
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'montar_orcamento';
  if position('preco_oficial_obrigatorio' in d) = 0 then
    a2 := E'    v_qtd := coalesce((it ->> ''quantidade'')::integer, 1);';
    if position(a2 in d) = 0 then raise exception 'âncora do orçamento não encontrada'; end if;
    execute replace(d, a2, a2 || E'\n    if exists (select 1 from public.catalogo cx where cx.sku = v_sku and cx.preco_venda is null) then /* preco_oficial_obrigatorio */\n      return jsonb_build_object(''status'', ''bloqueado'', ''motivo'', ''sem_preco_oficial'', ''alternativa'', ''Esse item não tem preço oficial na planilha. Ofereça o produto mais próximo que a busca devolveu e continue o atendimento.'');\n    end if;');
  end if;
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'alerta_criar';
  if position('erros_viram_resumo' in d) = 0 then
    if position(a3 in d) = 0 then raise exception 'âncora de gravidade não encontrada'; end if;
    execute replace(d, a3, 'v_grav text := case when p_tipo in (''agente_falhou'', ''falha_ferramenta'', ''erro_workflow'', ''erro_followup'') and coalesce(p_chave, '''') not like ''silencio:%'' then ''baixa'' /* erros_viram_resumo */ when lower(coalesce(p_gravidade, ''''))');
  end if;
end
$mig$;

create or replace function private.orcamento_revisao_alerta() returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  return new;
end $f$;
