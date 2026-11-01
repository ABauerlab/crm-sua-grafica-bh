-- Agente de IA, Etapa 4B: trecho de conhecimento sobre pedido de foto. Idempotente: não sobrescreve se o dono já editou.
-- (O mesmo trecho está em supabase/seed/conhecimento.json, que o lint do npm test confere.)
insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
select * from (values (
  'foto-produto', 'Cliente pede foto do produto', 'guia',
  'Cliente pede foto, imagem, exemplo ou como fica o produto.',
  'Claro! Vou te mandar umas fotos pra você ver como fica. Depois me conta a quantidade e se já tem a arte que eu monto seu orçamento.',
  'Use a ferramenta de foto, no máximo 3 imagens por pedido. A foto pode ser ilustrativa do acabamento e o produto final pode variar. Se não houver foto, diga que vai confirmar com a equipe. Nunca diga de onde veio a imagem.',
  'Depois das fotos, perguntar quantidade e arte e oferecer o orçamento em PDF.',
  array['foto','tem foto','manda foto','me mostra','quero ver como fica','foto do produto','tem exemplo','como fica','imagem do produto','tem imagem'],
  'carga da Etapa 4B', true, true)) as v (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
where not exists (select 1 from public.conhecimento k where k.slug = v.slug);
