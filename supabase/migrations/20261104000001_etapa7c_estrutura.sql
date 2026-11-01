-- Etapa 7C, parte 1: estrutura do banco de conhecimento v2, variáveis, uso dos trechos, sugestões e parâmetros do dono.
-- Aditiva e idempotente. A importação dos 83 trechos está em 20261104000002_etapa7c_conhecimento_importacao.sql.

-- ---------------------------------------------------------------- 1. colunas novas
alter table public.conhecimento add column if not exists usos integer not null default 0;
alter table public.conhecimento add column if not exists ultimo_uso_em timestamptz;
alter table public.conhecimento add column if not exists substituido_por text;   -- slug do trecho novo que substituiu este (importação 7C); null = nunca substituído
create index if not exists conhecimento_categoria_idx on public.conhecimento (categoria);

-- Uso (contador e última vez) não conta como edição: não mexe em atualizado_em nem reinicia a vetorização.
create or replace function private.conhecimento_antes() returns trigger
language plpgsql set search_path = ''
as $$
declare v_texto text;
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'usos' - 'ultimo_uso_em') = (to_jsonb(old) - 'usos' - 'ultimo_uso_em') then
    return new;
  end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'usos' - 'ultimo_uso_em' - 'ativo' - 'substituido_por') = (to_jsonb(old) - 'usos' - 'ultimo_uso_em' - 'ativo' - 'substituido_por') then
    return new;   -- só ligar/desligar por substituição: não é edição de conteúdo
  end if;
  v_texto := concat_ws('. ', new.titulo, new.quando_usar, new.resposta_pronta);
  if tg_op = 'INSERT' then
    new.embedding_texto := null;
  elsif new.embedding_texto is distinct from v_texto and (new.titulo is distinct from old.titulo or new.quando_usar is distinct from old.quando_usar or new.resposta_pronta is distinct from old.resposta_pronta) then
    new.embedding := null;
    new.embedding_em := null;
  end if;
  if tg_op = 'UPDATE' and not old.revisar and new.revisar is not distinct from old.revisar
     and (new.titulo is distinct from old.titulo or new.quando_usar is distinct from old.quando_usar or new.resposta_pronta is distinct from old.resposta_pronta
          or new.fatos is distinct from old.fatos or new.proximo_passo is distinct from old.proximo_passo) then
    new.revisar := true;
  end if;
  if new.revisar = false and (tg_op = 'INSERT' or old.revisar) then new.revisado_em := now(); end if;
  new.atualizado_em := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------- 2. sugestões (versão nova de um trecho que o dono já editou)
create table if not exists public.conhecimento_sugestoes (
  id uuid primary key default gen_random_uuid(),
  slug_novo text not null unique,
  slugs_atuais text[] not null default '{}',
  payload jsonb not null,
  motivo text,
  status text not null default 'pendente' check (status in ('pendente', 'aceita', 'recusada')),
  criado_em timestamptz not null default now(),
  decidido_em timestamptz
);
alter table public.conhecimento_sugestoes enable row level security;
revoke all on table public.conhecimento_sugestoes from anon;
drop policy if exists conhecimento_sugestoes_dono on public.conhecimento_sugestoes;
create policy conhecimento_sugestoes_dono on public.conhecimento_sugestoes for all to authenticated using (private.is_staff()) with check (private.is_staff());

-- ---------------------------------------------------------------- 3. parâmetros do dono (Configurações)
-- Personas: só NOMES de um assistente virtual. A fase (vendas ou pós-pagamento) é decidida pelo estado do pedido, nunca pelo modelo.
insert into public.app_settings (key, value) values ('personas', jsonb_build_object(
  'vendas', 'Laura', 'pos_pagamento', 'João Victor', 'artigo_vendas', 'a', 'artigo_pos_pagamento', 'o', 'apresentacao', 'assistente virtual da Sua Gráfica BH',
  'pos_pagamento_automatico', true))
on conflict (key) do nothing;

