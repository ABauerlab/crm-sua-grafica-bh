-- Etapa 4, correção 3: cole inteiro no SQL Editor do Supabase (idempotente). É a migration 20261029000012.
-- O cliente (PDF e respostas do agente) não vê mais que a entrega grátis é de bicicleta. A regra interna não muda.

-- Regra do dono: para o cliente, a entrega grátis na região central NÃO diz que é de bicicleta (nem no PDF, nem nas respostas do agente).
-- A regra interna (peso, maior lado, saídas por dia, custo) continua igual. Aditiva e idempotente.

-- 1) Textos devolvidos pelas funções (o agente repete o que elas devolvem)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.montar_orcamento(uuid,jsonb,jsonb)'::regprocedure);
  if d like '%Entrega grátis de bicicleta na região central%' then
    execute replace(d, 'Entrega grátis de bicicleta na região central', 'Entrega grátis na região central');
  end if;
  -- o agente também não recebe o código interno "bike_gratis"
  d := pg_get_functiondef('public.montar_orcamento(uuid,jsonb,jsonb)'::regprocedure);
  if d like '%''modo'', v_frete_modo, ''valor'', 0, ''texto'', v_frete_txt%' then
    execute replace(d, '''modo'', v_frete_modo, ''valor'', 0, ''texto'', v_frete_txt', '''modo'', case v_frete_modo when ''bike_gratis'' then ''entrega_gratis'' else v_frete_modo end, ''valor'', 0, ''texto'', v_frete_txt');
  end if;
  d := pg_get_functiondef('public.verificar_frete(text,jsonb,numeric,boolean)'::regprocedure);
  if d like '%grátis de bicicleta, em horário comercial%' then
    execute replace(d, 'grátis de bicicleta, em horário comercial', 'grátis na região central, em horário comercial');
  end if;
end $$;

-- 2) Banco de conhecimento (o que o agente responde). Editar o conteúdo volta a pedir revisão; a segunda passada marca como revisado (decisão do dono).
update public.conhecimento set
  fatos = 'A medida define o que existe no catálogo. Perguntar medida, local de uso, se quer acabamento com ilhós. Banner grande pode não ser elegível à entrega grátis: confira com a ferramenta de frete.'
where slug = 'qual-banner';

update public.conhecimento set
  resposta_pronta = 'Na região central de BH a entrega é grátis a partir de {{pedido_minimo}}. Me diz o seu bairro ou CEP que eu confiro.',
  fatos = 'O frete é grátis na região central quando o pedido atinge o mínimo e o tamanho é elegível. Quem pega o pacote de arte com frete não precisa do mínimo. Confirme sempre com a ferramenta de frete. Não diga como a entrega é feita nem o meio de transporte.'
where slug = 'frete-gratis-centro';

update public.conhecimento set
  titulo = 'Como é a entrega na região central',
  resposta_pronta = 'A entrega na região central é feita em horário comercial, em uma ou duas saídas por dia. Te aviso quando sair.',
  fatos = 'Entregas só em horário comercial, agrupadas em uma ou duas saídas por dia. Pedido muito pesado ou grande não é elegível e vai por Uber ou retirada. Não diga qual é o meio de transporte da entrega.'
where slug = 'frete-bike';

update public.conhecimento set
  titulo = 'Pedido grande demais para a entrega grátis',
  resposta_pronta = 'Esse pedido é grandinho pra entrega grátis, então a entrega seria por Uber. Ou você retira aqui no centro, de graça. Qual prefere?'
where slug = 'frete-tamanho';

-- Só marca como revisado se o resto do banco já estava revisado (como em produção, onde o dono marcou os 90 trechos); numa carga nova tudo continua para revisar.
update public.conhecimento set revisar = false
where slug in ('qual-banner', 'frete-gratis-centro', 'frete-bike', 'frete-tamanho') and revisar
  and not exists (select 1 from public.conhecimento k where k.revisar and k.slug not in ('qual-banner', 'frete-gratis-centro', 'frete-bike', 'frete-tamanho'));
