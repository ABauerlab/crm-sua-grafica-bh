-- 19/11/2026: (1) devolver a conversa para a IA reprocessa o que ficou sem resposta e destrava o setor;
-- (2) cobertura autônoma de orçamento concorrente (cobrir_orcamento) só para gráficas de BH e região, com CNPJ e endereço;
-- (3) lembrete de anúncio: cliente que só mandou a mensagem padrão recebe opções e preços 5 minutos depois.
-- Aditiva e idempotente.

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------------------------------------
-- (1) Devolver para a IA: reprocessa a última mensagem do cliente que ficou sem resposta
-- ---------------------------------------------------------------------------------------------------------
create or replace function private.agente_reprocessar_conversa(p_conv uuid, p_motivo text default 'devolvida_para_ia') returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_msg uuid;
begin
  select valor into v_url from public.app_segredos where chave = 'n8n_wf1_entrada_url';
  if v_url is null then return false; end if;
  if coalesce((select (value ->> 'enabled')::boolean from public.app_settings where key = 'agent'), false) = false then return false; end if;

  select mi.id into v_msg
    from public.messages mi
   where mi.conversation_id = p_conv and mi.direction = 'in' and mi.type in ('text', 'audio', 'image', 'document')
     and mi.created_at > now() - interval '12 hours'
     and not exists (select 1 from public.messages mo where mo.conversation_id = p_conv and mo.direction = 'out' and mo.created_at > mi.created_at)
   order by mi.created_at desc limit 1;
  if v_msg is null then return false; end if;

  delete from public.agente_execucoes where message_id = v_msg;
  insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)
  values (p_conv, 'sistema', 'reprocessar', jsonb_build_object('message_id', v_msg, 'motivo', p_motivo), 'ok', 'private.agente_reprocessar_conversa');
  perform net.http_post(url := v_url, headers := '{"Content-Type": "application/json", "x-gbh-token": "retomada"}'::jsonb,
                        body := jsonb_build_object('message_id', v_msg));
  return true;
end $$;
revoke all on function private.agente_reprocessar_conversa(uuid, text) from public, anon, authenticated;

-- Antes de gravar: ao voltar para a IA, limpa o aviso de "precisa de humano" e libera o setor arte/dono
create or replace function private.conversa_devolvida_limpar() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.modo_atendimento = 'ia' and old.modo_atendimento is distinct from 'ia' then
    new.needs_human := false;
    if new.setor in ('arte', 'dono') and coalesce(new.attendant_change_reason, '') like 'Devolvido para a IA%' then new.setor := null; end if;
  end if;
  return new;
end $$;
revoke execute on function private.conversa_devolvida_limpar() from public, anon, authenticated;
drop trigger if exists conversations_devolvida_limpar on public.conversations;
create trigger conversations_devolvida_limpar before update on public.conversations
  for each row execute function private.conversa_devolvida_limpar();

-- Depois de gravar: reprocessa o que o cliente mandou e ficou sem resposta
create or replace function private.conversa_devolvida_reprocessar() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform private.agente_reprocessar_conversa(new.id, 'devolvida_para_ia');
  exception when others then
    raise warning 'reprocessar na devolução: %', sqlerrm;
  end;
  return null;
end $$;
revoke execute on function private.conversa_devolvida_reprocessar() from public, anon, authenticated;
drop trigger if exists conversations_devolvida_reprocessar on public.conversations;
create trigger conversations_devolvida_reprocessar after update on public.conversations
  for each row when (new.modo_atendimento = 'ia' and old.modo_atendimento is distinct from 'ia')
  execute function private.conversa_devolvida_reprocessar();

-- A retomada automática também deve aceitar conversa que recebeu a frase neutra só uma vez
-- (a frase neutra agora só sai na primeira mensagem de uma conversa nova, ver WF2 de 19/11).

-- ---------------------------------------------------------------------------------------------------------
-- (2) Cobertura de orçamento concorrente
-- ---------------------------------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('cobertura', jsonb_build_object(
  'ativo', true, 'somente_regiao_bh', true, 'exigir_cnpj', true, 'exigir_endereco', true, 'abaixo_do_concorrente', 4.10,
  'cidades', jsonb_build_array('belo horizonte', 'contagem', 'betim', 'ibirite', 'sabara', 'santa luzia', 'nova lima', 'vespasiano',
    'lagoa santa', 'ribeirao das neves', 'sarzedo', 'mario campos', 'brumadinho', 'esmeraldas', 'pedro leopoldo', 'confins', 'caete',
    'raposos', 'rio acima', 'sao jose da lapa', 'matozinhos', 'florestal', 'juatuba', 'igarape', 'mateus leme', 'jaboticatubas',
    'nova uniao', 'baldim', 'capim branco', 'rio manso', 'itatiaiucu', 'sao joaquim de bicas', 'funilandia', 'taquaracu de minas')))
