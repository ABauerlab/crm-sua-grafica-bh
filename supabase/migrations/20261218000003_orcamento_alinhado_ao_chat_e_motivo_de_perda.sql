-- Rodada 18/11/2026 (parte 2). Aplicada pelo conector em duas partes (motivo_de_perda_e_alerta_de_preco_diferente e montar_orcamento_alinha_preco_com_o_chat).
-- 1) Correção na raiz do preço diferente do combinado: montar_orcamento passa a conferir o último valor único dito ao cliente (60 min) e, se nenhum item bate,
--    troca o item pelo equivalente (mesma categoria e quantidade) cujo preço de calcular_preco é o valor combinado. Nunca bloqueia o atendimento.
--    Causa do caso Patrícia (17/11): CRT0007 (R$ 177,90) e CRT0002 (R$ 159,90) são o mesmo cartão (mesma categoria, tamanho, cores e quantidade).
-- 2) Motivo de perda gravado na recusa explícita do cliente.
-- 3) Rede de segurança: alerta baixo se o PDF sair com valor diferente do último valor dito (não deveria mais acontecer).
-- Aditiva e idempotente.

create or replace function private.motivo_perda_trg() returns trigger
language plpgsql security definer set search_path = '' as $f$
declare v_ct uuid; v_mot text; v_id uuid;
begin
  if new.direction <> 'in' or new.body is null or new.type not in ('text', 'audio') then return new; end if;
  if new.body !~* '(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|^\W*obrigad[oa]\W*$|n[aã]o (quero|preciso|tenho interesse|faz sentido|vou (querer|seguir|fechar|precisar))|sem interesse|desist|j[aá] (fechei|resolvi|comprei|contratei)|por enquanto n[aã]o|n[aã]o por enquanto|talvez (depois|mais pra frente)|fica (pra|para) (depois|outra vez)|j[aá] tenho (gr[aá]fica|fornecedor)|n[aã]o,? obrigad|vou (pensar|ver) (depois|com calma|melhor))' then return new; end if;
  select cv.contact_id into v_ct from public.conversations cv where cv.id = new.conversation_id;
  select o.id into v_id from public.orcamentos o
   where o.contact_id = v_ct and o.status = 'enviado' and o.motivo_perda is null and o.criado_em > now() - interval '10 days' and coalesce(o.teste, false) = false
   order by o.criado_em desc limit 1;
  if v_id is null then return new; end if;
  v_mot := case when new.body ~* '(caro|pre[cç]o|valor|barato|desconto|or[cç]amento mais baixo|fora do (meu )?or[cç]amento|n[aã]o cabe)' then 'preco'
                when new.body ~* '(prazo|demora|urgente|n[aã]o d[aá] tempo|a tempo)' then 'prazo'
                when new.body ~* '(vou (pensar|ver)|depois|mais pra frente|outra vez|com calma)' then 'decidiu_depois'
                else 'outro' end;
  update public.orcamentos set motivo_perda = v_mot, motivo_perda_em = now() where id = v_id;
  return new;
exception when others then
  raise warning 'motivo_perda_trg falhou: %', sqlerrm;
  return new;
end $f$;
revoke all on function private.motivo_perda_trg() from public, anon, authenticated;
drop trigger if exists trg_motivo_perda on public.messages;
create trigger trg_motivo_perda after insert on public.messages for each row execute function private.motivo_perda_trg();

create or replace function private.preco_pdf_diferente_trg() returns trigger
language plpgsql security definer set search_path = '' as $f$
declare v_body text; v_vals numeric[]; v_ok numeric[]; v_dito numeric;
begin
  if new.pdf_enviado_em is null or new.pdf_enviado_em is not distinct from old.pdf_enviado_em or coalesce(new.teste, false) then return new; end if;
  select m.body into v_body from public.messages m join public.conversations cv on cv.id = m.conversation_id
   where cv.contact_id = new.contact_id and m.direction = 'out' and m.deleted_at is null and m.body ~ 'R\$ ?[0-9]' and m.body !~ '^\[Or[cç]amento' and m.created_at between new.pdf_enviado_em - interval '90 minutes' and new.pdf_enviado_em - interval '5 seconds'
   order by m.created_at desc limit 1;
  if v_body is null then return new; end if;
  v_vals := array(select replace(replace((x)[1], '.', ''), ',', '.')::numeric from regexp_matches(v_body, 'R\$ ?([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2})', 'g') x);
  if coalesce(array_length(v_vals, 1), 0) <> 1 then return new; end if;
  v_dito := v_vals[1];
  v_ok := array[new.total, new.subtotal, new.arte_valor, new.frete_valor] || array(select i.valor_total from public.orcamento_itens i where i.orcamento_id = new.id)
          || array(select i.preco_unitario from public.orcamento_itens i where i.orcamento_id = new.id);
  if exists (select 1 from unnest(v_ok) x where x is not null and abs(x - v_dito) < 0.011) then return new; end if;
  perform public.alerta_criar('agente_chamado', 'baixa', new.contact_id, new.conversation_id, new.order_id,
    'O orçamento ' || new.numero || ' saiu com total R$ ' || to_char(new.total, 'FM999G999D00') || ', mas o último valor dito no chat foi R$ ' || to_char(v_dito, 'FM999G999D00') || '. Confira se a Laura explicou a diferença ao cliente.',
    jsonb_build_object('orcamento_id', new.id, 'origem', 'preco_pdf_diferente'), 'preco_pdf:' || new.id, null);
  return new;
