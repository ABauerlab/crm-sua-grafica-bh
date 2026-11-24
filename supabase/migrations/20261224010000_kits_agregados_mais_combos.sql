-- 24/11/2026: kits agregados passam a casar também por categoria do catálogo (não só pelo texto da
-- descrição), porque vários pares não dá pra distinguir só pela descrição (cartão de visita, pasta e
-- panfleto usam os mesmos nomes de papel). Mais combos reais além de crachá+cordão: crachá+porta-crachá,
-- o trio crachá+cordão+porta-crachá, credencial+cordão, cartão+panfleto, papelaria corporativa
-- (cartão+pasta+timbrado) e boas-vindas (caderno+caneca+caneta). Continuam casando por padrão (qualquer
-- SKU da categoria/descrição), não por SKU fixo — então funciona pra qualquer tamanho, cor ou tiragem
-- desses itens, e sobrevive a troca de SKU na planilha. Aditiva e idempotente.

alter table public.kits_agregados_componentes alter column padrao_descricao drop not null;
alter table public.kits_agregados_componentes add column if not exists padrao_categoria text;
alter table public.kits_agregados_componentes
  drop constraint if exists kits_agregados_componentes_tem_padrao;
alter table public.kits_agregados_componentes
  add constraint kits_agregados_componentes_tem_padrao
  check (padrao_descricao is not null or padrao_categoria is not null);

alter table public.kits_agregados add column if not exists prioridade integer not null default 0;

-- ---------------------------------------------------------------- novos kits
insert into public.kits_agregados (slug, nome, descricao, prioridade)
values
  ('cracha-cordao-porta', 'Crachá + cordão + porta-crachá',
   'Os três no mesmo pedido: o lucro bruto mínimo do conjunto vale uma vez só. Nunca abaixo de 1,5x o custo, do piso duro nem do mínimo do conjunto.', 10),
  ('cracha-porta', 'Crachá + porta-crachá',
   'Crachá e porta-crachá retrátil no mesmo pedido: o lucro bruto mínimo vale uma vez só pro conjunto.', 0),
  ('credencial-cordao', 'Credencial + cordão',
   'Credencial de evento e cordão no mesmo pedido: o lucro bruto mínimo vale uma vez só pro conjunto.', 0),
  ('cartao-panfleto', 'Cartão de visita + panfleto',
   'Cartão de visita e panfleto no mesmo pedido: o lucro bruto mínimo vale uma vez só pro conjunto.', 0),
  ('papelaria-corporativa', 'Papelaria corporativa (cartão + pasta + timbrado)',
   'Cartão de visita, pasta e papel timbrado no mesmo pedido: o lucro bruto mínimo vale uma vez só pro conjunto.', 0),
  ('boas-vindas-corporativo', 'Boas-vindas corporativo (caderno + caneca + caneta)',
   'Caderno, caneca e caneta personalizados no mesmo pedido: o lucro bruto mínimo vale uma vez só pro conjunto.', 0)
on conflict (slug) do nothing;

insert into public.kits_agregados_componentes (kit_id, papel, padrao_descricao, padrao_categoria, recebe_abatimento)
select k.id, v.papel, v.padrao_descricao, v.padrao_categoria, v.recebe
  from public.kits_agregados k
  cross join (values
    ('cracha-cordao-porta', 'cracha', '^CRACH', null, false),
    ('cracha-cordao-porta', 'cordao', '^COR(D|C)', null, true),
    ('cracha-cordao-porta', 'porta_cracha', 'PORTA.?CRACH', null, false),

    ('cracha-porta', 'cracha', '^CRACH', null, false),
    ('cracha-porta', 'porta_cracha', 'PORTA.?CRACH', null, true),

    ('credencial-cordao', 'credencial', null, '^CREDENCI', false),
    ('credencial-cordao', 'cordao', '^COR(D|C)', null, true),

    ('cartao-panfleto', 'cartao', null, '^CART(Õ|O)ES DE VISITA', false),
    ('cartao-panfleto', 'panfleto', null, '^PANFLETOS', true),

    ('papelaria-corporativa', 'cartao', null, '^CART(Õ|O)ES DE VISITA', false),
    ('papelaria-corporativa', 'pasta', null, '^PASTAS', true),
    ('papelaria-corporativa', 'timbrado', null, '^PAPEL TIMBRADO', false),

    ('boas-vindas-corporativo', 'caderno', null, '^AGENDAS, CADERNOS', false),
    ('boas-vindas-corporativo', 'caneca', null, '^CANECA', true),
    ('boas-vindas-corporativo', 'caneta', null, '^CANETAS', false)
  ) as v(slug, papel, padrao_descricao, padrao_categoria, recebe)
 where k.slug = v.slug
on conflict (kit_id, papel) do update set padrao_descricao = excluded.padrao_descricao, padrao_categoria = excluded.padrao_categoria;

