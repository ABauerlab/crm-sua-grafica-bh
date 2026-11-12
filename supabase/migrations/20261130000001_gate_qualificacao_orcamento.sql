-- Trava de qualificação: o PDF do orçamento só sai pelo agente depois que a conversa tiver sido de fato consultiva.
-- Motivo (11/11/2026, primeira venda automática): a Laura enviou o PDF 1 minuto depois de fazer uma pergunta, sem esperar a
-- resposta, e orçou sacola 4x0 para quem pediu frente e verso, com o tamanho da ARTE (465 x 285) no lugar do tamanho final.
-- A decisão é do banco, não do prompt. Chamada pela Edge Function orcamento-pdf apenas quando quem pede é o servidor (agente).
-- Aditiva e idempotente.

create or replace function public.orcamento_gate_qualificacao(p_orcamento uuid, p_ate timestamptz default null, p_ignorar_envio boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  o record; v_ate timestamptz := coalesce(p_ate, now()); v_desde timestamptz;
  v_perg timestamptz; v_ins int; v_txt text; v_forma boolean; v_zero boolean; v_especifico boolean;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select q.id, q.conversation_id, q.pdf_enviado_em into o from public.orcamentos q where q.id = p_orcamento;
  if not found or o.conversation_id is null then return jsonb_build_object('pode', true); end if;
  -- reenvio do mesmo orçamento (já enviado antes) não passa de novo pela trava
  if o.pdf_enviado_em is not null and not p_ignorar_envio then return jsonb_build_object('pode', true); end if;

  select coalesce(cv.contexto_desde, '-infinity'::timestamptz) into v_desde from public.conversations cv where cv.id = o.conversation_id;

  select string_agg(m.body, ' | ' order by m.created_at), count(*) into v_txt, v_ins
    from public.messages m
   where m.conversation_id = o.conversation_id and m.direction = 'in' and m.type = 'text' and m.deleted_at is null
     and m.created_at > v_desde and m.created_at <= v_ate and m.body is not null;
  v_txt := coalesce(v_txt, '');

  -- 1) Pergunta do agente ainda sem resposta do cliente
  select max(m.created_at) into v_perg
    from public.messages m
   where m.conversation_id = o.conversation_id and m.direction = 'out' and m.type = 'text' and m.sent_by is null
     and m.deleted_at is null and m.created_at > v_desde and m.created_at <= v_ate and m.body ~ '\?';
  if v_perg is not null and not exists (
      select 1 from public.messages m
       where m.conversation_id = o.conversation_id and m.direction = 'in' and m.deleted_at is null
         and m.created_at > v_perg and m.created_at <= v_ate) then
    return jsonb_build_object('pode', false, 'motivo', 'aguardando_resposta_do_cliente',
      'orientacao', 'Você acabou de fazer uma pergunta e o cliente ainda não respondeu. Não envie o orçamento agora: espere a resposta e só então monte e envie o PDF.');
  end if;

  -- 2) Conversa curta demais, a não ser que o cliente tenha chegado com o pedido específico (medida e quantidade)
  v_especifico := v_txt ~* '[0-9]+([.,][0-9]+)?\s*(x|×|por)\s*[0-9]+' and v_txt ~* '[0-9]{2,}';
  if v_ins < 2 and not v_especifico then
    return jsonb_build_object('pode', false, 'motivo', 'qualificacao_incompleta',
      'orientacao', 'Ainda falta entender o que o cliente precisa (produto, tamanho, quantidade, arte e prazo). Faça no máximo duas perguntas, espere a resposta e só então envie o orçamento.');
  end if;

  -- 3) Cliente pediu frente e verso, mas o item orçado só imprime um lado (cores do tipo 4x0 ou 1x0)
  v_forma := v_txt ~* '(frente\s*(e|/|\+)\s*verso|dois lados|2 lados|ambos os lados|\m4x4\M|\m1x1\M)';
  select bool_or(c.cores ~* '^[0-9]x0$') into v_zero
    from public.orcamento_itens i join public.catalogo c on c.sku = i.sku where i.orcamento_id = o.id;
  if v_forma and coalesce(v_zero, false) then
    return jsonb_build_object('pode', false, 'motivo', 'impressao_frente_verso_indisponivel',
      'orientacao', 'O cliente pediu frente e verso, mas o item escolhido imprime só um lado. Procure com buscar_produto uma opção com impressão nos dois lados (4x4). Se não existir, explique com honestidade que esse modelo imprime só um lado e pergunte se serve. Nunca diga que cobre frente e verso se o item não cobre.');
  end if;

  -- 4) Produtos em 3D (sacola, caixa, envelope): o tamanho do catálogo é o da ARTE planificada, não o do produto pronto
  if exists (select 1 from public.orcamento_itens i join public.catalogo c on c.sku = i.sku
              where i.orcamento_id = o.id and c.categoria in ('SACOLAS E SACOS', 'CAIXAS E EMBALAGENS', 'ENVELOPES', 'COBRE CAIXAS'))
     and v_txt !~* '([0-9]+([.,][0-9]+)?\s*(x|×|por)\s*[0-9]+|[0-9]\s*(cm|mm))' then
    return jsonb_build_object('pode', false, 'motivo', 'tamanho_final_nao_confirmado',
      'orientacao', 'Este produto é uma embalagem e o cliente ainda não disse o tamanho que precisa. Pergunte a largura, a profundidade e a altura finais da peça pronta (ou o que vai dentro dela) e o modelo preferido. O tamanho do catálogo é o da arte planificada: nunca o apresente como tamanho do produto.');
  end if;

  return jsonb_build_object('pode', true);
end $$;

revoke execute on function public.orcamento_gate_qualificacao(uuid, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.orcamento_gate_qualificacao(uuid, timestamptz, boolean) to service_role;
