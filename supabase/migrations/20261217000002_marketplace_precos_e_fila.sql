-- Marketplaces (Mercado Livre e Shopee) pelo Bling: preço por canal com lucro líquido mínimo e fila de vínculos.
-- Aditiva e idempotente. Custo continua fechado: a função só é executável pela service role.
update public.app_settings
   set value = value || jsonb_build_object(
     'lucro_liquido_min', 50,
     'imposto_pct', 6,
     'ml_limite_frete_gratis', 79,
     -- ESTIMATIVA do custo de frete grátis no Mercado Envios por faixa de peso (kg). Conferir com uma cotação real.
     'frete_ml_estimado', jsonb_build_array(
        jsonb_build_object('ate_kg', 0.3, 'valor', 22), jsonb_build_object('ate_kg', 0.5, 'valor', 24),
        jsonb_build_object('ate_kg', 1, 'valor', 28), jsonb_build_object('ate_kg', 2, 'valor', 33),
        jsonb_build_object('ate_kg', 5, 'valor', 45), jsonb_build_object('ate_kg', 999, 'valor', 60)))
 where key = 'marketplaces';

create or replace function public.marketplace_preco_sku(p_sku text, p_canal text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c record; cfg jsonb; canal jsonb; lucro numeric; imp numeric; com numeric; fixa numeric; frete numeric := 0; limite numeric;
  preco numeric; dias int;
begin
  select * into c from public.catalogo where sku = p_sku;
  if not found or c.custo is null then return jsonb_build_object('erro', 'sku_sem_custo'); end if;
  select value into cfg from public.app_settings where key = 'marketplaces';
  canal := cfg -> p_canal;
  if canal is null then return jsonb_build_object('erro', 'canal_invalido'); end if;
  lucro := coalesce((cfg ->> 'lucro_liquido_min')::numeric, 50);
  imp := coalesce((cfg ->> 'imposto_pct')::numeric, 6) / 100;
  com := (canal ->> 'comissao_pct')::numeric / 100;
  fixa := coalesce((canal ->> 'taxa_fixa')::numeric, 0);
  limite := coalesce((cfg ->> 'ml_limite_frete_gratis')::numeric, 79);
  dias := coalesce(c.prazo_cliente_dias, c.prazo_dias_uteis, 3) + coalesce((canal ->> 'prazo_extra_dias')::int, 2);
  preco := (c.custo + lucro + fixa) / (1 - com - imp);
  if p_canal = 'mercado_livre' and preco >= limite then
    select (x ->> 'valor')::numeric into frete from jsonb_array_elements(cfg -> 'frete_ml_estimado') x
     where coalesce(c.peso_frete_kg, 0) <= (x ->> 'ate_kg')::numeric order by (x ->> 'ate_kg')::numeric limit 1;
    preco := (c.custo + lucro + coalesce(frete, 0)) / (1 - com - imp);
    fixa := 0;
  end if;
  preco := greatest(private.teto_90(preco), coalesce(c.preco_venda, 0));
  return jsonb_build_object('preco', preco, 'frete_estimado', coalesce(frete, 0), 'dias_preparacao', dias,
    'lucro_liquido', round(preco * (1 - com - imp) - fixa - coalesce(frete, 0) - c.custo, 2));
end $$;
revoke all on function public.marketplace_preco_sku(text, text) from public, anon, authenticated;
grant execute on function public.marketplace_preco_sku(text, text) to service_role;

create table if not exists public.marketplace_anuncios (
  id uuid primary key default gen_random_uuid(),
  sku text not null,
  canal text not null check (canal in ('mercado_livre', 'shopee')),
  bling_produto_id bigint not null,
  preco numeric(12, 2) not null,
  dias_preparacao int not null default 5,
  status text not null default 'pendente' check (status in ('pendente', 'ok', 'erro')),
  vinculo_id bigint,
  tentativas int not null default 0,
  erro text,
  atualizado_em timestamptz not null default now(),
  unique (sku, canal)
);
alter table public.marketplace_anuncios enable row level security;
revoke all on public.marketplace_anuncios from anon, authenticated;
