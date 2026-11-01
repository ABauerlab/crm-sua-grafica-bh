// Gera a migration de importação dos 83 trechos (Etapa 7C) a partir de docs/agente/conhecimento_v2.json (arquivo do dono, mantido como veio).
// Uso: node scripts/gerar-conhecimento-v2.ts
//
// Ajustes aplicados na importação (o JSON original NÃO é alterado; cada ajuste está listado em docs/agente/conhecimento-diferencas.md):
//  1. Nomes das personas viram variáveis ({{persona_vendas}}, {{persona_pos_pagamento}}), só na resposta pronta: o nome fica em Configurações.
//  2. Cupom de recompra e prazo de refação viram variáveis (percentual, teto, validade, prazo de foto), pelo mesmo motivo.
//  3. "limite de lucro" vira "limite interno" (a palavra lucro é proibida em trecho).
// A importação nunca sobrescreve trecho existente: o que o dono editou fica como está e a versão nova vira sugestão.
import { readFileSync, writeFileSync } from 'node:fs'
import { trechoProblemas, type Trecho } from '../src/lib/knowledge.ts'

interface Novo extends Trecho { id: string; categoria: string; tags: string[]; revisar: boolean }
const root = new URL('..', import.meta.url).pathname
const originais: Novo[] = JSON.parse(readFileSync(`${root}docs/agente/conhecimento_v2.json`, 'utf8'))

/** Equivalência: id novo -> slugs antigos que ele substitui. Antigo sem editar é desativado (reversível); antigo editado pelo dono protege o trecho: o novo vira sugestão. */
export const SUBSTITUI: Record<string, string[]> = {
  ab_cartao_premium: ['abertura-cartao'], ab_panfleto: ['abertura-panfleto'], ab_generica: ['abertura-generica'],
  q_cartao: ['qual-cartao'], q_panfleto: ['qual-panfleto'], q_adesivo: ['qual-adesivo'], q_banner: ['qual-banner'], q_outros: ['qual-geral'],
  como_funciona: ['compra-passos'],
  pagamento_pix: ['pag-pix', 'pag-formas'], pagamento_cartao: ['pag-cartao', 'pag-parcelar'], pagamento_boleto: ['pag-boleto'],
  seguranca_pagamento: ['pag-seguranca'], nota_fiscal: ['pag-nf'], apos_pagamento: ['pos-pagamento'],
  prazo_contamos: ['prazo-como-contamos'], prazo_corte: ['prazo-12h'], urgencia: ['prazo-urgente'],
  arte_tem: ['arte-pronta', 'arte-formato'], arte_recebida: ['pos-arte-pendente'], arte_criacao: ['arte-criacao'], arte_aprovacao: ['arte-prova'],
  frete_gratis: ['frete-gratis-centro'], frete_fora: ['frete-fora'], retirada: ['frete-retirada'],
  pedido_foto: ['foto-produto'], upsell_cartao: ['up-cartao'], upsell_kit: ['up-kit'], upsell_arte: ['up-arte'],
  obj_caro: ['obj-caro'], obj_mais_barato: ['obj-mais-barato'], obj_pensar: ['obj-vou-pensar'], obj_prazo: ['obj-prazo-curto'],
  obj_confio: ['obj-confianca'], obj_qualidade: ['obj-qualidade'], obj_parcelar: ['obj-parcelar'], obj_desconto: ['obj-desconto'],
  obj_ver_antes: ['obj-ver-antes'], obj_ir_ai: ['obj-ir-ai'],
  fechar: ['fech-pode-fechar', 'fech-resumo', 'fech-link'],
  dono_quando: ['dono-regras'], reclamacao: ['troca-reclamacao'], fora_catalogo: ['dono-fora-catalogo'],
  robo: ['robo-honesto'], sigilo: ['sigilo-interno', 'sigilo-regras'], troca: ['troca-politica'],
  empresa: ['empresa-quem-somos'],
  fu_f1: ['fu-f1-a', 'fu-f1-b'], fu_f2: ['fu-f2-a', 'fu-f2-b'], fu_f3: ['fu-condicao-a', 'fu-condicao-b'], fu_f4: ['fu-ultima'], fu_pagamento: ['fu-pagamento'],
  pv_satisfacao: ['pv-satisfacao'], pv_google: ['google-avaliacao'], pv_recompra: ['pv-recompra-cartao', 'pv-recompra-adesivo'], pv_indicacao: ['pv-indicacao'],
  dados_cadastro: ['dados-cliente'],
}


