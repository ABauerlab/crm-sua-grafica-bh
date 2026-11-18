-- 18/11/2026: o checkout sugeria sempre o mesmo produto (Cartões de Visita PVC) porque só havia 6 regras por categoria e,
-- fora delas, caía num fallback fixo. Agora: tabela de combinações por TIPO de produto (editável), pelo menos 5 sugestões
-- diferentes, escolha do item por faixa de preço (um complemento acessível, não o mais parecido nem o mais caro) e variação entre pedidos.
-- Aditiva e idempotente.

create table if not exists public.checkout_combinacoes (
  id uuid primary key default gen_random_uuid(),
  origem text not null,              -- expressão regular testada nas categorias do pedido ('.*' = qualquer pedido)
  destino text not null,             -- categoria sugerida (categoria_slug da vitrine)
  motivo text not null,
  pontos integer not null default 5 check (pontos between 1 and 20),
  ativo boolean not null default true,
  unique (origem, destino)
);
alter table public.checkout_combinacoes enable row level security;
revoke all on public.checkout_combinacoes from anon;
drop policy if exists checkout_combinacoes_select on public.checkout_combinacoes;
create policy checkout_combinacoes_select on public.checkout_combinacoes for select to authenticated using (private.is_staff());
drop policy if exists checkout_combinacoes_escrita on public.checkout_combinacoes;
create policy checkout_combinacoes_escrita on public.checkout_combinacoes for all to authenticated using (private.is_admin()) with check (private.is_admin());