on conflict (key) do nothing;

create table if not exists public.cobertura_log (
  id uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  contact_id uuid references public.contacts (id) on delete set null,
  conversation_id uuid,
  cidade text, uf text, cnpj text, endereco_informado boolean,
  resultado text not null, motivo text,
  itens jsonb, orcamentos uuid[] not null default '{}'
);
alter table public.cobertura_log enable row level security;
drop policy if exists cobertura_log_staff on public.cobertura_log;
create policy cobertura_log_staff on public.cobertura_log for select to authenticated using (private.is_staff());

create or replace function private.texto_norm(p text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(lower(translate(coalesce(p, ''), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '\s+', ' ', 'g'))
$$;

create or replace function private.cnpj_valido(p text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  w1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2]; w2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s int; i int; v1 int; v2 int;
begin
  if length(d) <> 14 or d ~ '^(\d)\1{13}$' then return false; end if;
  s := 0; for i in 1 .. 12 loop s := s + substr(d, i, 1)::int * w1[i]; end loop;
  v1 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  s := 0; for i in 1 .. 13 loop s := s + substr(d, i, 1)::int * w2[i]; end loop;
  v2 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  return v1 = substr(d, 13, 1)::int and v2 = substr(d, 14, 1)::int;
end $$;

-- Núcleo: avalia cada faixa do concorrente. Piso da cobertura (decisão do dono, 19/11/2026):
-- maior entre custo + lucro bruto mínimo (R$ 65) e o piso duro (lucro líquido zero, com imposto e taxa do Pix).
-- O piso normal (custo x 1,5) NÃO vale aqui; vale só para o preço de tabela. Tudo continua passando por validar_margem.
create or replace function private.cobertura_processar(p_contact uuid, p_itens jsonb, p_opcoes jsonb, p_criar boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cfg jsonb := coalesce((select value from public.app_settings where key = 'cobertura'), '{}'::jsonb);
  pr public.parametros_comerciais%rowtype;
  v_abaixo numeric := coalesce((cfg ->> 'abaixo_do_concorrente')::numeric, 4.10);
  v_taxa numeric := coalesce((private.taxa_pagamento('pix') ->> 'pct')::numeric, 0);
  it jsonb; c public.catalogo%rowtype; cand record; v_opc jsonb;
  v_sku text; v_qtd integer; v_val numeric; v_floor numeric; v_unit numeric; v_total numeric;
  v_m jsonb; v_id uuid; v_vm jsonb; v_fin jsonb; v_motivo text; v_f jsonb; v_faixas jsonb := '[]'::jsonb;
  v_cobertas integer := 0; v_ids uuid[] := '{}'; v_achou boolean; v_total_orc numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  v_opc := jsonb_strip_nulls(jsonb_build_object('conversation_id', p_opcoes -> 'conversation_id', 'bairro', p_opcoes -> 'bairro', 'cep', p_opcoes -> 'cep',
            'arte', coalesce(p_opcoes -> 'arte', '"nenhuma"'::jsonb), 'metodo', 'pix', 'teste', p_opcoes -> 'teste', 'nao_otimizar_lote', 'true'));

  for it in select * from jsonb_array_elements(p_itens) limit 6 loop
    v_sku := upper(btrim(coalesce(it ->> 'sku', '')));
    v_qtd := greatest(1, coalesce(nullif(it ->> 'quantidade', '')::integer, 1));
    v_val := nullif(it ->> 'valor_concorrente', '')::numeric;
    v_achou := false; v_motivo := null;
    select * into c from public.catalogo where sku = v_sku and active and vendavel and preco_venda is not null;
    if v_val is null or v_val <= 0 then
      v_motivo := 'valor_concorrente_invalido';
    elsif not found then
      v_motivo := 'sku_invalido';
    else
      for cand in
        select x.sku, x.custo, x.descricao, (x.sku = c.sku) as exato
          from public.catalogo x
         where x.active and x.vendavel and x.preco_venda is not null
           and (x.sku = c.sku or (x.categoria = c.categoria and x.quantidade is not distinct from c.quantidade
                and x.gramatura_g is not distinct from c.gramatura_g and x.cores is not distinct from c.cores
                and x.tamanho_mm is not distinct from c.tamanho_mm and x.custo < c.custo))
         order by (x.sku = c.sku) desc, x.custo desc
      loop
        v_floor := greatest(ceil((cand.custo * v_qtd + pr.lucro_bruto_minimo) * 100) / 100,
                            ceil(cand.custo * v_qtd / (1 - pr.imposto_pct / 100 - v_taxa / 100) * 100) / 100);
        v_unit := ceil(greatest(v_val - v_abaixo, v_floor) / v_qtd * 100) / 100;
        v_total := v_unit * v_qtd;
        if v_total >= v_val then v_motivo := 'abaixo_do_piso'; continue; end if;

        v_id := null; v_m := null; v_total_orc := v_total;
        if p_criar then
          v_m := public.montar_orcamento(p_contact, jsonb_build_array(jsonb_build_object('sku', cand.sku, 'quantidade', v_qtd)), v_opc);
          if coalesce(v_m ->> 'status', '') <> 'ok' then v_motivo := coalesce(v_m ->> 'motivo', 'orcamento_bloqueado'); continue; end if;
          v_id := (v_m ->> 'orcamento_id')::uuid;
          begin
            update public.orcamento_itens set preco_unitario = v_unit, regra_preco = 'cobertura_concorrente', confianca_preco = 'alta' where orcamento_id = v_id;
            update public.orcamentos set aprovado_dono_em = now(), regra_preco = 'cobertura_concorrente',
                   aprovado_dono_motivo = 'Cobertura automática de orçamento concorrente (regra do dono, 19/11/2026)' where id = v_id;
            v_vm := public.validar_margem(v_id);
            if v_vm ->> 'status' <> 'ok' then raise exception 'margem'; end if;
            v_fin := private.orcamento_financeiro(v_id);
            update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
                   lucro_liquido = (v_fin ->> 'lucro')::numeric,
                   margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
             where id = v_id;
            select total into v_total_orc from public.orcamentos where id = v_id;
          exception when others then
            delete from public.orcamentos where id = v_id;
            v_id := null; v_motivo := 'abaixo_do_piso';
            continue;
          end;
          v_ids := v_ids || v_id;
        end if;

        v_f := jsonb_build_object('cobrivel', true, 'quantidade_pacotes', v_qtd, 'descricao', cand.descricao,
                 'valor_concorrente', v_val, 'total', v_total_orc, 'valor_economia', round(v_val - v_total_orc, 2),
                 'eh_alternativa_sem_acabamento', not cand.exato,
                 'diferenca', case when cand.exato then null else 'Versão ' || cand.descricao || ' no lugar de ' || c.descricao end,
                 'orcamento_id', v_id, 'numero', v_m ->> 'numero', 'data_prevista_br', v_m ->> 'data_prevista_br');
        v_faixas := v_faixas || jsonb_build_array(jsonb_strip_nulls(v_f));
        v_cobertas := v_cobertas + 1; v_achou := true;
        exit;
      end loop;
    end if;
    if not v_achou then
      v_faixas := v_faixas || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('cobrivel', false, 'motivo', coalesce(v_motivo, 'abaixo_do_piso'),
                   'valor_concorrente', v_val, 'descricao', c.descricao)));
    end if;
  end loop;

  return jsonb_build_object('status', 'ok', 'cobertas', v_cobertas, 'faixas', v_faixas, 'orcamentos', to_jsonb(v_ids),
    'vantagens', jsonb_build_array('Retirada grátis no centro de BH, sem frete', 'Entrega grátis nos bairros centrais', 'Pix de qualquer banco e cartão em até 2x sem juros'),
    'orientacao', case
      when v_cobertas = 0 then 'Nenhuma faixa pôde ser coberta. Diga com educação que nessa especificação o valor do concorrente está abaixo do que conseguimos praticar, mostre o orçamento normal e destaque as vantagens (retirada grátis, Pix, prazo). Nunca cite custo, piso nem margem. Não chame o dono.'
      else 'Apresente só as faixas com cobrivel=true, com o valor de total e o valor_economia. Se eh_alternativa_sem_acabamento=true, diga com transparência a diferença (campo diferenca) de forma vendedora e pergunte se serve. Destaque as vantagens. Com UMA faixa coberta e o cliente pronto para fechar, chame gerar_pdf_orcamento e depois gerar_link_pagamento com o orcamento_id da faixa na mesma rodada. Com várias, diga quais cobrimos e pergunte qual ele quer. Nunca chame chamar_dono.' end);
end $$;
revoke all on function private.cobertura_processar(uuid, jsonb, jsonb, boolean) from public, anon, authenticated;

create or replace function public.cobrir_orcamento(p_contact uuid, p_itens_concorrente jsonb, p_opcoes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cfg jsonb := coalesce((select value from public.app_settings where key = 'cobertura'), '{}'::jsonb);
  o jsonb := coalesce(p_opcoes, '{}'::jsonb);
  v_cnpj text := regexp_replace(coalesce(o ->> 'cnpj_concorrente', ''), '\D', '', 'g');
  v_end text := btrim(coalesce(o ->> 'endereco_concorrente', ''));
  v_cid text := private.texto_norm(o ->> 'cidade_concorrente');
  v_uf text := upper(btrim(coalesce(o ->> 'uf_concorrente', '')));
  v_res jsonb; v_motivo text; v_orient text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if jsonb_typeof(p_itens_concorrente) is distinct from 'array' or jsonb_array_length(p_itens_concorrente) not between 1 and 6 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'orientacao', 'Informe de 1 a 6 faixas do concorrente com sku, quantidade e valor_concorrente.');
  end if;
  if not exists (select 1 from public.contacts where id = p_contact) then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'contato_nao_encontrado');
  end if;

  if not coalesce((cfg ->> 'ativo')::boolean, true) then v_motivo := 'cobertura_desligada';
  elsif coalesce((cfg ->> 'exigir_cnpj')::boolean, true) and not private.cnpj_valido(v_cnpj) then v_motivo := 'cnpj_ausente_ou_invalido';
  elsif coalesce((cfg ->> 'exigir_endereco')::boolean, true) and length(v_end) < 10 then v_motivo := 'endereco_ausente';
  elsif coalesce((cfg ->> 'somente_regiao_bh')::boolean, true) and (v_cid = '' or not (cfg -> 'cidades' ? v_cid) or (v_uf <> '' and v_uf <> 'MG')) then v_motivo := 'concorrente_fora_da_regiao';
  end if;

  if v_motivo is not null then
    v_orient := case v_motivo
      when 'cnpj_ausente_ou_invalido' then 'Não dá pra cobrir ainda: peça, com educação, o orçamento completo da gráfica com CNPJ e endereço (a imagem ou o PDF oficial). Não explique o motivo antifraude, só diga que precisa do documento completo da empresa.'
      when 'endereco_ausente' then 'Não dá pra cobrir ainda: peça o orçamento completo, com o endereço da gráfica e o CNPJ.'
      when 'concorrente_fora_da_regiao' then 'Só cobrimos orçamento de gráficas de Belo Horizonte e região. Diga isso com simpatia, mostre o nosso orçamento normal e destaque retirada grátis, Pix e prazo. Não chame o dono.'
      else 'Cobertura indisponível no momento. Siga com o orçamento normal.' end;
    insert into public.cobertura_log (contact_id, conversation_id, cidade, uf, cnpj, endereco_informado, resultado, motivo, itens)
    values (p_contact, nullif(o ->> 'conversation_id', '')::uuid, nullif(v_cid, ''), nullif(v_uf, ''), nullif(v_cnpj, ''), length(v_end) >= 10, 'recusada', v_motivo, p_itens_concorrente);
    return jsonb_build_object('status', 'recusado', 'motivo', v_motivo, 'orientacao', v_orient);
  end if;

  v_res := private.cobertura_processar(p_contact, p_itens_concorrente, o, true);
  insert into public.cobertura_log (contact_id, conversation_id, cidade, uf, cnpj, endereco_informado, resultado, motivo, itens, orcamentos)
  values (p_contact, nullif(o ->> 'conversation_id', '')::uuid, v_cid, nullif(v_uf, ''), v_cnpj, true,
          case when (v_res ->> 'cobertas')::int > 0 then 'coberta' else 'nao_coberta' end, null, v_res -> 'faixas',
          coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(v_res -> 'orcamentos') x), '{}'));
  return v_res - 'orcamentos';
