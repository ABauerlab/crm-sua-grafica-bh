-- Bling: envio automático de todo pedido pago (a Edge Function bling-integracao faz as chamadas; o banco guarda fila e resultado).
-- Aditiva e idempotente.
alter table public.orders add column if not exists bling_tentativas integer not null default 0;
alter table public.orders add column if not exists bling_ultima_tentativa timestamptz;
alter table public.orders add column if not exists bling_aviso text;

-- Pedidos pagos que ainda não estão no Bling, respeitando espera crescente entre tentativas (5, 10, 20, 40, 80 min) e no máximo 6 tentativas.
create or replace function public.bling_pendentes(p_limite integer default 10)
returns table (order_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return query
    select o.id from public.orders o
     where o.payment_status = 'aprovado' and o.bling_pedido_id is null and coalesce(o.teste, false) = false
       and coalesce(o.paid_at, o.created_at) > now() - interval '60 days'
       and o.bling_tentativas < 6
       and (o.bling_ultima_tentativa is null or o.bling_ultima_tentativa < now() - make_interval(mins => 5 * (2 ^ o.bling_tentativas)::int))
     order by coalesce(o.paid_at, o.created_at)
     limit greatest(1, least(coalesce(p_limite, 10), 30));
end $$;

-- Resultado de uma tentativa. Sucesso grava o id do Bling; erro conta a tentativa.
create or replace function public.bling_resultado(p_order uuid, p_pedido_id text, p_contato_id text, p_erro text, p_aviso text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_t integer; v_contact uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_pedido_id is not null then
    update public.orders set bling_pedido_id = p_pedido_id, bling_enviado_em = now(), bling_erro = null, bling_aviso = left(p_aviso, 500),
           bling_ultima_tentativa = now(), bling_tentativas = bling_tentativas + 1
     where id = p_order returning contact_id into v_contact;
    if p_contato_id is not null then update public.contacts set bling_contact_id = p_contato_id where id = v_contact; end if;
    return jsonb_build_object('ok', true);
  end if;
  update public.orders set bling_erro = left(coalesce(p_erro, 'erro desconhecido'), 500), bling_ultima_tentativa = now(), bling_tentativas = bling_tentativas + 1
   where id = p_order returning bling_tentativas into v_t;
  return jsonb_build_object('ok', false, 'tentativas', v_t);
end $$;

-- Reenvio manual: zera as tentativas do pedido.
create or replace function public.bling_reenviar(p_order uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orders set bling_tentativas = 0, bling_ultima_tentativa = null, bling_erro = null where id = p_order and bling_pedido_id is null;
end $$;

-- Painel do CRM: últimos pedidos pagos e o estado de cada um no Bling.
create or replace function public.bling_painel()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ativo', coalesce(((select value from public.app_settings where key = 'bling') ->> 'ativo')::boolean, false),
    'loja_id', (select value from public.app_settings where key = 'bling') ->> 'loja_id',
    'loja_nome', (select value from public.app_settings where key = 'bling') ->> 'loja_nome',
    'pedidos', coalesce((select jsonb_agg(x order by x ->> 'pago_em' desc) from (
        select jsonb_build_object('id', o.id, 'numero', o.number, 'cliente', c.name, 'pago_em', coalesce(o.paid_at, o.created_at),
               'bling_pedido_id', o.bling_pedido_id, 'enviado_em', o.bling_enviado_em, 'erro', o.bling_erro, 'aviso', o.bling_aviso,
               'tentativas', o.bling_tentativas, 'teste', coalesce(o.teste, false)) x
          from public.orders o join public.contacts c on c.id = o.contact_id
         where o.payment_status = 'aprovado' order by coalesce(o.paid_at, o.created_at) desc limit 40) q), '[]'::jsonb));
end $$;

revoke execute on function public.bling_pendentes(integer), public.bling_resultado(uuid, text, text, text, text), public.bling_reenviar(uuid), public.bling_painel() from public, anon;
grant execute on function public.bling_pendentes(integer), public.bling_resultado(uuid, text, text, text, text), public.bling_reenviar(uuid), public.bling_painel() to authenticated, service_role;

-- Fila automática a cada 2 minutos (a função só envia quando app_settings.bling.ativo = true).
do $$
begin
  perform cron.unschedule('bling-enviar') where exists (select 1 from cron.job where jobname = 'bling-enviar');
  perform cron.schedule('bling-enviar', '*/2 * * * *', $cmd$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/bling-integracao',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{"acao":"processar"}'::jsonb)
  $cmd$);
end $$;
