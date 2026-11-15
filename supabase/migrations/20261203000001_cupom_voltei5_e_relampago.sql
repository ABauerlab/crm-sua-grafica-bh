-- Cupom VOLTEI5 (5%, depois de avaliar no Google) e desconto relâmpago (3%, link válido por 1 hora).
-- Os dois entram como gatilhos de public.calcular_condicao_especial: mesma trava de piso, orçamento novo, link e PDF novos.
-- Tudo ou nada: se o percentual prometido não cabe acima do piso, a condição não é oferecida. Aditiva e idempotente.
alter table public.condicoes_especiais drop constraint if exists condicoes_especiais_gatilho_check;
alter table public.condicoes_especiais add constraint condicoes_especiais_gatilho_check check (gatilho = any (array['G1','G2','G3','RELAMPAGO','VOLTEI5']));

insert into public.app_settings (key, value) values ('cupons_codigo', jsonb_build_object(
  'VOLTEI5', jsonb_build_object('ativo', true, 'percentual', 5, 'validade_horas', 24, 'link_avaliacao', 'https://g.page/r/CZ6eNNGjdgO4EAE/review'),
  'relampago', jsonb_build_object('ativo', true, 'percentual', 3, 'validade_horas', 1)))
on conflict (key) do nothing;

create or replace function private.condicao_gatilho_fixo(p_orcamento uuid, p_gatilho text, p_registrar boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; pr public.parametros_comerciais%rowtype; cfg jsonb; f jsonb;
  v_pct numeric; v_horas integer; v_custo numeric; v_receita numeric; v_extra numeric; v_piso numeric; v_gordura numeric;
  v_base numeric; v_valor numeric; v_texto text; v_valida timestamptz; v_id uuid;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_nao_encontrado'); end if;
  if o.origem_id is not null then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ja_e_condicao_especial'); end if;
  if o.validade_ate is not null and o.validade_ate < now() then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_vencido'); end if;
  if o.status not in ('enviado', 'aceito') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ainda_nao_enviado_ou_encerrado'); end if;
  cfg := (select value from public.app_settings where key = 'cupons_codigo');

  if p_gatilho = 'RELAMPAGO' then
    if not coalesce((cfg -> 'relampago' ->> 'ativo')::boolean, false) then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'relampago_desligado'); end if;
    v_pct := (cfg -> 'relampago' ->> 'percentual')::numeric; v_horas := (cfg -> 'relampago' ->> 'validade_horas')::integer;
  else
    if not coalesce((cfg -> 'VOLTEI5' ->> 'ativo')::boolean, false) then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'cupom_invalido'); end if;
    if exists (select 1 from public.condicoes_especiais c where c.contact_id = o.contact_id and c.gatilho = 'VOLTEI5' and c.resultado <> 'cancelada') then
      return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'cupom_ja_usado');
    end if;
    v_pct := (cfg -> 'VOLTEI5' ->> 'percentual')::numeric; v_horas := (cfg -> 'VOLTEI5' ->> 'validade_horas')::integer;
  end if;

  -- uma condição por orçamento: nada de empilhar desconto
  if exists (select 1 from public.condicoes_especiais c where c.orcamento_id = o.id and c.resultado <> 'cancelada') then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'ja_houve_condicao_neste_orcamento');
  end if;
  if coalesce(o.desconto_valor, 0) > 0 then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ja_tem_desconto'); end if;

  select * into pr from public.parametros_comerciais where id = 1;
  f := private.orcamento_financeiro(o.id);
  if (f ->> 'itens')::integer = 0 then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_sem_itens'); end if;
  v_custo := (f ->> 'custo')::numeric;
  v_receita := (f ->> 'subtotal')::numeric + o.arte_valor + o.frete_valor;
  v_extra := (f ->> 'extra')::numeric;
  v_piso := ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100;
  v_gordura := greatest(v_receita - v_piso, 0);

  select coalesce(sum(i.quantidade * i.preco_unitario) filter (
           where p.permite_desconto and not (coalesce(p.categoria, '') = any (pr.categorias_sem_desconto))
             and not (coalesce(p.grupo_produto, '') = any (pr.categorias_sem_desconto))), 0)
    into v_base from public.orcamento_itens i join public.catalogo p on p.sku = i.sku where i.orcamento_id = o.id;
  if v_base <= 0 then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'itens_sem_permissao_de_desconto'); end if;

  -- o percentual prometido é o que sai: se não couber acima do piso, não oferece (tudo ou nada)
  v_valor := floor(v_base * v_pct / 100 * 100) / 100;
  if v_valor < 1 or v_valor > v_gordura then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'sem_gordura_acima_do_piso'); end if;

  v_texto := case when p_gatilho = 'RELAMPAGO' then 'desconto relâmpago de ' || trim(to_char(v_pct, 'FM990.##')) || '% (' || private.brl(v_valor) || ')'
                  else 'cupom VOLTEI5: ' || trim(to_char(v_pct, 'FM990.##')) || '% de desconto (' || private.brl(v_valor) || ')' end;
  v_valida := now() + make_interval(hours => v_horas);
  if p_registrar then
    insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate)
    values (o.id, o.contact_id, 2, p_gatilho, 'desconto', v_valor, v_texto, v_valida) returning id into v_id;
  end if;
  return jsonb_build_object('tipo', 'desconto', 'texto_curto', v_texto, 'valor', v_valor, 'valida_ate', v_valida, 'degrau', 2, 'condicao_id', v_id);
end $$;
revoke execute on function private.condicao_gatilho_fixo(uuid, text, boolean) from public, anon, authenticated;

do $mig$
declare d text; novo text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'calcular_condicao_especial';
  if position('condicao_gatilho_fixo' in d) > 0 then return; end if;
  novo := replace(d, 'if p_gatilho not in (''G1'', ''G2'', ''G3'') then',
    'if p_gatilho in (''RELAMPAGO'', ''VOLTEI5'') then return private.condicao_gatilho_fixo(p_orcamento, p_gatilho, p_registrar); end if;' || chr(10) || '  if p_gatilho not in (''G1'', ''G2'', ''G3'') then');
  if position('condicao_gatilho_fixo' in novo) = 0 then raise exception 'patch nao aplicou'; end if;
  execute novo;
end $mig$;

-- Follow-up F3 (dia 2, depois dos lembretes F1 e F2 sem resposta) passa a oferecer o desconto relâmpago.
alter table public.followup_regras drop constraint if exists followup_regras_gatilho_condicao_check;
alter table public.followup_regras add constraint followup_regras_gatilho_condicao_check check (gatilho_condicao is null or gatilho_condicao = any (array['G1','G2','G3','RELAMPAGO','VOLTEI5']));
update public.followup_regras set gatilho_condicao = 'RELAMPAGO',
  descricao = 'Dia 2, depois dos dois lembretes sem resposta: desconto relâmpago de 3% com link válido por 1 hora (se a trava de piso permitir)'
 where codigo = 'F3';