exception when others then
  raise warning 'preco_pdf_diferente_trg falhou: %', sqlerrm;
  return new;
end $f$;
revoke all on function private.preco_pdf_diferente_trg() from public, anon, authenticated;
drop trigger if exists trg_preco_pdf_diferente on public.orcamentos;
create trigger trg_preco_pdf_diferente after update of pdf_enviado_em on public.orcamentos for each row execute function private.preco_pdf_diferente_trg();

do $m$
begin
  if to_regprocedure('private.montar_orcamento_base(uuid,jsonb,jsonb)') is null then
    alter function public.montar_orcamento(uuid, jsonb, jsonb) set schema private;
    alter function private.montar_orcamento(uuid, jsonb, jsonb) rename to montar_orcamento_base;
  end if;
end $m$;

create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_body text; v_vals numeric[]; v_dito numeric; v_novos jsonb := '[]'::jsonb; it jsonb; v_hit boolean := false; v_trocou boolean := false;
  v_sku text; v_q integer; v_cat text; v_un integer; v_alt text; v_res jsonb; v_cand jsonb := '[]'::jsonb; v_pos integer := 0; v_pos_troca integer; v_sku_novo text;
begin
  begin
    if jsonb_typeof(p_itens) = 'array' and jsonb_array_length(p_itens) between 1 and 10 and p_contact is not null then
      select m.body into v_body from public.messages m join public.conversations cv on cv.id = m.conversation_id
       where cv.contact_id = p_contact and m.direction = 'out' and m.deleted_at is null and m.body ~ 'R\$ ?[0-9]' and m.body !~ '^\[Or[cç]amento'
         and m.created_at > now() - interval '60 minutes'
       order by m.created_at desc limit 1;
      if v_body is not null then
        v_vals := array(select replace(replace((x)[1], '.', ''), ',', '.')::numeric from regexp_matches(v_body, 'R\$ ?([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2})', 'g') x);
        if coalesce(array_length(v_vals, 1), 0) = 1 then
          v_dito := v_vals[1];
          for it in select * from jsonb_array_elements(p_itens) loop
            v_pos := v_pos + 1;
            v_sku := upper(btrim(coalesce(it ->> 'sku', ''))); v_q := greatest(1, coalesce((it ->> 'quantidade')::integer, 1));
            if v_sku = '' then continue; end if;
            if it ? 'acabamento' or it ? 'largura_mm' or it ? 'altura_mm' then v_hit := true; continue; end if;
            if abs(coalesce((public.calcular_preco(v_sku, v_q, '{}'::jsonb) ->> 'preco_total')::numeric, -1) - v_dito) < 0.011 then v_hit := true; end if;
          end loop;
          if not v_hit then
            v_pos := 0;
            for it in select * from jsonb_array_elements(p_itens) loop
              v_pos := v_pos + 1;
              v_sku := upper(btrim(coalesce(it ->> 'sku', ''))); v_q := greatest(1, coalesce((it ->> 'quantidade')::integer, 1));
              select c.categoria, c.quantidade into v_cat, v_un from public.catalogo c where c.sku = v_sku;
              if v_cat is null then continue; end if;
              select c2.sku into v_alt from public.catalogo c2
               where c2.categoria = v_cat and c2.quantidade = v_un and c2.sku <> v_sku and c2.active and c2.vendavel and c2.preco_venda is not null
                 and abs(coalesce((public.calcular_preco(c2.sku, v_q, '{}'::jsonb) ->> 'preco_total')::numeric, -1) - v_dito) < 0.011
               order by c2.sku limit 1;
              if v_alt is not null then v_cand := v_cand || jsonb_build_array(jsonb_build_object('pos', v_pos, 'sku', v_alt)); v_alt := null; end if;
            end loop;
            if jsonb_array_length(v_cand) = 1 then
              v_pos_troca := (v_cand -> 0 ->> 'pos')::integer; v_sku_novo := v_cand -> 0 ->> 'sku'; v_pos := 0;
              for it in select * from jsonb_array_elements(p_itens) loop
                v_pos := v_pos + 1;
                v_novos := v_novos || jsonb_build_array(case when v_pos = v_pos_troca then jsonb_set(it, '{sku}', to_jsonb(v_sku_novo)) else it end);
              end loop;
              p_itens := v_novos; v_trocou := true;
            end if;
          end if;
        end if;
      end if;
    end if;
  exception when others then
    raise warning 'montar_orcamento: alinhamento com o chat ignorado: %', sqlerrm;
  end;
  v_res := private.montar_orcamento_base(p_contact, p_itens, p_opcoes);
  if v_trocou and jsonb_typeof(v_res) = 'object' then
    v_res := v_res || jsonb_build_object('alinhado_ao_chat', true, 'orientacao_alinhamento', 'O item foi ajustado para o mesmo valor que você combinou com o cliente. Use os valores desta resposta e não mencione troca de item.');
  end if;
  return v_res;
end $f$;
revoke all on function public.montar_orcamento(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.montar_orcamento(uuid, jsonb, jsonb) to authenticated, service_role;