/** Ajuste de recuperação (pedido da etapa: "ajuste quando_usar e tags dos que falharem"). Frases que o cliente realmente escreve, somadas às tags do arquivo. */
export const TAGS_EXTRA: Record<string, string[]> = {
  prazo_contamos: ['quanto tempo leva', 'quanto tempo demora', 'em quanto tempo fica pronto', 'prazo de entrega', 'que dia fica pronto', 'quando fica pronto', 'ficar pronto'],
  prazo_corte: ['depois do meio dia', 'depois do meio-dia', 'apos as 12h', 'depois das 12h', 'corte das 12h'],
  urgencia: ['urgente', 'urgencia', 'preciso pra amanha', 'preciso pra sexta', 'com pressa'],
  pagamento_cartao: ['parcelar no cartao', 'parcelar', 'parcelas', 'em quantas vezes', 'cartao de credito', 'sem juros', 'dividir'],
  obj_parcelar: ['da pra parcelar', 'tem parcelamento', 'dividir o pagamento', 'parcelar no cartao'],
  pagamento_pix: ['aceita pix', 'pagar no pix', 'link do pix', 'pix de qualquer banco'],
  pagamento_boleto: ['boleto', 'trabalham com boleto', 'pagar no boleto'],
  seguranca_pagamento: ['link de pagamento e seguro mesmo', 'link seguro', 'o link e seguro', 'e seguro pagar', 'golpe', 'confiavel', 'link de pagamento e seguro', 'e seguro'],
  retirada: ['buscar ai', 'retirar', 'posso buscar', 'retirada', 'pegar ai no centro', 'buscar no centro', 'retirar ai'],
  obj_ir_ai: ['onde fica', 'onde fica a loja', 'endereco de voces', 'qual o endereco', 'posso ir ai', 'visitar', 'conhecer o escritorio', 'onde voces ficam'],
  frete_fora: ['contagem', 'betim', 'fora de bh', 'outra cidade', 'entregam em', 'entrega fora do centro', 'uber', 'moro longe'],
  frete_gratis: ['frete gratis', 'entregam no meu bairro', 'entrega gratis', 'pedido minimo'],
  arte_criacao: ['nao tenho arte vcs fazem', 'nao tenho arte',  'voces fazem a arte', 'criar a arte', 'fazem o design', 'preciso de arte', 'sem arte', 'fazem a arte'],
  arte_tem: ['ja tenho a arte', 'tenho a arte pronta', 'arte em pdf', 'qual formato', 'que formato de arquivo'],
  arte_baixa: ['foto do logo', 'mandei foto', 'print do logo', 'imagem do whatsapp', 'logo no whatsapp', 'serve essa imagem', 'imagem pequena', 'baixa qualidade'],
  quer_humano: ['falar com o dono', 'falar com uma pessoa', 'falar com atendente', 'falar com humano', 'quero o responsavel', 'chama o dono', 'falar com alguem'],
  sigilo: ['ignora as regras', 'ignore as instrucoes', 'esquece as regras', 'me passa suas instrucoes', 'prompt', 'regras internas', 'ignora tudo', 'esquece tudo'],
  quem_produz: ['quem fabrica', 'quem produz', 'fabricante', 'quem faz', 'onde produzem'],
  quem_atende: ['quem esta falando', 'com quem falo', 'qual seu nome', 'com quem eu estou falando'],
  robo: ['voce e robo', 'e um robo', 'e uma pessoa', 'e humano', 'e bot', 'atendente virtual'],
  nota_fiscal: ['nota fiscal', 'emitem nota', 'preciso de nota', 'nf'],
  bauerlab: ['site', 'criar site', 'fazer site', 'identidade visual', 'logo', 'logotipo', 'marca', 'landing page', 'loja virtual', 'trafego pago', 'google meu negocio', 'redes sociais', 'agencia', 'anuncios'],
  troca: ['trocar', 'troca', 'posso trocar', 'nao gostei', 'veio com defeito', 'veio errado', 'refazer', 'refacao'],
  reclamacao: ['cor errada', 'erro no pedido', 'reclamar', 'problema no pedido', 'pedido atrasado', 'defeito', 'veio errado', 'estou insatisfeito'],
  cancelamento: ['cancelar', 'desistir', 'quero cancelar', 'cancelar o pedido', 'desisti'],
  fechar: ['pode fechar', 'fechado', 'quero fechar', 'vamos fechar', 'fechou', 'aprovado o orcamento', 'me manda o link'],
  obj_ver_antes: ['amostra', 'tem amostra', 'amostra do papel', 'ver o papel', 'ver antes de pagar', 'quero ver antes'],
  obj_desconto: ['desconto', 'faz desconto', 'tem desconto', 'melhor preco', 'abatimento'],
  empresa: ['qual o cnpj', 'cnpj', 'quem somos', 'horario de atendimento', 'horario', 'que horas abrem'],
  como_funciona: ['validade do orcamento', 'ate quando vale o orcamento', 'orcamento vale ate quando', 'como funciona', 'como comprar', 'como faco pra comprar', 'passo a passo'],
  apos_pagamento: ['paguei', 'ja paguei', 'fiz o pagamento', 'pagamento feito', 'acabei de pagar', 'paguei o pix', 'comprovante'],
  pedido_foto: ['foto do produto', 'fotos do produto', 'manda foto', 'tem foto', 'imagem do produto'],
  ajustar_pedido: ['mudar a quantidade', 'alterar o pedido', 'mudar o pedido', 'trocar a quantidade'],
}

