-- Lembrete de conversa parada (Q1/Q2): só retoma a venda, sem citar quantidade nem repetir pergunta. Aplicada pelo conector.
create or replace function private.fu_texto_q(p_regra text, p_conv uuid, p_nome text, p_var integer)
returns text language plpgsql stable security definer set search_path = '' as $$
begin
  if p_regra = 'Q1' then
    return case p_var
      when 0 then format('Oi, %s! Assim que puder, me dá uma resposta por aqui pra gente já seguir com o seu orçamento e conseguir te entregar o seu material o quanto antes, combinado?', p_nome)
      else format('Oi, %s! Passando pra gente não perder o fio: quando puder me responder aqui, eu já sigo com o seu orçamento e garanto a entrega o mais rápido possível. Pode ser?', p_nome) end;
  elsif p_regra = 'Q2' then
    return format('Oi, %s! Última chamada: se ainda fizer sentido pra você, é só me responder por aqui que eu já sigo com o seu orçamento e te entrego o material o quanto antes. Posso contar com você?', p_nome);
  end if;
  return null;
end $$;