-- ---------------------------------------------------------------- kit_agregado_aplicar casa também por categoria
create or replace function private.kit_agregado_aplicar(p_orcamento uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  k record;
  pr public.parametros_comerciais%rowtype;
  v_comp record;
  v_alvo record;
  v_falta boolean;
  v_val jsonb;
  v_linha numeric;
  v_piso numeric;
  v_cap numeric;
  v_r numeric;
  v_novo numeric;
  v_unit numeric;
  v_tent numeric[] := array[65, 50, 40, 30, 20, 10];
  t numeric;
  v_abatido numeric;
  v_fin jsonb;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if exists (select 1 from public.orcamentos where id = p_orcamento and kit_agregado_id is not null) then return null; end if;

  for k in select * from public.kits_agregados where ativo order by prioridade desc, criado_em loop
    v_falta := false;
    for v_comp in select * from public.kits_agregados_componentes where kit_id = k.id loop
      if not exists (
        select 1 from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku
         where i.orcamento_id = p_orcamento
           and ((v_comp.padrao_descricao is not null and i.descricao ~* v_comp.padrao_descricao)
                or (v_comp.padrao_categoria is not null and c.categoria ~* v_comp.padrao_categoria))
      ) then
        v_falta := true;
      end if;
    end loop;
    if v_falta then continue; end if;

    select i.id, i.quantidade, i.preco_unitario, i.sku, coalesce(c.custo, 0) as custo_pacote, coalesce(i.piso_duro, 0) as piso_duro
      into v_alvo
      from public.orcamento_itens i
      join public.kits_agregados_componentes kc on kc.kit_id = k.id and kc.recebe_abatimento
      left join public.catalogo c on c.sku = i.sku
     where i.orcamento_id = p_orcamento
       and ((kc.padrao_descricao is not null and i.descricao ~* kc.padrao_descricao)
            or (kc.padrao_categoria is not null and c.categoria ~* kc.padrao_categoria))
     order by i.quantidade * i.preco_unitario desc
     limit 1;
    if not found or v_alvo.sku is null then continue; end if;

    v_linha := v_alvo.quantidade * v_alvo.preco_unitario;
    v_piso := greatest(v_alvo.custo_pacote * v_alvo.quantidade * pr.multiplicador_piso, v_alvo.piso_duro);
    v_cap := v_linha - v_piso;
    if v_cap < 5 then continue; end if;

    foreach t in array v_tent loop
      v_r := least(t, v_cap);
      -- novo total da linha termina em ,90 como o resto da tabela, sem passar do abatimento tentado
      v_novo := floor(v_linha - v_r - 0.90) + 0.90;
      if v_novo < v_piso or v_novo >= v_linha then continue; end if;
      v_unit := ceil(v_novo / v_alvo.quantidade * 100) / 100;
      begin
        update public.orcamento_itens set preco_unitario = v_unit where id = v_alvo.id;
        v_val := public.validar_margem(p_orcamento);
        if v_val ->> 'status' is distinct from 'ok' then
          raise exception 'kit_recusado_pela_trava';
        end if;
        v_abatido := round(v_linha - v_alvo.quantidade * v_unit, 2);
        update public.orcamentos set kit_agregado_id = k.id, kit_abatimento = v_abatido where id = p_orcamento;
        v_fin := private.orcamento_financeiro(p_orcamento);
        update public.orcamentos
           set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
               lucro_liquido = (v_fin ->> 'lucro')::numeric,
               margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
         where id = p_orcamento;
        return jsonb_build_object('kit', k.nome, 'abatimento', v_abatido);
      exception when others then
        null; -- a atualização do bloco volta sozinha; tenta um abatimento menor
      end;
    end loop;
  end loop;
  return null;
end
$f$;

-- ---------------------------------------------------------------- upsell: avisa quando falta a outra metade do kit
create or replace function private.upsell_regra(p_skus text[], p_segmento text, p_arte_modo text) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  v_txt text;
  v_seg text := lower(coalesce(p_segmento, ''));
  v_cats text;
  v_tem_cracha boolean; v_tem_cordao boolean; v_tem_porta boolean;
  v_tem_cartao boolean; v_tem_credencial boolean; v_tem_panfleto boolean;
begin
  select string_agg(lower(coalesce(c.grupo_produto, '') || ' ' || coalesce(c.categoria, '') || ' ' || coalesce(c.descricao, '')), ' '),
         string_agg(upper(coalesce(c.categoria, '')), ' | ')
    into v_txt, v_cats from public.catalogo c where c.sku = any (p_skus);

  v_tem_cracha := v_txt ~ '(^|\W)cracha';
  v_tem_cordao := v_txt ~ 'cord(ã|a)o|cord(õ|o)es';
  v_tem_porta := v_txt ~ 'porta.?cracha';
  v_tem_cartao := v_cats ~* 'CART(Õ|O)ES DE VISITA';
  v_tem_credencial := v_cats ~* 'CREDENCI';
  v_tem_panfleto := v_cats ~* 'PANFLETOS';

  if v_tem_cracha and not v_tem_cordao then
    return jsonb_build_object('tipo', 'kit_cracha_cordao', 'texto', 'Quer que eu já inclua o cordão junto? Saindo no mesmo pedido o conjunto fica mais em conta.');
  end if;
  if v_tem_cracha and v_tem_cordao and not v_tem_porta then
    return jsonb_build_object('tipo', 'kit_cracha_porta', 'texto', 'Quer aproveitar e incluir o porta-crachá retrátil também? No mesmo pedido sai mais em conta.');
  end if;
  if v_tem_credencial and not v_tem_cordao then
    return jsonb_build_object('tipo', 'kit_credencial_cordao', 'texto', 'Quer que eu já inclua o cordão para a credencial? Saindo junto fica mais em conta.');
  end if;
  if v_tem_cartao and not v_tem_panfleto then
    return jsonb_build_object('tipo', 'cartao_adesivo_panfleto', 'texto', 'Que tal incluir adesivos ou panfletos para divulgar o seu negócio junto com os cartões?');
  end if;
  if v_seg ~ 'barbearia|delivery|loja|lan(ç|c)amento' then
    return jsonb_build_object('tipo', 'kit_segmento', 'texto', 'Temos kits prontos para o seu segmento. Pergunte pelo kit e veja o que cabe no seu pedido.');
  end if;
  if p_arte_modo = 'nenhuma' then
    return jsonb_build_object('tipo', 'servico_arte', 'texto', 'Não tem arte pronta? Criamos a sua arte por um valor fixo, é só pedir.');
  end if;
  return null;
end;
$$;
