-- Bug de 24/11 (caso Som DJ Iluminação): cliente disse que ia juntar o dinheiro e se despediu
-- ("Ok obrigado" -> "Um abraço!"), mas o Q1 (10 min) disparou "Ficou alguma dúvida sobre os adesivos?"
-- porque o regex de recusa/encerramento em followup_reservar só casava "obrigado"/"valeu" isolados
-- (sem palavra antes) e não reconhecia despedida ("abraço", "tchau", "até mais") nem "volto depois"/
-- "vou juntar o dinheiro". Agora qualquer Q1/Q2 pendente é pulado (motivo cliente_recusou) também
-- nesses casos. Aditiva e idempotente.

create or replace function pg_temp.trocar(p_def text, p_velho text, p_novo text) returns text language plpgsql as $f$
begin
  if position(p_velho in p_def) = 0 then raise exception 'trecho não encontrado: %', left(p_velho, 80); end if;
  return replace(p_def, p_velho, p_novo);
end $f$;

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_reservar';
  if position('/* despedida_24_11 */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def,
      $q$z.body ~* '(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|^\W*obrigad[oa]\W*$|^\W*valeu\W*$|n[aã]o (quero|preciso|tenho interesse|faz sentido|vou (querer|seguir|fechar|precisar))|sem interesse|deixa (pra l[aá]|quieto|assim)|desist|j[aá] (fechei|resolvi|comprei|contratei)|era s[oó] isso)') then v_motivo := 'cliente_recusou'; /* cliente_recusou */$q$,
      $q$z.body ~* '(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|\Wobrigad[oa]\W*$|^\W*valeu\W*$|n[aã]o (quero|preciso|tenho interesse|faz sentido|vou (querer|seguir|fechar|precisar))|sem interesse|deixa (pra l[aá]|quieto|assim)|desist|j[aá] (fechei|resolvi|comprei|contratei)|era s[oó] isso|abra[çc]o|tchau|at[eé] (mais|logo|a pr[oó]xima)|volt[oa] (depois|mais tarde)|vou (ver|pensar|juntar|organizar).*(dinheiro|valor|grana|depois)|(depois|mais tarde) eu (volto|te chamo|falo))' then v_motivo := 'cliente_recusou'; /* cliente_recusou despedida_24_11 */$q$);
    execute v_new;
  end if;
end $mig$;