end $$;
revoke all on function public.cobrir_orcamento(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.cobrir_orcamento(uuid, jsonb, jsonb) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- (3) Lembrete de anúncio: cliente que só mandou a mensagem padrão do anúncio
-- ---------------------------------------------------------------------------------------------------------
alter table public.followup_regras drop constraint if exists followup_regras_referencia_check;
alter table public.followup_regras add constraint followup_regras_referencia_check
  check (referencia = any (array['orcamento_enviado', 'link_pagamento', 'pedido_entregue', 'pedido_pago', 'conversa_parada', 'checkout_aberto', 'anuncio_parado']));
insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, hora_min, hora_max, ativo, revisar)
values ('Q1_ANUNCIO', 'Lead de anúncio que só mandou a mensagem padrão: 5 minutos depois, opções e preços do produto do anúncio (do mais em conta ao mais completo)', 'anuncio_parado', 5, 8, 20, true, false)
on conflict (codigo) do nothing;

-- Texto montado pelo banco (preço sempre de calcular_preco; sem SKU, custo ou fornecedor)
create or replace function private.fu_texto_anuncio(p_conv uuid, p_nome text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_head text; v_h text; v_cat text; v_q integer; v_t text; v_linhas text;
begin
  select coalesce(nullif(cv.last_referral ->> 'headline', ''), nullif(ct.first_referral ->> 'headline', '')) into v_head
    from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conv;
  if v_head is null then return null; end if;
  v_h := private.texto_norm(v_head);

  if v_h like '%crach%' then
    return format('Oi, %s! Vi que você veio pelo nosso anúncio de %s. Pra eu te mostrar as opções certas: você prefere o crachá na vertical ou na horizontal?', p_nome, lower(v_head));
  end if;

  v_cat := case
    when v_h ~ 'cart(ao|oes).*visita|visita' then 'CARTÕES DE VISITA'
    when v_h ~ 'panfleto|flyer|folheto' then 'PANFLETOS, FLYERS E FOLHETOS'
    else (select c.categoria from public.catalogo c
           where c.active and c.vendavel and c.preco_venda is not null and v_h like '%' || split_part(private.texto_norm(c.categoria), ' ', 1) || '%' limit 1) end;
  if v_cat is null then
    return format('Oi, %s! Vi que você veio pelo nosso anúncio de %s. Me conta qual quantidade você precisa que eu já te passo as opções e os valores certinhos.', p_nome, lower(v_head));
  end if;

  select mode() within group (order by quantidade) into v_q from public.catalogo where categoria = v_cat and active and vendavel and preco_venda is not null;
  select mode() within group (order by tamanho_mm) into v_t from public.catalogo where categoria = v_cat and quantidade = v_q and active and vendavel and preco_venda is not null;

  with g as (
    select distinct on (x.descricao, x.cores)
           initcap(lower(x.descricao)) || case x.cores
             when '4X0' then ', colorido na frente' when '4X4' then ', colorido frente e verso' when '4X1' then ', colorido na frente e uma cor no verso'
             when '1X0' then ', uma cor na frente' when '1X1' then ', uma cor frente e verso' else '' end as texto,
           (public.calcular_preco(x.sku, 1, '{}'::jsonb) ->> 'preco_total')::numeric as preco
      from public.catalogo x
     where x.categoria = v_cat and x.quantidade = v_q and x.tamanho_mm is not distinct from v_t and x.active and x.vendavel and x.preco_venda is not null
     order by x.descricao, x.cores, x.preco_venda),
  rk as (select g.*, row_number() over (order by g.preco) as rn, count(*) over () as n from g where g.preco is not null)
  select string_agg(E'\n• ' || rk.texto || ': ' || private.brl(rk.preco), '' order by rk.preco) into v_linhas
    from rk where rk.n <= 5 or rk.rn in (1, 1 + (rk.n - 1) / 4, 1 + (rk.n - 1) / 2, 1 + (3 * (rk.n - 1)) / 4, rk.n);
  if v_linhas is null then return null; end if;
  return format('Oi, %s! Vi que você veio pelo nosso anúncio de %s. Separei algumas opções de %s unidades (%s mm), da mais em conta à mais completa:%s' || E'\n\n' || 'O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros. Qual dessas faz mais sentido pra você?',
                p_nome, lower(v_head), v_q, coalesce(v_t, 'padrão'), v_linhas);
end $$;
revoke all on function private.fu_texto_anuncio(uuid, text) from public, anon, authenticated;

-- Agendamento: conversa de anúncio com uma única mensagem do cliente, sem pedido nem orçamento
create or replace function private.fu_agendar_anuncio(p_agora timestamptz default now()) returns integer
language plpgsql security definer set search_path = '' as $$
declare r public.followup_regras%rowtype; v_n integer := 0;
begin
  select * into r from public.followup_regras where codigo = 'Q1_ANUNCIO' and ativo;
  if not found then return 0; end if;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, teste)
  select cv.contact_id, cv.id, r.codigo, r.codigo || ':' || cv.id::text,
         private.fu_proxima_janela(ult.criado + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max),
         'teste' = any (coalesce(ct.tags, '{}'))
    from public.conversations cv join public.contacts ct on ct.id = cv.contact_id
    cross join lateral (select max(m.created_at) as criado from public.messages m where m.conversation_id = cv.id) ult
   where (cv.last_referral is not null or ct.first_referral is not null)
     and cv.last_inbound_at > p_agora - interval '20 hours'
     and (select count(*) from public.messages m where m.conversation_id = cv.id and m.direction = 'in') = 1
     and coalesce(cv.modo_atendimento, 'ia') = 'ia' and not coalesce(ct.optout, false)
     and not exists (select 1 from public.orders xo where xo.contact_id = cv.contact_id and xo.excluido_em is null)
     and not exists (select 1 from public.orcamentos o where o.contact_id = cv.contact_id)
  on conflict (chave) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function private.fu_agendar_anuncio(timestamptz) from public, anon, authenticated;