-- Política de troca e cancelamento. Os textos curtos vão no rodapé do PDF do orçamento e na descrição do link de pagamento.
insert into public.app_settings (key, value) values ('politica', jsonb_build_object(
  'troca_prazo_dias_uteis', 2,
  'resumo_pdf', 'Produto personalizado, produzido após a aprovação da arte. Refação gratuita em caso de defeito de impressão ou divergência da arte aprovada, com foto em até {{troca_prazo}} do recebimento. Sem cancelamento após a aprovação da arte; antes dela, cancelamento com reembolso.',
  'descricao_link', 'Produto personalizado feito após aprovação da arte. Refação em defeito de impressão (foto em até {{troca_prazo}}). Sem cancelamento após a aprovação da arte.',
  'aceite_arte', 'Ao aprovar a arte, você confirma o texto, as cores e as imagens. Depois disso a impressão segue exatamente como aprovada.',
  'reembolso_so_dono', true))
on conflict (key) do nothing;

-- Parcelamento: até 2x sem juros (taxa absorvida, já no piso); acima disso os juros são do cliente e aparecem no link.
insert into public.app_settings (key, value) values ('parcelamento', jsonb_build_object('sem_juros_ate', 2, 'maximo_link', 12))
on conflict (key) do nothing;

-- Arte: formato ideal, baixa qualidade e reaviso ao dono
insert into public.app_settings (key, value) values ('arte', jsonb_build_object(
  'formato_ideal', 'PDF em alta qualidade', 'horas_novo_alerta', 4, 'min_lado_px', 1200,
  'tipos_baixa_qualidade', jsonb_build_array('imagem_whatsapp', 'print', 'foto', 'imagem_pequena')))
on conflict (key) do nothing;

-- Cupom de recompra: parâmetros do dono (continua DESLIGADO até a simulação ser aprovada; ver cupom_recompra_simular)
update public.app_settings set value = value
  || jsonb_build_object('teto_reais', coalesce((value ->> 'teto_reais')::numeric, 25), 'uso_unico', true, 'acumula_condicao_especial', false, 'depende_de_avaliacao', false)
 where key = 'cupom_recompra';

-- O prompt do agente lê o nome do atendente por aqui: a persona de vendas
update public.agente_config set nome_atendente = (select value ->> 'vendas' from public.app_settings where key = 'personas') where id = 1 and nome_atendente = 'Bia';

-- ---------------------------------------------------------------- 4. variáveis resolvidas na hora da resposta
create or replace function private.politica_texto(p_chave text) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare v_t text; v_d integer;
begin
  select value ->> p_chave, coalesce((value ->> 'troca_prazo_dias_uteis')::integer, 2) into v_t, v_d from public.app_settings where key = 'politica';
  if v_t is null then return null; end if;
  return replace(v_t, '{{troca_prazo}}', v_d || case when v_d = 1 then ' dia útil' else ' dias úteis' end);
end;
$$;
revoke execute on function private.politica_texto(text) from public, anon, authenticated;

create or replace function public.politica_texto(p_chave text) returns text
language sql stable security definer set search_path = ''
as $$ select private.politica_texto(p_chave) $$;
revoke execute on function public.politica_texto(text) from public, anon;
grant execute on function public.politica_texto(text) to authenticated, service_role;

