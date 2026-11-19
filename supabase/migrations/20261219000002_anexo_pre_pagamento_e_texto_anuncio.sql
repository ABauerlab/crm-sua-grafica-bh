-- 19/11/2026: (1) o WF1 só lê imagem e PDF com visão (Gemini) quando a conversa ainda não tem pagamento aprovado;
-- (2) descrições legíveis nas opções do lembrete de anúncio. Aditiva e idempotente.

create or replace function public.agente_anexo_pre_pagamento(p_conversation uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('pre_pagamento', private.agente_fase(cv.contact_id) <> 'pos_pagamento',
                               'modelo', coalesce((select c.modelo_resumo from public.agente_config c where c.id = 1), 'gemini-3.1-flash-lite'))
       from public.conversations cv where cv.id = p_conversation),
    jsonb_build_object('pre_pagamento', false));
$$;
revoke all on function public.agente_anexo_pre_pagamento(uuid) from public, anon, authenticated;
grant execute on function public.agente_anexo_pre_pagamento(uuid) to service_role;

create or replace function private.desc_publica(p text) returns text
language sql immutable set search_path = '' as $$
  select replace(replace(upper(left(x, 1)) || substr(x, 2), 'Couche', 'Couchê'), 'couche', 'couchê')
    from (select lower(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(p, ''),
            ' FR E VR', ' frente e verso', 'gi'), 'LAM\.? ', 'laminação ', 'gi'), ' FR\M', ' frente', 'gi'), ' VR\M', ' verso', 'gi'), 'CAL\. ', 'calandrado ', 'gi')) as x) t
$$;

create or replace function private.fu_texto_anuncio(p_conv uuid, p_nome text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_head text; v_h text; v_cat text; v_q integer; v_t text; v_linhas text;
begin
  select coalesce(nullif(cv.last_referral ->> 'headline', ''), nullif(ct.first_referral ->> 'headline', '')) into v_head
    from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conv;
  if v_head is null then return null; end if;
  v_h := private.texto_norm(v_head);

  if v_h like '%crach%' then
    return format('Oi, %s! Vi que você veio pelo nosso anúncio de %s. Pra eu te mostrar as opções certas: você prefere o crachá na vertical ou na horizontal?', p_nome, lower(v_head));
  end if;

  v_cat := case
    when v_h ~ 'cart(ao|oes).*visita|visita' then 'CARTÕES DE VISITA'
    when v_h ~ 'panfleto|flyer|folheto' then 'PANFLETOS, FLYERS E FOLHETOS'
    else (select c.categoria from public.catalogo c
           where c.active and c.vendavel and c.preco_venda is not null and v_h like '%' || split_part(private.texto_norm(c.categoria), ' ', 1) || '%' limit 1) end;
  if v_cat is null then
    return format('Oi, %s! Vi que você veio pelo nosso anúncio de %s. Me conta qual quantidade você precisa que eu já te passo as opções e os valores certinhos.', p_nome, lower(v_head));
  end if;

  select mode() within group (order by quantidade) into v_q from public.catalogo where categoria = v_cat and active and vendavel and preco_venda is not null;
  select mode() within group (order by tamanho_mm) into v_t from public.catalogo where categoria = v_cat and quantidade = v_q and active and vendavel and preco_venda is not null;

  with g as (
    select distinct on (x.descricao, x.cores)
           private.desc_publica(x.descricao) || case x.cores
             when '4X0' then ', colorido na frente' when '4X4' then ', colorido frente e verso' when '4X1' then ', colorido na frente e uma cor no verso'
             when '1X0' then ', uma cor na frente' when '1X1' then ', uma cor frente e verso' else '' end as texto,
           (public.calcular_preco(x.sku, 1, '{}'::jsonb) ->> 'preco_total')::numeric as preco
      from public.catalogo x
     where x.categoria = v_cat and x.quantidade = v_q and x.tamanho_mm is not distinct from v_t and x.active and x.vendavel and x.preco_venda is not null
     order by x.descricao, x.cores, x.preco_venda),
  rk as (select g.*, row_number() over (order by g.preco) as rn, count(*) over () as n from g where g.preco is not null)
  select string_agg(E'\n• ' || rk.texto || ': ' || private.brl(rk.preco), '' order by rk.preco) into v_linhas
    from rk where rk.n <= 5 or rk.rn in (1, 1 + (rk.n - 1) / 4, 1 + (rk.n - 1) / 2, 1 + (3 * (rk.n - 1)) / 4, rk.n);
  if v_linhas is null then return null; end if;
  return format('Oi, %s! Vi que você veio pelo nosso anúncio de %s. Separei algumas opções de %s unidades (%s mm), da mais em conta à mais completa:%s' || E'\n\n' || 'O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros. Qual dessas faz mais sentido pra você?',
                p_nome, lower(v_head), v_q, coalesce(v_t, 'padrão'), v_linhas);
end $$;
revoke all on function private.fu_texto_anuncio(uuid, text) from public, anon, authenticated;
