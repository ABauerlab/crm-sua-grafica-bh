// Gera a migration dos trechos de conhecimento adaptados dos estudos do dono (rodada 18/11/2026) a partir de docs/agente/conhecimento_rodada18.json.
// Uso: node scripts/gerar-conhecimento-rodada18.ts
// Só ADITIVO: nunca sobrescreve trecho existente (slug que já existe é ignorado). Os vetores (gte-small) são refeitos pela Edge Function "conhecimento".
import { readFileSync, writeFileSync } from 'node:fs'
import { trechoProblemas, type Trecho } from '../src/lib/knowledge.ts'

interface Novo extends Trecho { id: string; categoria: string; tags: string[]; revisar: boolean }
const root = new URL('..', import.meta.url).pathname
const novos: Novo[] = JSON.parse(readFileSync(`${root}docs/agente/conhecimento_rodada18.json`, 'utf8'))

const falhas: string[] = []
for (const t of novos) for (const m of trechoProblemas({ ...t, slug: t.id })) falhas.push(`${t.id}: ${m}`)
if (new Set(novos.map((t) => t.id)).size !== novos.length) falhas.push('ids repetidos')
if (falhas.length) { console.error(`lint reprovou:\n${falhas.join('\n')}`); process.exit(1) }

const q = (s: string) => {
  if (s.includes('$q$')) throw new Error(`texto com $q$: ${s}`)
  return `$q$${s}$q$`
}
const arr = (a: string[]) => `array[${a.map(q).join(', ')}]::text[]`
const linhas = novos.map((t) => `  (${q(t.id)}, ${q(t.titulo)}, ${q(t.categoria)}, ${q(t.quando_usar ?? '')}, ${q(t.resposta_pronta ?? '')}, ${q(t.fatos ?? '')}, ${q(t.proximo_passo ?? '')}, ${arr(t.tags)}, ${t.revisar})`)

const sql = `-- Rodada 18/11/2026: ${novos.length} trechos de conhecimento adaptados dos estudos do dono (docs/agente/conhecimento_rodada18.json).
-- GERADO por scripts/gerar-conhecimento-rodada18.ts. Não edite à mão: edite o JSON e gere de novo.
-- Aditivo e idempotente: slug que já existe é ignorado (nada que o dono editou é sobrescrito). Todos nascem com revisar = true.
-- Os vetores (gte-small) são refeitos pela Edge Function "conhecimento" (cron de 5 minutos).

insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
select v.slug, v.titulo, v.categoria, v.quando_usar, v.resposta_pronta, v.fatos, v.proximo_passo, v.tags, 'Estudos do dono (18/11/2026)', v.revisar, true
  from (values
${linhas.join(',\n')}
  ) as v (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, revisar)
 where not exists (select 1 from public.conhecimento k where k.slug = v.slug);

-- Correção: o horário de corte da produção é 10h30 em dia útil (decisão do dono de 17/11/2026), e cinco trechos antigos ainda diziam 12h.
-- Vetor zerado para o cron refazer. Idempotente (só mexe onde ainda existe 12h).
update public.conhecimento
   set titulo = replace(titulo, '12h', '10h30'), resposta_pronta = replace(resposta_pronta, '12h', '10h30'), fatos = replace(fatos, '12h', '10h30'), embedding = null
 where slug in ('fu_f2', 'prazo_corte', 'obj_prazo', 'obj_pensar', 'prazo_contamos')
   and (titulo like '%12h%' or resposta_pronta like '%12h%' or fatos like '%12h%');
`
writeFileSync(`${root}supabase/migrations/20261218000004_conhecimento_estudos_do_dono.sql`, sql)
console.log(`OK: ${novos.length} trechos, migration escrita`)