create or replace function public.conhecimento_resolver(p_texto text) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare pr public.parametros_comerciais%rowtype; t text := p_texto; per jsonb; cup jsonb; pol jsonb; v_d integer;
begin
  if t is null then return null; end if;
  if position('{{' in t) = 0 then return t; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  t := replace(t, '{{arte_basica}}', private.brl(pr.arte_valor));
  t := replace(t, '{{arte_frete}}', private.brl(pr.arte_frete_valor));
  t := replace(t, '{{pedido_minimo}}', private.brl(pr.pedido_minimo_frete_gratis));
  t := replace(t, '{{validade}}', pr.validade_orcamento_dias || case when pr.validade_orcamento_dias = 1 then ' dia' else ' dias' end);
  t := replace(t, '{{horario}}', private.horario_texto());
  select value into per from public.app_settings where key = 'personas';
  select value into cup from public.app_settings where key = 'cupom_recompra';
  select value into pol from public.app_settings where key = 'politica';
  t := replace(t, '{{persona_vendas}}', coalesce(per ->> 'vendas', 'Laura'));
  t := replace(t, '{{persona_pos_pagamento}}', coalesce(per ->> 'pos_pagamento', 'João Victor'));
  t := replace(t, '{{cupom_percentual}}', trim(trailing '.' from trim(trailing '0' from to_char(coalesce((cup ->> 'percentual')::numeric, 5), 'FM990.99'))));
  t := replace(t, '{{cupom_teto}}', private.brl(coalesce((cup ->> 'teto_reais')::numeric, 25)));
  t := replace(t, '{{cupom_validade_dias}}', coalesce(cup ->> 'validade_dias', '30'));
  v_d := coalesce((pol ->> 'troca_prazo_dias_uteis')::integer, 2);
  t := replace(t, '{{troca_prazo}}', v_d || case when v_d = 1 then ' dia útil' else ' dias úteis' end);
  return t;
end;
$$;
revoke execute on function public.conhecimento_resolver(text) from public, anon;
grant execute on function public.conhecimento_resolver(text) to authenticated, service_role;

-- ---------------------------------------------------------------- 5. busca: agora conta o uso de cada trecho devolvido
create or replace function public.buscar_conhecimento(p_pergunta text, p_embedding extensions.vector(384) default null, p_limite integer default 3, p_conversation uuid default null, p_registrar boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_norm text := private.norm_busca(p_pergunta);
  v_faq record; v_res jsonb; v_melhor numeric; v_melhor_id uuid;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'pergunta_vazia'); end if;

  select * into v_faq from public.faq_cache f where f.pergunta_norm = v_norm and f.ativo;
  if found then
    update public.faq_cache set usos = usos + 1 where pergunta_norm = v_norm;
    if p_registrar then
      insert into public.conhecimento_consultas (pergunta_norm, encontrou, melhor_score, trecho_id, via) values (v_norm, true, 1, v_faq.trecho_id, 'faq');
      update public.conhecimento set usos = usos + 1, ultimo_uso_em = now() where id = v_faq.trecho_id;
    end if;
    return jsonb_build_object('ok', true, 'encontrou', true, 'via', 'faq', 'resposta_direta', public.conhecimento_resolver(v_faq.resposta),
      'trechos', coalesce((select jsonb_build_array(jsonb_build_object('id', k.id, 'titulo', k.titulo, 'proximo_passo', public.conhecimento_resolver(k.proximo_passo), 'score', 1)) from public.conhecimento k where k.id = v_faq.trecho_id), '[]'::jsonb));
  end if;

  with cand as (
    select k.id, k.slug, k.titulo, k.resposta_pronta, k.fatos, k.proximo_passo,
           case when p_embedding is not null and k.embedding is not null then (1 - (k.embedding operator(extensions.<=>) p_embedding))::numeric end as sem,
           private.conhecimento_score_texto(v_norm, k.titulo, k.quando_usar, k.tags) as lex
      from public.conhecimento k where k.ativo and k.resposta_pronta is not null
  ), pont as (
    select *,
           (coalesce(sem, 0) >= pr.conhecimento_limiar_semantico or lex >= pr.conhecimento_limiar_lexico) as passa
      from cand
  ), top as (
    select * from pont where passa order by greatest(coalesce(sem, 0), lex) desc, lex desc limit least(greatest(p_limite, 1), 3)
  )
  select jsonb_agg(jsonb_build_object('id', id, 'slug', slug, 'titulo', titulo, 'resposta_pronta', public.conhecimento_resolver(resposta_pronta),
           'fatos', public.conhecimento_resolver(fatos), 'proximo_passo', public.conhecimento_resolver(proximo_passo),
           'score', round(greatest(coalesce(sem, 0), lex), 3)) order by greatest(coalesce(sem, 0), lex) desc),
         max(greatest(coalesce(sem, 0), lex)), (array_agg(id order by greatest(coalesce(sem, 0), lex) desc))[1]
    into v_res, v_melhor, v_melhor_id from top;

  if v_res is null then
    if p_registrar then
      insert into public.conhecimento_lacunas (pergunta, pergunta_norm, conversation_id) values (left(p_pergunta, 500), v_norm, p_conversation)
      on conflict (pergunta_norm) do update set ocorrencias = public.conhecimento_lacunas.ocorrencias + 1, ultima_em = now(),
        status = case when public.conhecimento_lacunas.status = 'resolvida' then 'aberta' else public.conhecimento_lacunas.status end;
      insert into public.conhecimento_consultas (pergunta_norm, encontrou) values (v_norm, false);
    end if;
    return jsonb_build_object('ok', true, 'encontrou', false, 'trechos', '[]'::jsonb,
      'orientacao', 'dizer_que_vai_confirmar_e_chamar_dono_gravidade_baixa');
  end if;
  if p_registrar then
    insert into public.conhecimento_consultas (pergunta_norm, encontrou, melhor_score, trecho_id) values (v_norm, true, v_melhor, v_melhor_id);
    update public.conhecimento set usos = usos + 1, ultimo_uso_em = now() where id in (select (e ->> 'id')::uuid from jsonb_array_elements(v_res) e);
  end if;
  return jsonb_build_object('ok', true, 'encontrou', true, 'trechos', v_res);
