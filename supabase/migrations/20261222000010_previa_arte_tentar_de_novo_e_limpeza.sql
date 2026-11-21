-- Item 2 (21/11/2026): o botão "Tentar de novo" (status='erro' em previas_arte) chamava
-- previa_arte_regenerar, que só aceitava status='pronta'. Toda vez que o worker falhava, o cliente
-- ficava travado: o botão existia mas não fazia nada (ok:false silencioso, sem erro na tela).
-- previa_arte_regenerar agora também aceita status='erro', mandando a prévia de volta pra fila.
-- Aditiva e idempotente (CREATE OR REPLACE).
create or replace function public.previa_arte_regenerar(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v public.previas_arte%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  select * into v from public.previas_arte where token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  if v.expira_em <= now() then return jsonb_build_object('ok', false, 'motivo', 'expirado'); end if;
  if v.status = 'erro' then
    update public.previas_arte set status = 'pendente', fase = 'geracao', erro_detalhe = null, processando_desde = null, atualizado_em = now() where id = v.id;
    return jsonb_build_object('ok', true, 'status', 'pendente');
  end if;
  if v.status <> 'pronta' then return jsonb_build_object('ok', false, 'motivo', 'ainda_nao_pronta'); end if;
  if v.geracoes >= 2 then return jsonb_build_object('ok', false, 'motivo', 'limite_geracao_atingido', 'alternativa', 'Use previa_arte_ajustar com feedback.'); end if;
  if v.ajustes > 0 then return jsonb_build_object('ok', false, 'motivo', 'ja_em_rodada_de_ajuste'); end if;
  update public.previas_arte set status = 'pendente', fase = 'geracao', erro_detalhe = null, atualizado_em = now() where id = v.id;
  return jsonb_build_object('ok', true, 'status', 'pendente');
end;
$$;

-- Limpeza automática (48h) das prévias de pedidos não pagos: devolve os caminhos de Storage para o
-- worker previa-arte-processar remover a cada execução do cron (preserva as de pedidos pagos).
create or replace function public.previa_arte_limpar_expiradas() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ids uuid[]; v_resultado text[]; v_uploads text[];
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;

  select coalesce(array_agg(p.id), '{}'), coalesce(array_agg(p.resultado_path) filter (where p.resultado_path is not null), '{}'),
         coalesce(array_agg(u) filter (where u is not null), '{}')
    into v_ids, v_resultado, v_uploads
  from public.previas_arte p
  left join lateral jsonb_array_elements_text(coalesce(p.uploads, '[]'::jsonb)) u on true
  where p.expira_em < now()
    and not exists (select 1 from public.orders o where o.id = p.order_id and o.paid_at is not null);

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object('ok', true, 'removidos', 0, 'resultado_paths', '[]'::jsonb, 'upload_paths', '[]'::jsonb);
  end if;

  delete from public.previas_arte where id = any(v_ids);

  return jsonb_build_object('ok', true, 'removidos', array_length(v_ids, 1),
    'resultado_paths', to_jsonb(v_resultado), 'upload_paths', to_jsonb(v_uploads));
end;
$$;
revoke execute on function public.previa_arte_limpar_expiradas() from public, anon, authenticated;
grant execute on function public.previa_arte_limpar_expiradas() to service_role;