-- followup_agendar e followup_montar viram invólucros: a lógica antiga continua intacta em private.*_base
do $$
begin
  if to_regprocedure('private.followup_agendar_base(timestamptz)') is null then
    alter function public.followup_agendar(timestamptz) set schema private;
    alter function private.followup_agendar(timestamptz) rename to followup_agendar_base;
  end if;
  if to_regprocedure('private.followup_montar_base(uuid,timestamptz)') is null then
    alter function public.followup_montar(uuid, timestamptz) set schema private;
    alter function private.followup_montar(uuid, timestamptz) rename to followup_montar_base;
  end if;
end $$;
revoke all on function private.followup_agendar_base(timestamptz) from public, anon, authenticated;
revoke all on function private.followup_montar_base(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.followup_agendar(p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_ad integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  v := private.followup_agendar_base(p_agora);
  begin v_ad := private.fu_agendar_anuncio(p_agora); exception when others then raise warning 'agendar anúncio: %', sqlerrm; end;
  return v || jsonb_build_object('anuncio', v_ad);
end $$;
revoke all on function public.followup_agendar(timestamptz) from public, anon;
grant execute on function public.followup_agendar(timestamptz) to authenticated, service_role;

create or replace function public.followup_montar(p_fila uuid, p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.followup_fila%rowtype; cv public.conversations%rowtype; ct public.contacts%rowtype; v_texto text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila;
  if not found then return private.followup_montar_base(p_fila, p_agora); end if;

  if f.regra_codigo = 'Q1' and exists (select 1 from public.followup_fila x where x.conversation_id = f.conversation_id and x.regra_codigo = 'Q1_ANUNCIO' and x.status in ('enviado', 'reservado')) then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'opcoes_do_anuncio_ja_enviadas');
  end if;
  if f.regra_codigo <> 'Q1_ANUNCIO' then return private.followup_montar_base(p_fila, p_agora); end if;

  select * into cv from public.conversations where id = f.conversation_id;
  select * into ct from public.contacts where id = f.contact_id;
  if cv.id is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'sem_conversa'); end if;
  if cv.last_inbound_at > f.criado_em then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'cliente_respondeu'); end if;
  if cv.last_inbound_at is null or cv.last_inbound_at + interval '24 hours' < p_agora then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'janela_fechada'); end if;
  if exists (select 1 from public.orcamentos o where o.contact_id = f.contact_id) or exists (select 1 from public.orders x where x.contact_id = f.contact_id and x.excluido_em is null) then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'ja_tem_orcamento');
  end if;
  v_texto := private.fu_texto_anuncio(cv.id, private.fu_nome(ct.name));
  if v_texto is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'anuncio_sem_produto'); end if;
  return jsonb_build_object('ok', true, 'acao', 'enviar', 'via', 'livre', 'texto', v_texto, 'template', null, 'params', null,
    'conversation_id', cv.id, 'regra', f.regra_codigo, 'janela_ate', cv.last_inbound_at + interval '24 hours', 'com_condicao', false,
    'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
end $$;
revoke all on function public.followup_montar(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.followup_montar(uuid, timestamptz) to service_role;
