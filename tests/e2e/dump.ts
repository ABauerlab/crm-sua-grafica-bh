// Modo "retratos": quando o executor não tem a chave de serviço (sessão de agente via MCP), cada turno é executado com as
// funções e2e_criar_caso/e2e_aguardar do banco e os retratos viram arquivos JSON. Este módulo transforma os retratos em
// ResultadoConversa e aplica as mesmas verificações determinísticas do executor.
import { avaliarEspera, checarFalhaDeLucro } from './executor.ts'
import { PERSONAS } from './personas.ts'
import type { Cenario, Contexto, Falha, MensagemDialogo, ResultadoConversa } from './tipos.ts'
import { verificarDialogo } from './verificacoes.ts'

export interface Retrato {
  status: string | null
  saidas: string[]
  ferramentas: string[]
  valores_vistos: number[]
  /** Totais e itens dos orçamentos do contato (montados por ferramenta ou pelo preparo do cenário). */
  valores_orcamentos?: number[]
  links_vistos: string[]
  links_orcamento: string[]
  tokens: number
  custo: number
  alerta: boolean
  violacao_lucro: boolean
}
export interface DumpConversa {
  cenario: string
  formulacao: number
  turnos: { n: number; cliente: string[]; snapshot: Retrato }[]
}

export const variante = (v: string[], f: number) => v[Math.min(f - 1, v.length - 1)] ?? ''
const reOptout = /^\s*(parar|pare)\b|pare de me|nao quero mais receber|n[ãa]o quero mais receber/i

/** Plano de um cenário: as entradas de cada turno (o id da conversa entra no lugar de __CONVERSA__ a partir do turno 2). */
export function planoDoCenario(cen: Cenario, formulacao: number, rodada: string) {
  return {
    cenario: cen.id, formulacao, persona: PERSONAS[cen.persona]?.nome ?? cen.persona,
    turnos: cen.turnos.map((t, i) => ({
      n: i + 1,
      nome_caso: `e2e-${rodada}-${cen.id}-f${formulacao}-t${i + 1}`,
      cliente: t.cliente.map((f) => variante(f.variantes, formulacao)),
      entradas: {
        nome: (PERSONAS[cen.persona]?.nome ?? 'Cliente').split(',')[0],
        ...(i === 0 && cen.anuncio ? { anuncio: cen.anuncio } : {}),
        ...(i > 0 ? { continuar_conversation: '__CONVERSA__' } : {}),
        preparar: [...(i === 0 ? cen.preparar ?? [] : []), ...(t.preparar ?? [])],
        mensagens: t.cliente.map((f) => ({ tipo: f.tipo ?? 'text', texto: variante(f.variantes, formulacao) })),
      },
    })),
  }
}

export function resultadoDoDump(cen: Cenario, d: DumpConversa, valoresFixos = [39.9, 49.9, 150]): ResultadoConversa {
  const dialogo: MensagemDialogo[] = []
  const falhas: Falha[] = []
  let pagoDesdeTurno: number | null = cen.preparar?.includes('pedido_pago') ? 1 : null
  let optoutNoTurno: number | null = null
  for (const t of d.turnos) {
    const turno = cen.turnos[t.n - 1]
    if (pagoDesdeTurno === null && turno?.preparar?.includes('pedido_pago')) pagoDesdeTurno = t.n
    if (optoutNoTurno === null && t.cliente.some((x) => reOptout.test(x))) optoutNoTurno = t.n
    for (const c of t.cliente) dialogo.push({ de: 'cliente', texto: c, turno: t.n })
    for (const s of t.snapshot.saidas) dialogo.push({ de: 'agente', texto: s, turno: t.n })
    falhas.push(...avaliarEspera(turno?.espera, t.n, t.snapshot.saidas, t.snapshot.ferramentas, t.snapshot.alerta))
  }
  const ultimo = d.turnos[d.turnos.length - 1]?.snapshot
  const ctx: Contexto = {
    valoresPermitidos: [...d.turnos.flatMap((t) => [...t.snapshot.valores_vistos, ...(t.snapshot.valores_orcamentos ?? [])]).map(Number), ...valoresFixos],
    pagoDesdeTurno,
    linksValidos: d.turnos.flatMap((t) => [...t.snapshot.links_vistos, ...t.snapshot.links_orcamento]),
    ferramentas: ultimo?.ferramentas ?? [],
    optoutNoTurno,
  }
  falhas.push(...verificarDialogo(dialogo, ctx))
  if (d.turnos.some((t) => t.snapshot.violacao_lucro)) falhas.push(checarFalhaDeLucro())
  const semStatus = d.turnos.find((t) => !t.snapshot.status)
  return {
    cenario: cen.id, formulacao: d.formulacao, dialogo, ferramentas: ctx.ferramentas,
    tokens: ultimo?.tokens ?? 0, custo: ultimo?.custo ?? 0, falhasDeterministicas: falhas,
    erro: semStatus ? `o turno ${semStatus.n} não terminou no tempo` : undefined,
  }
}