insert into public.checkout_combinacoes (origem, destino, motivo, pontos) values
  -- cartões
  ('cartoes|cartao|mini-cartao', 'pastas', 'Cartão e pasta andam juntos: apresente sua empresa por completo.', 10),
  ('cartoes|cartao|mini-cartao', 'adesivos', 'Um adesivo da sua marca em cada entrega faz o cliente lembrar de você.', 9),
  ('cartoes|cartao|mini-cartao', 'cartoes-fidelidade', 'Cartão fidelidade faz o cliente voltar: mais vendas com o mesmo cliente.', 8),
  ('cartoes|cartao|mini-cartao', 'envelopes', 'Envelope com a sua marca para enviar propostas.', 7),
  ('cartoes|cartao|mini-cartao', 'marcador-de-pagina', 'Marcador de página: brinde barato que o cliente guarda.', 6),
  ('cartoes|cartao|mini-cartao', 'imas-de-geladeira', 'Ímã de geladeira deixa o seu contato à vista todo dia.', 6),
  -- crachás e credenciais
  ('cracha|credenciais|cordoes|porta-documentos|pulseiras', 'cordoes', 'O cordão é o que deixa o crachá pronto para usar.', 10),
  ('cracha|credenciais|cordoes|porta-documentos|pulseiras', 'porta-documentos', 'Porta-crachá protege o documento e dá acabamento.', 9),
  ('cracha|credenciais|cordoes|porta-documentos|pulseiras', 'cartoes-de-visita', 'Quem usa crachá também distribui cartão de visita.', 8),
  ('cracha|credenciais|cordoes|porta-documentos|pulseiras', 'canetas-promocionais', 'Caneta personalizada para a equipe e para brindar clientes.', 7),
  ('cracha|credenciais|cordoes|porta-documentos|pulseiras', 'agendas-cadernos-e-apostilas', 'Agenda com a marca da empresa para a equipe.', 6),
  ('cracha|credenciais|cordoes|porta-documentos|pulseiras', 'bottons-e-pins-personalizados', 'Botton da marca para completar o uniforme.', 5),
  -- panfletos
  ('panfleto|filipeta|folhas|folders|mini-panfleto|encarte', 'banners-faixas-lonas-e-tecidos', 'Panfleto convida, banner chama a atenção na porta do seu negócio.', 10),
  ('panfleto|filipeta|folhas|folders|mini-panfleto|encarte', 'cartoes-de-visita', 'Quem pega o panfleto leva o seu cartão para ligar depois.', 9),
  ('panfleto|filipeta|folhas|folders|mini-panfleto|encarte', 'adesivos', 'Adesivo da sua marca para colar no que você entrega.', 8),
  ('panfleto|filipeta|folhas|folders|mini-panfleto|encarte', 'imas-de-geladeira', 'Ímã de geladeira: o cliente guarda o seu contato.', 7),
  ('panfleto|filipeta|folhas|folders|mini-panfleto|encarte', 'cartazes', 'Cartaz para reforçar a divulgação no ponto de venda.', 6),
  -- adesivos e rótulos
  ('adesivo|rotulo', 'sacolas-e-sacos', 'Leve sacolas com a sua marca e entregue o adesivo com mais charme.', 10),
  ('adesivo|rotulo', 'cartoes-de-visita', 'Adesivo chama atenção, o cartão fecha o contato.', 9),
  ('adesivo|rotulo', 'tags', 'Tags para etiquetar e deixar o produto com cara de loja.', 8),
  ('adesivo|rotulo', 'caixas-e-embalagens', 'Caixa personalizada para o produto chegar bonito.', 7),
  ('adesivo|rotulo', 'cartoes-fidelidade', 'Cartão fidelidade para o cliente voltar.', 6),
  -- banners e sinalização
  ('banner|lona|faixa|wind|roll-up|cavalete|totens|bandeira|displays|cartazes', 'cartoes-de-visita', 'Quem vê o banner leva o seu cartão no bolso.', 10),
  ('banner|lona|faixa|wind|roll-up|cavalete|totens|bandeira|displays|cartazes', 'panfletos-flyers-e-folhetos', 'Banner na porta e panfleto na mão: divulgação completa.', 9),
  ('banner|lona|faixa|wind|roll-up|cavalete|totens|bandeira|displays|cartazes', 'adesivos', 'Adesivos da marca para reforçar a identidade do espaço.', 7),
  ('banner|lona|faixa|wind|roll-up|cavalete|totens|bandeira|displays|cartazes', 'bandeirolas', 'Bandeirolas para dar clima de promoção.', 6),
  ('banner|lona|faixa|wind|roll-up|cavalete|totens|bandeira|displays|cartazes', 'imas-de-geladeira', 'Ímã para o cliente levar o seu contato.', 5),
  -- papelaria institucional
  ('pasta|papel-timbrado|envelopes|capas|solapas|certificados', 'cartoes-de-visita', 'Pasta pronta merece o cartão de visita para acompanhar.', 10),
  ('pasta|papel-timbrado|envelopes|capas|solapas|certificados', 'envelopes', 'Envelope com a sua marca para enviar propostas.', 9),
  ('pasta|papel-timbrado|envelopes|capas|solapas|certificados', 'papel-timbrado', 'Papel timbrado completa a identidade da empresa.', 8),
  ('pasta|papel-timbrado|envelopes|capas|solapas|certificados', 'canetas-promocionais', 'Caneta com a sua marca para assinar o fechamento.', 7),
  ('pasta|papel-timbrado|envelopes|capas|solapas|certificados', 'agendas-cadernos-e-apostilas', 'Agenda personalizada para presentear clientes.', 6),
  -- embalagens e delivery
  ('sacola|caixa|embalagem|tags|delivery|potes|forro|canudos|cinta', 'adesivos', 'Feche a embalagem com um adesivo da sua marca.', 10),
  ('sacola|caixa|embalagem|tags|delivery|potes|forro|canudos|cinta', 'tags', 'Tags com a sua marca deixam a embalagem mais bonita.', 9),
  ('sacola|caixa|embalagem|tags|delivery|potes|forro|canudos|cinta', 'cartoes-de-visita', 'Um cartão dentro de cada embalagem aproxima o cliente.', 8),
  ('sacola|caixa|embalagem|tags|delivery|potes|forro|canudos|cinta', 'cartoes-fidelidade', 'Cartão fidelidade na sacola faz o cliente voltar.', 7),
  ('sacola|caixa|embalagem|tags|delivery|potes|forro|canudos|cinta', 'fita-de-cetim', 'Fita de cetim para o acabamento do pacote.', 5),
  -- cardápios e comandas
  ('cardapios|blocos-comandas|porta-copos|carnes|ficha', 'delivery', 'Peças de delivery para vender também fora do salão.', 10),
  ('cardapios|blocos-comandas|porta-copos|carnes|ficha', 'adesivos', 'Adesivos para lacrar e identificar os pedidos.', 9),
  ('cardapios|blocos-comandas|porta-copos|carnes|ficha', 'sacolas-e-sacos', 'Sacolas com a sua marca para entrega.', 8),
  ('cardapios|blocos-comandas|porta-copos|carnes|ficha', 'cartoes-fidelidade', 'Cartão fidelidade para o cliente voltar sempre.', 7),
  ('cardapios|blocos-comandas|porta-copos|carnes|ficha', 'imas-de-geladeira', 'Ímã com o seu contato para pedidos.', 6),
  -- brindes
  ('canetas|caneca|garrafas|abridores|chaveiros|celular|reguas|estojos|bottons|borrachas|lapis|trena', 'sacolas-e-sacos', 'Entregue os brindes em sacolas da sua marca.', 10),
  ('canetas|caneca|garrafas|abridores|chaveiros|celular|reguas|estojos|bottons|borrachas|lapis|trena', 'cartoes-de-visita', 'Cartão de visita junto de cada brinde.', 9),
  ('canetas|caneca|garrafas|abridores|chaveiros|celular|reguas|estojos|bottons|borrachas|lapis|trena', 'adesivos', 'Adesivos da marca para completar o kit.', 8),
  ('canetas|caneca|garrafas|abridores|chaveiros|celular|reguas|estojos|bottons|borrachas|lapis|trena', 'agendas-cadernos-e-apostilas', 'Agenda para montar um kit de brindes completo.', 7),
  ('canetas|caneca|garrafas|abridores|chaveiros|celular|reguas|estojos|bottons|borrachas|lapis|trena', 'tags', 'Tags para embalar e identificar o brinde.', 6),
  -- decoração, fotos e papelaria criativa
  ('quadro|foto-produtos|postais|placas|poster|almofada|azulejos|espelho|luminarias|moldura', 'postais', 'Postais para presentear e divulgar a marca.', 9),
  ('quadro|foto-produtos|postais|placas|poster|almofada|azulejos|espelho|luminarias|moldura', 'imas-de-geladeira', 'Ímãs combinando com a decoração.', 8),
  ('quadro|foto-produtos|postais|placas|poster|almofada|azulejos|espelho|luminarias|moldura', 'cartoes-de-visita', 'Cartão de visita para quem se encantar com a peça.', 8),
  ('quadro|foto-produtos|postais|placas|poster|almofada|azulejos|espelho|luminarias|moldura', 'calendarios-e-folhinhas-2027', 'Calendário 2027 personalizado: presente que dura o ano todo.', 7),
  ('quadro|foto-produtos|postais|placas|poster|almofada|azulejos|espelho|luminarias|moldura', 'adesivos', 'Adesivos para personalizar mais peças.', 6),
  -- festas e convites
  ('convites|festa|painel|cilindros|balde|baralhos|ventarola', 'convites', 'Convites combinando com a decoração.', 9),
  ('convites|festa|painel|cilindros|balde|baralhos|ventarola', 'tags', 'Tags para lembrancinhas e embalagens.', 8),
  ('convites|festa|painel|cilindros|balde|baralhos|ventarola', 'adesivos', 'Adesivos para as lembrancinhas.', 8),
  ('convites|festa|painel|cilindros|balde|baralhos|ventarola', 'sacolas-e-sacos', 'Sacolinhas para entregar as lembrancinhas.', 7),
  ('convites|festa|painel|cilindros|balde|baralhos|ventarola', 'bandeirolas', 'Bandeirolas para a decoração.', 6),
  -- calendários, agendas e revistas
  ('calendarios|agendas|revista|catalogo|marcador|cd-e-dvd', 'canetas-promocionais', 'Caneta combinando com a agenda ou o calendário.', 9),
  ('calendarios|agendas|revista|catalogo|marcador|cd-e-dvd', 'cartoes-de-visita', 'Cartão de visita para acompanhar o material.', 8),
  ('calendarios|agendas|revista|catalogo|marcador|cd-e-dvd', 'marcador-de-pagina', 'Marcador de página: brinde barato e útil.', 7),
  ('calendarios|agendas|revista|catalogo|marcador|cd-e-dvd', 'adesivos', 'Adesivos da marca para fechar o kit.', 6),
  -- vestuário e outros: vale para qualquer pedido (pontos baixos)
  ('.*', 'cartoes-de-visita', 'O cartão de visita combina com qualquer pedido.', 4),
  ('.*', 'adesivos', 'Adesivo da sua marca: barato e aparece em todo lugar.', 4),
  ('.*', 'tags', 'Tags para identificar e embalar seus produtos.', 3),
  ('.*', 'sacolas-e-sacos', 'Sacolas com a sua marca para entregar o pedido.', 3),
  ('.*', 'canetas-promocionais', 'Canetas personalizadas para brindar clientes.', 3),
  ('.*', 'calendarios-e-folhinhas-2027', 'Calendário 2027: presente que dura o ano inteiro.', 3),
  ('.*', 'imas-de-geladeira', 'Ímã de geladeira: o cliente guarda o seu contato.', 2),
  ('.*', 'cartoes-fidelidade', 'Cartão fidelidade para o cliente voltar.', 2),
  ('.*', 'bottons-e-pins-personalizados', 'Bottons para divulgar a sua marca.', 2),
  ('.*', 'postais', 'Postais para agradecer e divulgar.', 2)
