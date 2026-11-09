-- E-commerce Fase 9: checkout em 3 passos, carrinho abandonado, frete grátis só nos 7 bairros, base do SuperFrete e status do Pix.
-- Aditiva e idempotente.

-- 1) Cache CEP -> bairro (preenchido pela Edge Function loja-frete a partir de uma consulta pública de CEP).
create table if not exists public.cep_bairros (
  cep text primary key check (cep ~ '^[0-9]{8}$'),
  logradouro text,
  bairro text,
  cidade text,
  uf text,
  fonte text not null default 'viacep',
  atualizado_em timestamptz not null default now()
);
alter table public.cep_bairros enable row level security;
revoke all on public.cep_bairros from anon, authenticated;

-- 2) Frete grátis só nos bairros ativos de zonas_frete_gratis (7 hoje). Com o CEP no cache, vale o bairro (e a cidade
--    precisa ser Belo Horizonte, porque "Centro" existe em toda cidade). CEP fora do cache segue a faixa antiga (Laura).
create or replace function public.verificar_frete(p_cep_ou_bairro text, p_itens jsonb default '[]'::jsonb, p_valor_pedido numeric default 0, p_pacote_arte boolean default false)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_txt text := coalesce(p_cep_ou_bairro, '');
  v_cep text := regexp_replace(coalesce(p_cep_ou_bairro, ''), '\D', '', 'g');
  v_zona boolean := false;
  v_origem text;
  v_cache record;
  it jsonb; prod record;
  v_peso numeric := 0; v_lado numeric := 0; v_desconhecido boolean := false; v_qtd integer;
  v_cabe boolean; v_elegivel_tamanho boolean; v_minimo_ok boolean; v_gratis boolean;
  v_motivo text; v_opcoes jsonb := '[]'::jsonb;
  v_sku_in text;
begin
  select * into pr from public.parametros_comerciais where id = 1;

  if v_txt ~ '^\s*\d{5}-?\d{3}\s*$' then
    v_origem := 'cep';
    select bairro, cidade, uf into v_cache from public.cep_bairros where cep = v_cep;
    if found and v_cache.bairro is not null then
      v_origem := 'cep_bairro';
      v_zona := private.norm_txt(coalesce(v_cache.cidade, '')) = 'belo horizonte' and coalesce(upper(v_cache.uf), 'MG') = 'MG'
        and exists (select 1 from public.zonas_frete_gratis z where z.ativo and z.tipo = 'bairro' and private.norm_txt(z.bairro) = private.norm_txt(v_cache.bairro));
    else
      v_zona := exists (select 1 from public.zonas_frete_gratis z where z.ativo and z.tipo = 'cep' and v_cep between z.cep_inicio and z.cep_fim);
    end if;
  else
    v_origem := 'bairro';
    v_zona := exists (select 1 from public.zonas_frete_gratis z
                      where z.ativo and z.tipo = 'bairro'
                        and private.norm_txt(z.bairro) = regexp_replace(private.norm_txt(v_txt), '^bairro ', ''));
  end if;

  if jsonb_typeof(p_itens) = 'array' then
    for it in select * from jsonb_array_elements(p_itens) loop
      v_sku_in := nullif(btrim(coalesce(it ->> 'sku', '')), '');
      if v_sku_in is null then v_desconhecido := true; continue; end if;
      select c.peso_g, c.maior_lado_mm, c.quantidade into prod from public.catalogo c where c.sku = upper(v_sku_in);
      if not found then v_desconhecido := true; continue; end if;
      v_qtd := greatest(coalesce((it ->> 'quantidade')::integer, 1), 1);
      if coalesce(prod.quantidade, 1) >= 5 and v_qtd >= prod.quantidade and mod(v_qtd, prod.quantidade) = 0 then
        v_qtd := v_qtd / prod.quantidade;
      end if;
      v_peso := v_peso + coalesce(prod.peso_g, 0) * v_qtd;
      if coalesce(prod.peso_g, 0) <= 0 or prod.maior_lado_mm is null then v_desconhecido := true;
      else v_lado := greatest(v_lado, prod.maior_lado_mm); end if;
    end loop;
  end if;

  v_cabe := not v_desconhecido and v_peso <= pr.peso_max_bike_g and v_lado <= pr.lado_max_bike_mm;
  v_elegivel_tamanho := (not pr.exigir_cabe_na_bike) or v_cabe;
  v_minimo_ok := coalesce(p_pacote_arte, false) or coalesce(p_valor_pedido, 0) >= pr.pedido_minimo_frete_gratis;
  v_gratis := v_zona and v_elegivel_tamanho and v_minimo_ok;
  v_motivo := case
    when v_gratis then 'frete_gratis_regiao_central'
    when not v_zona then 'fora_da_regiao_central'
    when not v_elegivel_tamanho then case when v_desconhecido then 'dimensao_desconhecida' else 'nao_cabe_na_bike' end
    else 'abaixo_do_pedido_minimo' end;

  v_opcoes := jsonb_build_array(jsonb_build_object('tipo', 'retirada', 'valor_cliente', 0, 'obs', 'retirada grátis no centro de BH'));
  if v_gratis then
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'bike', 'valor_cliente', 0, 'obs', 'entrega grátis na região central, em horário comercial'));
  else
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'uber', 'valor_cliente', pr.custo_entrega_uber, 'obs', 'Uber Entrega por conta do cliente (valor de referência)'));
  end if;

  return jsonb_build_object(
    'ok', true, 'origem_consulta', v_origem, 'regiao_central', v_zona,
    'cabe_na_bike', v_cabe, 'peso_total_g', v_peso, 'maior_lado_mm', v_lado, 'dimensao_desconhecida', v_desconhecido,
    'pedido_minimo', pr.pedido_minimo_frete_gratis, 'pedido_minimo_atingido', v_minimo_ok, 'pacote_arte', coalesce(p_pacote_arte, false),
    'falta_para_frete_gratis', case when v_minimo_ok then 0 else greatest(pr.pedido_minimo_frete_gratis - coalesce(p_valor_pedido, 0), 0) end,
    'frete_gratis', v_gratis,
    'valor_frete_cliente', case when v_gratis then 0 else pr.custo_entrega_uber end,
    'frete_estimado', not v_gratis,
    'custo_entrega_nosso', case when v_gratis then pr.custo_entrega_bike else 0 end,
    'entrega_sugerida', case when v_gratis then 'bike' else 'uber' end,
    'saidas_bike_por_dia', pr.saidas_bike_por_dia,
    'motivo', v_motivo, 'opcoes', v_opcoes);
