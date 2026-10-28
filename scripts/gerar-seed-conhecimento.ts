// Gera a migration de carga inicial do banco de conhecimento a partir de supabase/seed/conhecimento.json (fonte única dos 90 trechos).
// Uso: node scripts/gerar-seed-conhecimento.ts
// A carga é idempotente (ON CONFLICT DO NOTHING pelo slug): editar um trecho pela tela do CRM nunca é sobrescrito por uma nova execução.
import { readFileSync, writeFileSync } from 'node:fs'

interface Trecho { slug: string; titulo: string; categoria: string; quando_usar: string; resposta_pronta: string; fatos: string; proximo_passo: string; tags: string[]; revisar: boolean }

const root = new URL('..', import.meta.url).pathname
const trechos: Trecho[] = JSON.parse(readFileSync(`${root}supabase/seed/conhecimento.json`, 'utf8'))
const q = (s: string) => {
  if (s.includes('$q$')) throw new Error(`texto com $q$: ${s}`)
  return `$q$${s}$q$`
}

const linhas = trechos.map((t) =>
  `  (${q(t.slug)}, ${q(t.titulo)}, ${q(t.categoria)}, ${q(t.quando_usar)}, ${q(t.resposta_pronta)}, ${q(t.fatos)}, ${q(t.proximo_passo)}, array[${t.tags.map(q).join(', ')}]::text[])`)

const faq: [string, string][] = [
  ['qual o horario de funcionamento', 'empresa-horario'], ['que horas voces abrem', 'empresa-horario'], ['voces aceitam pix', 'pag-pix'], ['aceita pix', 'pag-pix'],
  ['tem pedido minimo', 'compra-minimo'], ['qual o cnpj de voces', 'empresa-cnpj'], ['voce e um robo', 'robo-honesto'], ['posso retirar ai', 'frete-retirada'],
  ['a retirada e gratis', 'frete-retirada'], ['tem boleto', 'pag-boleto'], ['qual o endereco', 'empresa-endereco'], ['onde fica a loja', 'obj-ir-ai'],
]

const sql = `-- Agente de IA, Etapa 2: carga inicial do banco de conhecimento (${trechos.length} trechos) e do cache de perguntas frequentes.
-- GERADO por scripts/gerar-seed-conhecimento.ts a partir de supabase/seed/conhecimento.json. Não edite à mão: edite o JSON e gere de novo.
-- Todos os trechos nascem com revisar = true. Idempotente: nunca sobrescreve um trecho que o dono já editou.
-- Os vetores (gte-small) são gerados pela Edge Function "conhecimento" (reindexação automática a cada 5 minutos ou botão Reindexar na tela).

insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
select v.slug, v.titulo, v.categoria, v.quando_usar, v.resposta_pronta, v.fatos, v.proximo_passo, v.tags, 'carga inicial da Etapa 2', true, true
from (values
${linhas.join(',\n')}
) as v (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags)
on conflict (slug) where slug is not null do nothing;

insert into public.faq_cache (pergunta_norm, pergunta, resposta, trecho_id)
select private.norm_busca(f.pergunta), f.pergunta, k.resposta_pronta, k.id
from (values
${faq.map(([p, s]) => `  (${q(p)}, ${q(s)})`).join(',\n')}
) as f (pergunta, slug)
join public.conhecimento k on k.slug = f.slug
on conflict (pergunta_norm) do nothing;
`
writeFileSync(`${root}supabase/migrations/20261029000005_conhecimento_seed.sql`, sql)
console.log(`gerado: ${trechos.length} trechos, ${faq.length} perguntas no cache`)