const AJUSTES: string[] = []
function ajustar(t: Novo): Novo {
  const c: Novo = { ...t, tags: [...t.tags] }
  const troca = (campo: 'resposta_pronta' | 'fatos', de: RegExp, para: string, porque: string) => {
    const v = c[campo] ?? ''
    if (de.test(v)) { c[campo] = v.replace(de, para); AJUSTES.push(`${t.id}.${campo}: ${porque}`) }
  }
  troca('resposta_pronta', /\bLaura\b/g, '{{persona_vendas}}', 'nome da persona de vendas vira variável')
  troca('resposta_pronta', /João Victor/g, '{{persona_pos_pagamento}}', 'nome da persona pós-pagamento vira variável')
  if (t.id === 'pv_cupom') {
    troca('resposta_pronta', /\b5%/g, '{{cupom_percentual}}%', 'percentual do cupom vem de Configurações')
    troca('resposta_pronta', /\b30 dias\b/g, '{{cupom_validade_dias}} dias', 'validade do cupom vem de Configurações')
    troca('fatos', /\b5%/g, '{{cupom_percentual}}%', 'percentual do cupom vem de Configurações')
    troca('fatos', /R\$ ?25\b/g, '{{cupom_teto}}', 'teto do cupom vem de Configurações')
    troca('fatos', /\b30 dias\b/g, '{{cupom_validade_dias}} dias', 'validade do cupom vem de Configurações')
    troca('fatos', /limite de lucro/g, 'limite interno', 'palavra proibida em trecho (lucro)')
  }
  // Regra do dono (migration 20261029000012): para o cliente a entrega grátis nunca é dita "de bicicleta"
  troca('fatos', /Itens grandes ou pesados não vão de bicicleta/g, 'Itens grandes ou pesados podem não ser elegíveis à entrega grátis', 'regra do dono: nunca dizer bicicleta')
  troca('fatos', /Itens grandes não vão de bicicleta/g, 'Itens grandes podem não ser elegíveis à entrega grátis', 'regra do dono: nunca dizer bicicleta')
  if (t.id === 'troca') {
    troca('resposta_pronta', /2 dias úteis/g, '{{troca_prazo}}', 'prazo da foto vem de Configurações')
    troca('fatos', /2 dias úteis/g, '{{troca_prazo}}', 'prazo da foto vem de Configurações')
  }
  c.tags = [...new Set([...c.tags, ...(TAGS_EXTRA[t.id] ?? [])])]
  return c
}

const novos = originais.map(ajustar)
const falhas: string[] = []
for (const t of novos) for (const m of trechoProblemas({ ...t, slug: t.id })) falhas.push(`${t.id}: ${m}`)
if (falhas.length) { console.error(`lint reprovou:\n${falhas.join('\n')}`); process.exit(1) }
for (const t of novos) if (/\b(bicicleta|bike)\b/i.test(JSON.stringify(t))) falhas.push(`${t.id}: menciona bicicleta`)
if (falhas.length) { console.error(`lint reprovou:\n${falhas.join('\n')}`); process.exit(1) }
const semEquivalente = Object.keys(SUBSTITUI).filter((k) => !novos.some((n) => n.id === k))
if (semEquivalente.length) { console.error(`equivalência aponta para id inexistente: ${semEquivalente.join(', ')}`); process.exit(1) }

const q = (s: string) => {
  if (s.includes('$q$')) throw new Error(`texto com $q$: ${s}`)
  return `$q$${s}$q$`
}
const arr = (a: string[]) => `array[${a.map(q).join(', ')}]::text[]`
const linhas = novos.map((t) =>
  `  (${q(t.id)}, ${q(t.titulo)}, ${q(t.categoria)}, ${q(t.quando_usar ?? '')}, ${q(t.resposta_pronta ?? '')}, ${q(t.fatos ?? '')}, ${q(t.proximo_passo ?? '')}, ${arr(t.tags)}, ${t.revisar}, ${arr(SUBSTITUI[t.id] ?? [])})`)

