-- 18/11/2026 (dono): o foco é lucrar. O kit é só praticidade de consulta e orçamento: NÃO baixa preço.
-- E o lembrete depois do link sem pagamento passa a ser rápido (20 min), sem insistir (6 h e 24 h já existiam).
-- Aditiva e idempotente (patch por expressão regular sobre as definições atuais).

-- ---------------------------------------------------------------- kit sem abatimento (liga só se o dono decidir)
alter table public.kits_agregados add column if not exists abate_preco boolean not null default false;
update public.kits_agregados set abate_preco = false where slug = 'cracha-cordao';

do $m$
declare d text; n text;
begin
  select pg_get_functiondef('private.kit_agregado_aplicar(uuid)'::regprocedure) into d;
  if position('abate_preco' in d) = 0 then
    n := regexp_replace(d, 'if v_falta then continue; end if;',
      E'if v_falta then continue; end if;\n    if not k.abate_preco then\n      update public.orcamentos set kit_agregado_id = k.id, kit_abatimento = 0 where id = p_orcamento;\n      return jsonb_build_object(''kit'', k.nome, ''abatimento'', 0);\n    end if;');
    if n = d then raise exception 'kit_agregado_aplicar mudou: ajuste o patch.'; end if;
    execute n;
  end if;

  select pg_get_functiondef('public.montar_orcamento(uuid,jsonb,jsonb)'::regprocedure) into d;
  if position('sem desconto no kit' in d) = 0 then
    n := replace(d, 'apresente o conjunto com o total desta resposta (o valor do cordão já está ajustado). Não fale em desconto nem em abatimento; é o preço do kit.',
                    'apresente crachá e cordão como um conjunto, com o valor de cada item e o total desta resposta (sem desconto no kit). Não fale em desconto.');
    if n = d then raise exception 'montar_orcamento mudou: ajuste o patch do kit.'; end if;
    execute n;
  end if;
end
$m$;

-- ---------------------------------------------------------------- lembrete depois do link
insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, template_janela_fechada, hora_min, hora_max, ativo, revisar)
values ('PAG_20M', 'Pagamento pendente: lembrete curto 20 minutos depois do link (Pix de qualquer banco e cartão em até 2x sem juros)', 'link_pagamento', 20, 'pagamento_pendente', 8, 20, true, false)
on conflict (codigo) do nothing;
-- a de 1 hora ficava colada na de 20 minutos: sai (mantêm-se 20 min, 6 h e 24 h)
update public.followup_regras set ativo = false, descricao = descricao || ' (desligada em 18/11: substituída pela de 20 min)' where codigo = 'PAG_1H' and ativo;

do $m$
declare d text; n text;
begin
  select pg_get_functiondef('public.followup_montar(uuid,timestamptz)'::regprocedure) into d;
  if position('PAG_20M' in d) > 0 then return; end if;
  -- texto do PAG_20M
  n := regexp_replace(d, E'case f\\.regra_codigo\\s+when ''PAG_1H'' then',
    E'case f.regra_codigo when ''PAG_20M'' then format(''Oi, %s! O link do orçamento %s está logo acima: %s. O Pix de qualquer banco cai na hora e dá pra pagar no cartão em até 2x sem juros. Se quiser ajustar alguma coisa antes de fechar, me fala.'', n, v_num, v_link) when ''PAG_1H'' then');
  if n = d then raise exception 'followup_montar mudou: âncora PAG_1H não encontrada.'; end if;
  -- F1 (10 min depois do PDF) não cutuca quem já recebeu o link: o PAG_20M cuida
  d := n;
  n := regexp_replace(d, E'if f\\.regra_codigo = ''F1'' then',
    E'if f.regra_codigo = ''F1'' and o.link_pagamento is not null then return jsonb_build_object(''ok'', true, ''acao'', ''pular'', ''motivo'', ''coberto_pelo_link''); end if;\n  if f.regra_codigo = ''F1'' then');
  if n = d then raise exception 'followup_montar mudou: âncora F1 não encontrada.'; end if;
  execute n;
end
$m$;

update public.kits_agregados
   set descricao = 'Crachá e cordão no mesmo orçamento, só para facilitar a consulta e a montagem. Cada item mantém o preço da planilha (sem desconto de kit) e a trava de lucro continua valendo.'
 where slug = 'cracha-cordao';
