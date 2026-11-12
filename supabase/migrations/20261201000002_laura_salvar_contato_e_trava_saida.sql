-- Aplicadas em produção em 12/11/2026 (resumo; os trechos de função foram aplicados por substituição sobre a definição vigente):
-- * contacts.quer_nota_fiscal (boolean, default false): agente_salvar_contato gravava nela e a coluna não existia (toda chamada falhava).
-- * contacts_segment_check alargado (barbearia, delivery, loja, outro, alimentacao, varejo, servicos, saude, beleza, educacao, eventos, construcao, automotivo, outros).
-- * agente_contexto_base: consentimento "none" não conta como "já cadastrado".
-- * agente_saida_base_execucao: "margem" só barra margem de lucro, não "margem de segurança/sangria/corte".
-- * agente_salvar_contato: marketing_consent como texto (opted_in/opted_out); resetar_chat_completo limpa quer_nota_fiscal.
alter table public.contacts add column if not exists quer_nota_fiscal boolean not null default false;
alter table public.contacts drop constraint if exists contacts_segment_check;
alter table public.contacts add constraint contacts_segment_check check (segment is null or segment = any (array['barbearia','delivery','loja','outro','alimentacao','varejo','servicos','saude','beleza','educacao','eventos','construcao','automotivo','outros']));
