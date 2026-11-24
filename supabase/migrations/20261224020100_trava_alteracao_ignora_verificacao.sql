-- A trava de alteração pós-pagamento não pode barrar a frase correta ("vou verificar com o responsável se ainda dá pra ajustar").
-- Frases de verificação são descartadas antes de conferir a promessa. Aditiva e idempotente.
create or replace function private.saida_sem_verificacao(p_texto text) returns text
language sql immutable set search_path = ''
as $$ select coalesce(string_agg(x, ' '), '') from regexp_split_to_table(coalesce(p_texto, ''), '(?<=[.!?])\s+|\n+') x
        where x !~* '(verific|ver se|confer|checar|saber se|se (ainda )?(d[aá]|é poss[ií]vel|consigo|conseguimos|podemos|posso))'; $$;
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'private'::regnamespace and p.proname = 'saida_travas_extra';
  if position('saida_sem_verificacao' in v_def) = 0 then
    v_new := replace(v_def, $q$if p_texto ~* '((j[aá]\s+)?(anotei$q$, $q$if private.saida_sem_verificacao(p_texto) ~* '((j[aá]\s+)?(anotei$q$);
    if position('saida_sem_verificacao' in v_new) = 0 then raise exception 'saida_travas_extra: padrão mudou'; end if;
    execute v_new;
  end if;
end
$mig$;
