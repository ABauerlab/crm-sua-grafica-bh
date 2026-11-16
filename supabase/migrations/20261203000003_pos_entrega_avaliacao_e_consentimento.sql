-- PENDENTE DE APLICAR (o Supabase pede confirmação para o update em massa): pós-entrega com agradecimento, avaliação no Google e consentimento.
-- Quem recebe o pedido passa a constar como opted_in (origem 'pos_entrega'), exceto quem já pediu PARAR. A mensagem avisa como sair.
-- Template da Meta: pos_venda_avaliacao (MARKETING, enviado para revisão; só funciona fora da janela de 24 h depois de aprovado).
-- A lista de origens do consentimento não aceitava 'pos_entrega' (descoberto ao aplicar em 16/11/2026).
alter table public.contacts drop constraint if exists contacts_marketing_consent_source_check;
alter table public.contacts add constraint contacts_marketing_consent_source_check check (marketing_consent_source = any (array['whatsapp','manual','formulario','loja','outro','pos_entrega']));

create or replace function private.orders_entregue_consentimento() returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.stage = 'entregue' and old.stage is distinct from 'entregue' then
    update public.contacts set marketing_consent = 'opted_in', marketing_consent_at = now(), marketing_consent_source = 'pos_entrega'
     where id = new.contact_id and coalesce(marketing_consent, 'none') = 'none' and coalesce(optout, false) = false;
  end if;
  return new;
end $$;
drop trigger if exists orders_entregue_consentimento on public.orders;
create trigger orders_entregue_consentimento after update of stage on public.orders for each row execute function private.orders_entregue_consentimento();

update public.contacts c set marketing_consent = 'opted_in', marketing_consent_at = now(), marketing_consent_source = 'pos_entrega'
 where coalesce(c.marketing_consent, 'none') = 'none' and coalesce(c.optout, false) = false
   and exists (select 1 from public.orders o where o.contact_id = c.id and o.stage = 'entregue');

update public.followup_regras set template_janela_fechada = 'pos_venda_avaliacao',
  descricao = 'Pós-entrega: agradecimento, pedido de avaliação no Google e aviso de novidades, 1 dia depois da entrega' where codigo = 'POS_ENTREGA';

do $mig$
declare d text; novo text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'followup_montar';
  if position('pos_venda_avaliacao' in d) > 0 then return; end if;
  novo := replace(d, $q$v_texto := format('Oi, %s! Seu pedido %s foi entregue. Deu tudo certo? %s', n, v_ped, v_up);$q$,
    $q$v_texto := format('Oi, %s! Seu pedido %s foi entregue. Obrigado pela confiança! Deu tudo certo? Se puder, avalie a Sua Gráfica BH no Google, leva 1 minuto: https://g.page/r/CZ6eNNGjdgO4EAE/review %s Vamos te avisar por aqui de novidades e promoções. Se não quiser, é só responder PARAR.', n, v_ped, v_up);$q$);
  novo := replace(novo, $q$v_tpl := 'pos_venda_satisfacao'; v_params := jsonb_build_array(n, v_ped);$q$, $q$v_tpl := 'pos_venda_avaliacao'; v_params := jsonb_build_array(n, v_ped);$q$);
  if position('pos_venda_avaliacao' in novo) = 0 or position('avalie a Sua' in novo) = 0 then raise exception 'patch nao aplicou'; end if;
  execute novo;
end $mig$;