end;
$$;

-- 3) Dados de frete para a Edge Function loja-frete (só service role): cotação pública do site + pacotes por produto.
--    Dimensões vêm de catalogo.embalagem_cm ("16 x 11 x 60"); a menor medida é empilhada pelo número de lotes.
create or replace function public.loja_frete_base(p_itens jsonb, p_arte text, p_cep text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_calc jsonb; it jsonb; v_sku text; v_lotes integer; c record; d numeric[]; v_pacotes jsonb := '[]'::jsonb; v_ok boolean := true;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  v_calc := public.loja_calcular(p_itens, p_arte, p_cep);
  if not coalesce((v_calc ->> 'ok')::boolean, false) then return v_calc; end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := private.loja_sku(it ->> 'ref');
    v_lotes := least(greatest(coalesce(nullif(it ->> 'quantidade', '')::integer, 1), 1), 100);
    select peso_frete_kg, embalagem_cm into c from public.catalogo where sku = v_sku;
    d := null;
    if c.embalagem_cm ~ '^\s*[0-9]+([.,][0-9]+)?\s*[xX]\s*[0-9]+([.,][0-9]+)?\s*[xX]\s*[0-9]+([.,][0-9]+)?\s*$' then
      select array_agg(replace(x, ',', '.')::numeric order by replace(x, ',', '.')::numeric)
        into d from regexp_split_to_table(regexp_replace(c.embalagem_cm, '\s', '', 'g'), '[xX]') x;
    end if;
    if d is null or coalesce(c.peso_frete_kg, 0) <= 0 then v_ok := false; continue; end if;
    v_pacotes := v_pacotes || jsonb_build_array(jsonb_build_object(
      'peso_kg', round(c.peso_frete_kg * v_lotes, 3), 'altura_cm', d[1] * v_lotes, 'largura_cm', d[2], 'comprimento_cm', d[3]));
  end loop;
  return v_calc || jsonb_build_object('pacotes', case when v_ok then v_pacotes end, 'pacotes_ok', v_ok);
end $$;
revoke all on function public.loja_frete_base(jsonb, text, text) from public, anon, authenticated;
grant execute on function public.loja_frete_base(jsonb, text, text) to service_role;

-- 4) Carrinho abandonado: gravado pelo site (sem preço vindo do navegador), recuperado quando o pedido é criado.
create table if not exists public.carrinhos_abandonados (
  id uuid primary key default gen_random_uuid(),
  sessao text not null unique check (sessao ~ '^[a-zA-Z0-9-]{16,64}$'),
  whatsapp text,
  nome text,
  email text,
  itens jsonb not null,
  arte text not null default 'pronta',
  entrega text not null default 'retirada',
  cep text,
  total numeric(10,2),
  status text not null default 'aberto' check (status in ('aberto', 'recuperado', 'avisado', 'descartado')),
  pedido_id uuid references public.orders(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  avisado_em timestamptz
);
create index if not exists carrinhos_abandonados_status_idx on public.carrinhos_abandonados (status, atualizado_em);
alter table public.carrinhos_abandonados enable row level security;
drop policy if exists carrinhos_staff_ler on public.carrinhos_abandonados;
create policy carrinhos_staff_ler on public.carrinhos_abandonados for select to authenticated using (private.is_staff());
drop policy if exists carrinhos_staff_atualizar on public.carrinhos_abandonados;
create policy carrinhos_staff_atualizar on public.carrinhos_abandonados for update to authenticated using (private.is_staff()) with check (private.is_staff());
revoke all on public.carrinhos_abandonados from anon;

create or replace function public.loja_carrinho_salvar(p_sessao text, p_cliente jsonb, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_wa text := regexp_replace(coalesce(p_cliente ->> 'whatsapp', ''), '\D', '', 'g');
  v_arte text := coalesce(nullif(p_opcoes ->> 'arte', ''), 'pronta');
  v_ent text := case when p_opcoes ->> 'entrega' = 'entrega' then 'entrega' else 'retirada' end;
  v_cep text := nullif(regexp_replace(coalesce(p_opcoes ->> 'cep', ''), '\D', '', 'g'), '');
  v_email text := nullif(lower(btrim(coalesce(p_cliente ->> 'email', ''))), '');
  v_calc jsonb; v_atual public.carrinhos_abandonados%rowtype;
begin
  if coalesce(p_sessao, '') !~ '^[a-zA-Z0-9-]{16,64}$' then return jsonb_build_object('ok', false, 'erro', 'sessao_invalida'); end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then return jsonb_build_object('ok', false, 'erro', 'itens_invalidos'); end if;
  if length(v_wa) in (10, 11) then v_wa := '55' || v_wa; end if;
  if v_wa !~ '^55[1-9][0-9]9?[0-9]{8}$' then v_wa := null; end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then v_email := null; end if;
  if v_cep is not null and v_cep !~ '^[0-9]{8}$' then v_cep := null; end if;
  v_calc := public.loja_calcular(p_itens, v_arte, null);
  if not coalesce((v_calc ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', coalesce(v_calc ->> 'erro', 'itens_invalidos')); end if;
  select * into v_atual from public.carrinhos_abandonados where sessao = p_sessao;
  if found then
    if v_atual.status = 'recuperado' then return jsonb_build_object('ok', true, 'recuperado', true); end if;
    update public.carrinhos_abandonados set
      whatsapp = coalesce(v_wa, whatsapp), nome = coalesce(nullif(left(btrim(coalesce(p_cliente ->> 'nome', '')), 120), ''), nome),
      email = coalesce(v_email, email), itens = p_itens, arte = v_arte, entrega = v_ent, cep = coalesce(v_cep, cep),
      total = (v_calc ->> 'total')::numeric, status = 'aberto', atualizado_em = now()
    where id = v_atual.id;
  else
    if (select count(*) from public.carrinhos_abandonados where criado_em > now() - interval '1 hour') >= 300 then
      return jsonb_build_object('ok', false, 'erro', 'muitas_tentativas');
    end if;
    insert into public.carrinhos_abandonados (sessao, whatsapp, nome, email, itens, arte, entrega, cep, total)
    values (p_sessao, v_wa, nullif(left(btrim(coalesce(p_cliente ->> 'nome', '')), 120), ''), v_email, p_itens, v_arte, v_ent, v_cep, (v_calc ->> 'total')::numeric);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.loja_carrinho_salvar(text, jsonb, jsonb, jsonb) from public;
grant execute on function public.loja_carrinho_salvar(text, jsonb, jsonb, jsonb) to anon, authenticated, service_role;

-- Marca como recuperado quando o pedido nasce (por sessão ou pelo WhatsApp). Só service role.
create or replace function public.loja_carrinho_fechar(p_sessao text, p_whatsapp text, p_pedido uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.carrinhos_abandonados set status = 'recuperado', pedido_id = p_pedido, atualizado_em = now()
   where status in ('aberto', 'avisado') and (sessao = p_sessao or (p_whatsapp is not null and whatsapp = p_whatsapp));
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.loja_carrinho_fechar(text, text, uuid) from public, anon, authenticated;
grant execute on function public.loja_carrinho_fechar(text, text, uuid) to service_role;

-- Fila de recuperação: carrinhos com WhatsApp parados há 15 min (até 24 h), sem pedido. "pode_enviar" só é verdadeiro
-- com consentimento de promoções (regra do dono) ou conversa aberta nas últimas 24 h (mensagem livre).
create or replace view public.v_carrinhos_recuperar with (security_invoker = true) as
select c.id, c.whatsapp, c.nome, c.total, c.itens, c.atualizado_em,
       (ct.marketing_consent = 'opted_in') as consentiu,
       exists (select 1 from public.conversations cv where cv.contact_id = ct.id and cv.last_inbound_at > now() - interval '24 hours') as janela_aberta
from public.carrinhos_abandonados c
left join public.contacts ct on ct.wa_id = c.whatsapp
where c.status = 'aberto' and c.whatsapp is not null
  and c.atualizado_em < now() - interval '15 minutes' and c.atualizado_em > now() - interval '24 hours';

-- 5) Status público e anônimo do pedido (o id é um UUID que só quem criou o pedido conhece): a tela do Pix consulta até pagar.
create or replace function public.loja_pedido_status(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object('ok', true, 'numero', o.number, 'pago', o.payment_status = 'aprovado')
                     from public.orders o where o.id = p_pedido and o.origin_label = 'site'),
                  jsonb_build_object('ok', false));
$$;
revoke all on function public.loja_pedido_status(uuid) from public;
grant execute on function public.loja_pedido_status(uuid) to anon, authenticated, service_role;
