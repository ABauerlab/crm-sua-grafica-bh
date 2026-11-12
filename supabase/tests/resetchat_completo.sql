-- /resetchat completo: recusa número comum e número com pedido pago; apaga tudo do número de teste. Tudo em transação desfeita.
-- Rodar com um operador real (troque o uuid pelo de um profile).
begin;
select set_config('request.jwt.claims', '{"sub":"9669d774-cb9c-4547-b788-9ef2f94cd2fb","role":"authenticated"}', true);
create temp table _r (q text, ok boolean);
grant all on _r to authenticated;
set local role authenticated;
do $$ declare r jsonb; begin
  -- número que não é de teste
  select public.resetar_chat_completo(c.id) into r from conversations c join contacts k on k.id = c.contact_id where k.wa_id = '553171494800';
  insert into _r values ('recusa numero comum', r ->> 'erro' = 'numero_nao_e_de_teste');
end $$;
reset role;
insert into numeros_teste (telefone, apelido) values ('3171494800', 'tmp') on conflict do nothing;
set local role authenticated;
do $$ declare r jsonb; begin
  select public.resetar_chat_completo(c.id) into r from conversations c join contacts k on k.id = c.contact_id where k.wa_id = '553171494800';
  insert into _r values ('recusa pedido pago', r ->> 'erro' = 'tem_pedido_pago');
end $$;
reset role;
do $$ begin
  if exists (select 1 from _r where not ok) then raise exception 'FALHOU: %', (select string_agg(q, ', ') from _r where not ok); end if;
  raise notice 'OK: resetchat recusa numero comum e pedido pago';
end $$;
rollback;