on conflict (origem, destino) do nothing;

create or replace function private.checkout_sugestoes(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_contact uuid; v_conv uuid; v_cats text[]; v_base numeric; v_texto text; v_alvo numeric; v_slugs text[]; v_titulos text[];
  v_out jsonb := '[]'::jsonb; v_n integer := 0; v_cands jsonb; c jsonb; p record; v_rodada integer;
begin
  select contact_id, conversation_id into v_contact, v_conv from public.orders where id = p_order;
  select coalesce(array_agg(distinct e.categoria_slug), '{}'), coalesce(array_agg(distinct e.produto_slug), '{}'), coalesce(array_agg(distinct e.titulo), '{}')
    into v_cats, v_slugs, v_titulos
    from public.order_items oi join public.ecommerce_products e on e.sku = oi.code where oi.order_id = p_order;
  select coalesce(sum(qty * unit_price), 0) into v_base from public.order_items where order_id = p_order and description !~* '^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)';
  -- complemento acessível: perto de 35% do pedido, entre R$ 50 e R$ 400
  v_alvo := greatest(50, least(v_base * 0.35, 400));
  select lower(coalesce(string_agg(body, ' '), '')) into v_texto from (
    select body from public.messages where conversation_id = v_conv and direction = 'in' and deleted_at is null and body is not null
       and created_at > now() - interval '30 days' order by created_at desc limit 60) m;

  -- categorias candidatas: combinações do tipo de produto + o que o cliente citou na conversa + o que ele já comprou
  select coalesce(jsonb_agg(to_jsonb(t) order by t.pontos desc, t.h), '[]'::jsonb) into v_cands from (
    with casa as (
      select destino, (array_agg(motivo order by pontos desc))[1] as motivo, max(pontos) as pts, false as citou
        from public.checkout_combinacoes
       where ativo and exists (select 1 from unnest(v_cats) cc where cc ~ origem and origem <> '.*') group by destino),
    geral as (
      select destino, (array_agg(motivo order by pontos desc))[1] as motivo, max(pontos) as pts, false as citou
        from public.checkout_combinacoes where ativo and origem = '.*' group by destino),
    cit as (
      select m.destino, 'Você comentou isso na conversa: vale incluir no mesmo pedido.'::text as motivo, 6 as pts, true as citou
        from (values ('pastas', 'pasta'), ('adesivos', 'adesiv|r[oó]tulo'), ('cartoes-de-visita', 'cart[aã]o|cart[oõ]es'),
                     ('sacolas-e-sacos', 'sacola|sacos'), ('banners-faixas-lonas-e-tecidos', 'banner|lona|faixa'), ('tags', 'tag|etiqueta'),
                     ('envelopes', 'envelope'), ('cartoes-fidelidade', 'fidelidade'), ('canetas-promocionais', 'caneta|brinde'),
                     ('calendarios-e-folhinhas-2027', 'calend[aá]rio'), ('imas-de-geladeira', '[ií]m[aã]')) m(destino, termo)
       where v_texto ~ m.termo),
    todas as (
      select destino, (array_agg(motivo order by pts desc))[1] as motivo, sum(pts) as pts, bool_or(citou) as citou
        from (select * from casa union all select * from geral union all select * from cit) x group by destino)
    select t.destino, t.motivo, t.citou, h.comprou, t.pts + case when h.comprou then 4 else 0 end as pontos, hashtext(p_order::text || t.destino) as h
      from todas t
      cross join lateral (select exists (select 1 from public.orders o2 join public.order_items i2 on i2.order_id = o2.id
                                           join public.ecommerce_products e2 on e2.sku = i2.code
                                          where o2.contact_id = v_contact and o2.payment_status = 'aprovado' and e2.categoria_slug = t.destino) as comprou) h
     where not (t.destino = any (v_cats))
       and not exists (select 1 from public.order_items i3 join public.ecommerce_products e3 on e3.sku = i3.code where i3.order_id = p_order and i3.checkout_extra and e3.categoria_slug = t.destino)
     order by pontos desc, h
     limit 14) t;

  -- rodada 1: um produto por categoria; rodada 2 (se faltar para 5): um segundo produto das melhores categorias
  for v_rodada in 1..2 loop
    for c in select * from jsonb_array_elements(v_cands) loop
      exit when v_n >= 6 or (v_rodada = 2 and v_n >= 5);
      select e.ref, e.sku_slug, e.titulo, e.variante, e.quantidade, e.preco, e.parcela_2x, e.prazo_dias_uteis, e.fotos ->> 0 as foto, e.produto_slug into p
        from public.ecommerce_products e
       where e.categoria_slug = c ->> 'destino' and e.ativo and e.preco between 15 and 900
         and e.produto_slug <> all (v_slugs) and left(e.titulo, 12) <> all (select left(t, 12) from unnest(v_titulos) t) and e.fotos <> '[]'::jsonb
       order by abs(e.preco - v_alvo), hashtext(p_order::text || e.sku)
       limit 1;
      if found then
        v_slugs := v_slugs || p.produto_slug; v_titulos := v_titulos || p.titulo; v_n := v_n + 1;
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'ref', p.ref, 'slug', p.sku_slug, 'titulo', p.titulo || coalesce(' · ' || p.variante, ''), 'quantidade', p.quantidade,
          'preco', p.preco, 'parcela_2x', p.parcela_2x, 'prazo_dias_uteis', p.prazo_dias_uteis, 'foto', p.foto,
          'motivo', c ->> 'motivo',
          'selo', case when (c ->> 'citou')::boolean then 'Você comentou na conversa' when (c ->> 'comprou')::boolean then 'Reposição' else 'Combina com o seu pedido' end));
      end if;
    end loop;
  end loop;
  return v_out;
end;
$$;
revoke all on function private.checkout_sugestoes(uuid) from public, anon, authenticated;