end;
$$;
revoke execute on function public.buscar_conhecimento(text, extensions.vector, integer, uuid, boolean) from public, anon;
grant execute on function public.buscar_conhecimento(text, extensions.vector, integer, uuid, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------- 6. perguntas sem resposta -> novo trecho; sugestões; reverter a importação
create or replace function public.conhecimento_criar_de_lacuna(p_lacuna uuid, p_titulo text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare l public.conhecimento_lacunas%rowtype; v_id uuid; v_slug text; v_tags text[];
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into l from public.conhecimento_lacunas where id = p_lacuna;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'lacuna_inexistente'); end if;
  if l.trecho_id is not null then return jsonb_build_object('ok', true, 'trecho_id', l.trecho_id, 'ja_existia', true); end if;
  v_slug := 'lacuna-' || substr(md5(l.pergunta_norm), 1, 8);
  v_tags := array[left(l.pergunta_norm, 80)];
  insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
  values (v_slug, left(coalesce(nullif(trim(p_titulo), ''), 'Pergunta: ' || l.pergunta), 120), 'geral',
          'Cliente pergunta algo como: ' || left(l.pergunta, 200), 'Escreva aqui a resposta (até 40 palavras).', '', 'Voltar ao pedido.', v_tags, 'Pergunta sem resposta', true, false)
  on conflict (slug) where slug is not null do update set slug = excluded.slug
  returning id into v_id;
  update public.conhecimento_lacunas set trecho_id = v_id where id = p_lacuna;
  return jsonb_build_object('ok', true, 'trecho_id', v_id, 'ja_existia', false,
    'orientacao', 'Rascunho criado desativado. Escreva a resposta, marque como revisado e ative.');
end;
$$;
revoke execute on function public.conhecimento_criar_de_lacuna(uuid, text) from public, anon;
grant execute on function public.conhecimento_criar_de_lacuna(uuid, text) to authenticated;

create or replace function public.conhecimento_sugestao_decidir(p_sugestao uuid, p_aceitar boolean) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare s public.conhecimento_sugestoes%rowtype; p jsonb; v_id uuid; v_old text;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into s from public.conhecimento_sugestoes where id = p_sugestao and status = 'pendente' for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sugestao_inexistente_ou_decidida'); end if;
  if not p_aceitar then
    update public.conhecimento_sugestoes set status = 'recusada', decidido_em = now() where id = s.id;
    return jsonb_build_object('ok', true, 'aceita', false);
  end if;
  p := s.payload;
  insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
  values (s.slug_novo, p ->> 'titulo', p ->> 'categoria', p ->> 'quando_usar', p ->> 'resposta_pronta', p ->> 'fatos', p ->> 'proximo_passo',
          array(select jsonb_array_elements_text(p -> 'tags')), 'Etapa 7C (sugestão aceita)', coalesce((p ->> 'revisar')::boolean, true), true)
  on conflict (slug) where slug is not null do update set titulo = excluded.titulo, categoria = excluded.categoria, quando_usar = excluded.quando_usar,
    resposta_pronta = excluded.resposta_pronta, fatos = excluded.fatos, proximo_passo = excluded.proximo_passo, tags = excluded.tags,
    fonte = excluded.fonte, revisar = excluded.revisar, ativo = true
  returning id into v_id;
  foreach v_old in array s.slugs_atuais loop
    if v_old <> s.slug_novo then
      update public.conhecimento set ativo = false, substituido_por = s.slug_novo where slug = v_old and ativo;
    end if;
  end loop;
  update public.conhecimento_sugestoes set status = 'aceita', decidido_em = now() where id = s.id;
  return jsonb_build_object('ok', true, 'aceita', true, 'trecho_id', v_id);
end;
$$;
revoke execute on function public.conhecimento_sugestao_decidir(uuid, boolean) from public, anon;
grant execute on function public.conhecimento_sugestao_decidir(uuid, boolean) to authenticated;

-- Desfaz a importação 7C: reativa os trechos antigos e desativa os novos (nada é apagado)
create or replace function public.conhecimento_reverter_importacao_7c() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_re integer; v_des integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.conhecimento set ativo = true, substituido_por = null where substituido_por is not null;
  get diagnostics v_re = row_count;
  update public.conhecimento set ativo = false where fonte = 'Etapa 7C' and ativo;
  get diagnostics v_des = row_count;
  return jsonb_build_object('ok', true, 'reativados', v_re, 'desativados', v_des);
end;
$$;
revoke execute on function public.conhecimento_reverter_importacao_7c() from public, anon, authenticated;
grant execute on function public.conhecimento_reverter_importacao_7c() to service_role;

-- ---------------------------------------------------------------- 7. cupom de recompra: teto em reais, sem acumular com condição especial, e arte básica grátis quando não couber
alter table public.cupons_recompra add column if not exists beneficio text not null default 'desconto' check (beneficio in ('desconto', 'arte_basica_gratis'));

create or replace function public.cupom_recompra_aplicar(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  cfg jsonb; o public.orcamentos%rowtype; c public.cupons_recompra%rowtype; v_itens numeric; v_piso numeric; v_desc numeric; v_val jsonb; v_teto numeric;
  v_arte numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select value into cfg from public.app_settings where key = 'cupom_recompra';
  if not coalesce((cfg ->> 'ativo')::boolean, false) then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'desligado'); end if;
  select * into o from public.orcamentos where id = p_orcamento;
  if not found or o.desconto_valor > 0 then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'orcamento_ja_tem_desconto'); end if;
  -- não acumula com condição especial
  if exists (select 1 from public.condicoes_especiais ce where ce.orcamento_id = p_orcamento and ce.resultado <> 'cancelada') or o.origem_id is not null then
    return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'ja_tem_condicao_especial');
  end if;
  select * into c from public.cupons_recompra where contact_id = o.contact_id and usado_em is null and valido_ate > now();
  if not found then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'sem_cupom_valido'); end if;
  v_teto := coalesce((cfg ->> 'teto_reais')::numeric, 25);
  select coalesce(sum(quantidade * preco_unitario), 0), coalesce(sum(coalesce(piso, 0)), 0) into v_itens, v_piso from public.orcamento_itens where orcamento_id = p_orcamento;
  v_desc := floor(least(v_itens * c.percentual / 100, greatest(v_itens - v_piso, 0) * (cfg ->> 'fracao_gordura_max')::numeric, v_teto) * 100) / 100;

  if v_desc >= 5 then
    update public.orcamentos set desconto_valor = v_desc, total = total - v_desc where id = p_orcamento;
    v_val := public.validar_margem(p_orcamento);
    if v_val ->> 'status' = 'ok' then
      update public.cupons_recompra set usado_em = now(), orcamento_id = p_orcamento, desconto_valor = v_desc, beneficio = 'desconto' where id = c.id;
      return jsonb_build_object('ok', true, 'aplicado', true, 'tipo', 'desconto', 'desconto', v_desc, 'texto_curto', 'Como cliente que já comprou com a gente, você tem um cupom de recompra nesta compra.');
    end if;
    update public.orcamentos set desconto_valor = 0, total = total + v_desc where id = p_orcamento;
  end if;

  -- não coube no limite: vira arte básica grátis (quando o orçamento tem arte cobrada)
  v_arte := o.arte_valor;
  if v_arte > 0 and o.arte_modo = 'paga' then
    update public.orcamentos set arte_valor = 0, total = total - v_arte where id = p_orcamento;
    v_val := public.validar_margem(p_orcamento);
    if v_val ->> 'status' = 'ok' then
      update public.cupons_recompra set usado_em = now(), orcamento_id = p_orcamento, desconto_valor = v_arte, beneficio = 'arte_basica_gratis' where id = c.id;
      return jsonb_build_object('ok', true, 'aplicado', true, 'tipo', 'arte_basica_gratis', 'desconto', v_arte, 'texto_curto', 'Como cliente que já comprou com a gente, a criação da arte básica sai por nossa conta nesta compra.');
    end if;
    update public.orcamentos set arte_valor = v_arte, total = total + v_arte where id = p_orcamento;
  end if;
  return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'sem_margem_para_o_cupom');
