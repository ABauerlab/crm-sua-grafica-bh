-- Riscos abertos antes do tráfego pago (15/11/2026). Aditiva e idempotente, sem drop.
-- 1) buscar_produto: as 4 opções passam a ser as mais baratas entre as relevantes (antes espalhava até o item mais caro),
--    e A4/A3 viram tamanho de catálogo (A4 = " x 300", A3 = "300 x 420"). A5/A6 já existiam na migration 20261215000002.
-- 2) Alerta ao dono quando um orçamento é enviado com total a partir de R$ 1.000 ou com adesivo/banner (nunca bloqueia o envio).
-- 3) Testes e8-fluxo-2 e e8-fluxo-4 passam a pedir um papel que existe (couchê 300g 4x4).
-- ATENÇÃO: os itens 1 e 3 já foram aplicados em produção pelo agente; o item 2 NÃO foi (o Supabase pediu confirmação).

do $mig$
declare d text; a1 text; a2 text; a3 text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'buscar_produto';
  if d is null then raise exception 'buscar_produto não encontrada'; end if;
  if position('opcoes_por_relevancia' in d) = 0 then
    a1 := 'where (not v_exact) or rn in (1, greatest(1, ceil(n / 3.0)::int), greatest(1, ceil(2 * n / 3.0)::int), n)';
    if position(a1 in d) = 0 then raise exception 'âncora das opções não encontrada'; end if;
    d := replace(d, a1, 'where true /* opcoes_por_relevancia: as 4 mais baratas entre as relevantes, sem espalhar até o item mais caro */');
  end if;
  if position('a4( ' in d) = 0 then
    a2 := 'when v_norm ~ ''(^| )a6( |$)'' then ''100 x 150'' end;';
    a3 := 'regexp_replace(v_norm, ''(^| )a[56]( |$)'', '' '', ''g'')';
    if position(a2 in d) = 0 or position(a3 in d) = 0 then raise exception 'âncoras de tamanho não encontradas'; end if;
    d := replace(d, a2, 'when v_norm ~ ''(^| )a6( |$)'' then ''100 x 150'' when v_norm ~ ''(^| )a4( |$)'' then '' x 300'' when v_norm ~ ''(^| )a3( |$)'' then ''300 x 420'' end;');
    d := replace(d, a3, 'regexp_replace(v_norm, ''(^| )a[3-6]( |$)'', '' '', ''g'')');
  end if;
  execute d;
end
$mig$;

create or replace function private.orcamento_revisao_alerta()
returns trigger language plpgsql security definer set search_path = '' as $f$
declare v_motivo text; v_cat text;
begin
  if coalesce(new.teste, false) or new.status is distinct from 'enviado' or old.status is not distinct from 'enviado' then return new; end if;
  begin
    select string_agg(distinct lower(c.categoria), ', ') into v_cat
      from public.orcamento_itens i join public.catalogo c on c.sku = i.sku
     where i.orcamento_id = new.id and (c.categoria ilike 'adesivo%' or c.categoria ilike 'banner%');
    if coalesce(new.total, 0) >= 1000 then
      v_motivo := 'Orçamento ' || coalesce(new.numero::text, '') || ' enviado com total alto (R$ ' || to_char(new.total, 'FM999G999D00') || '). Confira os itens antes de o cliente aprovar.';
    elsif v_cat is not null then
      v_motivo := 'Orçamento ' || coalesce(new.numero::text, '') || ' enviado com item de ' || v_cat || '. Confira tamanho, quantidade e preço antes de o cliente aprovar.';
    end if;
    if v_motivo is not null then
      perform public.alerta_criar('agente_chamado', 'media', new.contact_id, new.conversation_id, new.order_id, v_motivo,
        jsonb_build_object('orcamento_id', new.id, 'origem', 'revisao_orcamento'), 'orc_revisao:' || new.id, null);
    end if;
  exception when others then
    raise warning 'alerta de revisão do orçamento não criado: %', sqlerrm;
  end;
  return new;
end $f$;
revoke all on function private.orcamento_revisao_alerta() from public, anon, authenticated;

do $t$
begin
  if not exists (select 1 from pg_trigger where tgname = 'orcamento_revisao_alerta' and tgrelid = 'public.orcamentos'::regclass) then
    create trigger orcamento_revisao_alerta after update of status on public.orcamentos
      for each row execute function private.orcamento_revisao_alerta();
  end if;
end
$t$;

update public.testes_conversa set entradas = jsonb_set(entradas, '{mensagens,0,texto}', '"Quero 500 cartões de visita no papel couchê 300g, 4x4, tamanho 91x51. Já tenho a arte pronta. Entrega no Centro de BH, pode orçar?"')
 where nome = 'e8-fluxo-4-especificado';
update public.testes_conversa set entradas = jsonb_set(entradas, '{mensagens,1,texto}', '"Quero 1000 unidades, no couchê 300g. Preciso que crie a arte"')
 where nome = 'e8-fluxo-2-orcar-e-fechar';