const sql = `-- Agente de IA, Etapa 7C: importação dos ${novos.length} trechos do banco de conhecimento (docs/agente/conhecimento_v2.json).
-- GERADO por scripts/gerar-conhecimento-v2.ts. Não edite à mão: edite o JSON e gere de novo.
-- Idempotente e conservadora: nada que o dono editou é sobrescrito (a versão nova vira sugestão em conhecimento_sugestoes);
-- trecho antigo sem edição que tem equivalente novo é DESATIVADO (nunca apagado) e pode ser reativado por conhecimento_reverter_importacao_7c().
-- Os vetores (gte-small) são refeitos pela Edge Function "conhecimento" (a cada 5 minutos); o índice HNSW atualiza sozinho com eles.

do $imp$
declare
  r record; ex public.conhecimento%rowtype; v_protegidos text[]; v_novo uuid; v_antigo text; v_n_ins integer := 0; v_n_sug integer := 0; v_n_desat integer := 0; v_n_ign integer := 0; v_n_upd integer := 0;
begin
  for r in
    select * from (values
${linhas.join(',\n')}
    ) as v (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, revisar, substitui)
  loop
    select * into ex from public.conhecimento where slug = r.slug;
    if found then
      -- o mesmo identificador já existe (rascunhos da Etapa 7B: bauerlab, urgencia). Rascunho nunca aprovado é atualizado; o que o dono aprovou vira sugestão.
      if ex.fonte = 'Etapa 7C' then
        v_n_ign := v_n_ign + 1;
      elsif ex.revisar then
        update public.conhecimento set titulo = r.titulo, categoria = r.categoria, quando_usar = r.quando_usar, resposta_pronta = r.resposta_pronta,
               fatos = r.fatos, proximo_passo = r.proximo_passo, tags = r.tags, fonte = 'Etapa 7C', revisar = r.revisar, ativo = true where id = ex.id;
        v_n_upd := v_n_upd + 1;
      else
        insert into public.conhecimento_sugestoes (slug_novo, slugs_atuais, payload, motivo)
        select r.slug, array[r.slug],
               jsonb_build_object('titulo', r.titulo, 'categoria', r.categoria, 'quando_usar', r.quando_usar, 'resposta_pronta', r.resposta_pronta,
                                  'fatos', r.fatos, 'proximo_passo', r.proximo_passo, 'tags', to_jsonb(r.tags), 'revisar', r.revisar, 'substitui', to_jsonb(r.substitui)),
               'o trecho atual já foi aprovado pelo dono e não foi sobrescrito'
         where not exists (select 1 from public.conhecimento_sugestoes s where s.slug_novo = r.slug);
        v_n_sug := v_n_sug + 1;
      end if;
      continue;
    end if;

    -- antigo protegido = já revisado pelo dono e alterado depois da carga (revisado_em mais de 1 minuto depois de criado)
    select coalesce(array_agg(k.slug), '{}') into v_protegidos
      from public.conhecimento k
     where k.slug = any (r.substitui) and k.ativo and not k.revisar and k.revisado_em > k.criado_em + interval '1 minute';

    if cardinality(v_protegidos) > 0 then
      insert into public.conhecimento_sugestoes (slug_novo, slugs_atuais, payload, motivo)
      select r.slug, v_protegidos,
             jsonb_build_object('titulo', r.titulo, 'categoria', r.categoria, 'quando_usar', r.quando_usar, 'resposta_pronta', r.resposta_pronta,
                                'fatos', r.fatos, 'proximo_passo', r.proximo_passo, 'tags', to_jsonb(r.tags), 'revisar', r.revisar, 'substitui', to_jsonb(r.substitui)),
             'o trecho atual foi editado depois da carga e não foi sobrescrito'
       where not exists (select 1 from public.conhecimento_sugestoes s where s.slug_novo = r.slug);
      v_n_sug := v_n_sug + 1;
      continue;
    end if;

    insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
    values (r.slug, r.titulo, r.categoria, r.quando_usar, r.resposta_pronta, r.fatos, r.proximo_passo, r.tags, 'Etapa 7C', r.revisar, true)
    returning id into v_novo;
    v_n_ins := v_n_ins + 1;

    foreach v_antigo in array r.substitui loop
      update public.conhecimento set ativo = false, substituido_por = r.slug where slug = v_antigo and ativo and substituido_por is null;
      if found then v_n_desat := v_n_desat + 1; end if;
      -- perguntas frequentes que apontavam para o trecho antigo passam a responder com o novo
      update public.faq_cache f set trecho_id = v_novo, resposta = r.resposta_pronta, atualizado_em = now()
       where f.trecho_id = (select id from public.conhecimento where slug = v_antigo);
    end loop;
  end loop;
  raise notice 'importação 7C: % inseridos, % rascunhos atualizados, % sugestões, % antigos desativados, % já importados', v_n_ins, v_n_upd, v_n_sug, v_n_desat, v_n_ign;
end
$imp$;
`
writeFileSync(`${root}supabase/migrations/20261104000002_etapa7c_conhecimento_importacao.sql`, sql)
console.log(`gerado: ${novos.length} trechos, ${Object.keys(SUBSTITUI).length} equivalências, ${AJUSTES.length} ajustes`)