end;
$$;
revoke execute on function public.cupom_recompra_aplicar(uuid) from public, anon, authenticated;
grant execute on function public.cupom_recompra_aplicar(uuid) to service_role;

-- ---------------------------------------------------------------- 8. busca textual: tag de frase longa vale mais que tag de uma palavra só
-- ("parcelar no cartao" deve ganhar de "cartao"). Só muda o desempate entre tags contidas na pergunta (0,86 a 0,90); o resto da pontuação é o mesmo.
create or replace function private.conhecimento_score_texto(p_pergunta_norm text, p_titulo text, p_quando text, p_tags text[]) returns numeric
language plpgsql immutable set search_path = ''
as $$
declare
  v_stop constant text[] := array['de','da','do','das','dos','para','pra','com','e','um','uma','por','favor','me','o','a','os','as','em','no','na','que','eh','ai','oi','ola','vcs','voce','voces','tem','ter','posso','pode','quero','queria','como','qual','quais','isso','esse','essa','la','ne','so','se','eu','meu','minha'];
  v_pal text[]; v_alvo text; v_hit numeric := 0; v_tot numeric := 0; w text; v_tag_max numeric := 0; t text;
begin
  v_alvo := private.norm_busca(concat_ws(' ', p_titulo, p_quando));
  v_pal := array(select x from regexp_split_to_table(p_pergunta_norm, ' ') x where x <> '' and not (x = any (v_stop)));
  foreach w in array v_pal loop
    v_tot := v_tot + 1;
    if (' ' || v_alvo || ' ') like ('% ' || w || ' %') or length(w) > 3 and v_alvo like ('%' || w || '%') then v_hit := v_hit + 1; end if;
  end loop;
  foreach t in array coalesce(p_tags, '{}') loop
    t := private.norm_busca(t);
    if t = '' then continue; end if;
    if p_pergunta_norm = t then v_tag_max := greatest(v_tag_max, 1);
    elsif (' ' || p_pergunta_norm || ' ') like ('% ' || t || ' %') then
      v_tag_max := greatest(v_tag_max, 0.84 + 0.02 * least(array_length(string_to_array(t, ' '), 1), 3));
    else v_tag_max := greatest(v_tag_max, (extensions.similarity(p_pergunta_norm, t) * 0.9)::numeric); end if;
  end loop;
  return greatest(
    v_tag_max,
    case when v_tot > 0 then v_hit / v_tot * 0.8 else 0 end,
    extensions.similarity(p_pergunta_norm, v_alvo)::numeric);
end;
$$;
