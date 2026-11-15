-- Alerta de "sessão da VPS caiu" só depois de 3 verificações seguidas falhando; persona e base de conhecimento sem "assistente virtual".
-- Aditiva e idempotente (já aplicada em produção).
alter table public.origem_sessao add column if not exists falhas_seguidas integer not null default 0;

create or replace function public.origem_sessao_registrar(p_token text, p_logado boolean, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_ok text; v_antes boolean; v_falhas integer; v_agora boolean;
begin
  select valor into v_ok from public.app_segredos where chave = 'origem_sessao_token';
  if v_ok is null or p_token is distinct from v_ok then return jsonb_build_object('ok', false); end if;
  select logado, falhas_seguidas into v_antes, v_falhas from public.origem_sessao where id;
  if p_logado then
    update public.origem_sessao set logado = true, motivo = left(p_motivo, 200), atualizado_em = now(), falhas_seguidas = 0 where id;
    return jsonb_build_object('ok', true, 'antes', v_antes, 'agora', true);
  end if;
  v_falhas := coalesce(v_falhas, 0) + 1;
  v_agora := case when v_falhas >= 3 then false else coalesce(v_antes, true) end;
  update public.origem_sessao set logado = v_agora, motivo = left(p_motivo, 200), atualizado_em = now(), falhas_seguidas = v_falhas where id;
  if v_falhas = 3 then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform public.alerta_criar('origem_sessao_expirada', 'alta', null, null, null,
      'A sessão logada no site do fornecedor caiu (3 verificações seguidas falharam). Abra o navegador da VPS e entre de novo para a Laura voltar a conferir preço e tamanho ao vivo.',
      jsonb_build_object('motivo', left(p_motivo, 200)));
  end if;
  return jsonb_build_object('ok', true, 'antes', v_antes, 'agora', v_agora, 'falhas_seguidas', v_falhas);
end $$;

update public.app_settings set value = jsonb_set(value, '{apresentacao}', '"atendente da Sua Gráfica BH"') where key = 'personas';
update public.conhecimento set
  resposta_pronta = case when slug in ('robo', 'robo-honesto') then 'Sou a Laura, do atendimento da Sua Gráfica BH! Cuido de tudo por aqui e, se preferir falar com o dono, eu chamo ele pra você. Posso seguir por aqui?'
    else replace(replace(resposta_pronta, ', assistente virtual da Sua Gráfica BH', ' da Sua Gráfica BH'), 'assistente virtual', 'atendente') end,
  fatos = replace(replace(replace(replace(coalesce(fatos, ''),
      'Não negar que é assistente virtual.', 'Nunca afirmar que é pessoa nem usar as palavras assistente virtual, IA ou robô.'),
      'Ambos são nomes do mesmo assistente virtual e tudo é automático.', 'Ambos são nomes da atendente da gráfica.'),
      'o assistente virtual', 'a atendente'), 'do assistente virtual', 'da atendente'),
  embedding = null, embedding_em = null, atualizado_em = now()
 where resposta_pronta ilike '%assistente virtual%' or fatos ilike '%assistente virtual%';
