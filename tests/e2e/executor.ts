// Executor: leva um cenário até o fluxo real (webhook de teste do WF1 no n8n, modelo real, ferramentas reais do banco)
// SEM enviar nada ao WhatsApp (o modo de teste grava a saída em testes_conversa; aqui ela é copiada para e2e_mensagens).
import type { Cenario, Contexto, Espera, Falha, MensagemDialogo, ResultadoConversa, Turno } from './tipos.ts'
import { PERSONAS } from './personas.ts'
import { verificarDialogo, normalizar } from './verificacoes.ts'

export interface Config {
  supabaseUrl: string
  chaveServico: string
  n8nTesteUrl: string
  rodada: string
  /** Tempo máximo de espera por turno, em ms. */
  esperaMaxMs: number
  /** Intervalo mínimo entre chamadas ao n8n (respeita limites; fotos: 1 por segundo). */
  intervaloMs: number
  valoresFixos: number[]
}

export function lerConfig(env = process.env): Config {
  const faltam = ['E2E_SUPABASE_URL', 'E2E_SERVICE_KEY', 'E2E_N8N_TESTE_URL'].filter((k) => !env[k])
  if (faltam.length) throw new Error(`defina ${faltam.join(', ')} (veja tests/e2e/README.md)`)
  return {
    supabaseUrl: env.E2E_SUPABASE_URL!.replace(/\/$/, ''),
    chaveServico: env.E2E_SERVICE_KEY!,
    n8nTesteUrl: env.E2E_N8N_TESTE_URL!,
    rodada: env.E2E_RODADA ?? new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12),
    esperaMaxMs: Number(env.E2E_ESPERA_MAX_MS ?? 180000),
    intervaloMs: Number(env.E2E_INTERVALO_MS ?? 1100),
    valoresFixos: (env.E2E_VALORES_FIXOS ?? '39.9,49.9,150').split(',').map(Number).filter(Number.isFinite),
  }
}

export class Banco {
  url: string
  chave: string
  f: typeof fetch
  constructor(url: string, chave: string, f: typeof fetch = fetch) { this.url = url; this.chave = chave; this.f = f }
  h(extra: Record<string, string> = {}) { return { apikey: this.chave, authorization: `Bearer ${this.chave}`, 'content-type': 'application/json', ...extra } }
  async consultar<T = Record<string, unknown>>(tabela: string, query: string): Promise<T[]> {
    const r = await this.f(`${this.url}/rest/v1/${tabela}?${query}`, { headers: this.h() })
    if (!r.ok) throw new Error(`consulta ${tabela} falhou (${r.status})`)
    return (await r.json()) as T[]
  }
  async inserir<T = Record<string, unknown>>(tabela: string, linha: unknown): Promise<T> {
    const r = await this.f(`${this.url}/rest/v1/${tabela}`, { method: 'POST', headers: this.h({ prefer: 'return=representation' }), body: JSON.stringify(linha) })
    if (!r.ok) throw new Error(`inserção em ${tabela} falhou (${r.status})`)
    return ((await r.json()) as T[])[0]
  }
  async apagar(tabela: string, query: string): Promise<void> {
    const r = await this.f(`${this.url}/rest/v1/${tabela}?${query}`, { method: 'DELETE', headers: this.h() })
    if (!r.ok) throw new Error(`exclusão em ${tabela} falhou (${r.status})`)
  }
  async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    const r = await this.f(`${this.url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: this.h(), body: JSON.stringify(args) })
    if (!r.ok) throw new Error(`rpc ${fn} falhou (${r.status})`)
    return (await r.json()) as T
  }
}

export class Orcamento {
  usado = 0
  avisou = false
  teto: number
  constructor(teto: number) { this.teto = teto }
  gastar(tokens: number): void {
    this.usado += tokens
    if (!this.avisou && this.usado >= this.teto * 0.8) {
      this.avisou = true
      console.warn(`AVISO: ${Math.round((this.usado / this.teto) * 100)}% do teto de tokens do teste (${this.usado} de ${this.teto}).`)
    }
  }
  get estourou() { return this.usado >= this.teto }
}

const dormir = (ms: number) => new Promise((r) => setTimeout(r, ms))
let ultimaChamada = 0
async function respeitarIntervalo(ms: number) {
  const espera = ultimaChamada + ms - Date.now()
  ultimaChamada = Math.max(Date.now(), ultimaChamada + ms)
  if (espera > 0) await dormir(espera)
}

const variante = (v: string[], f: number) => v[Math.min(f - 1, v.length - 1)] ?? ''

export function montarEntradas(cen: Cenario, turno: Turno, indice: number, formulacao: number, conversaId?: string) {
  const preparar = [...(indice === 0 ? cen.preparar ?? [] : []), ...(turno.preparar ?? [])]
  return {
    nome: PERSONAS[cen.persona]?.nome.split(',')[0] ?? 'Cliente',
    ...(indice === 0 && cen.anuncio ? { anuncio: cen.anuncio } : {}),
    ...(conversaId ? { continuar_conversation: conversaId } : {}),
    preparar,
    mensagens: turno.cliente.map((f) => ({ tipo: f.tipo ?? 'text', texto: variante(f.variantes, formulacao) })),
  }
}

export function avaliarEspera(esp: Espera | undefined, turno: number, saidas: string[], ferramentas: string[], temAlerta: boolean): Falha[] {
  if (!esp) return []
  const f: Falha[] = []
  const falha = (codigo: string, detalhe: string): Falha => ({ codigo, gravidade: 'alta', detalhe: `turno ${turno}: ${detalhe}`, origem: 'deterministica' })
  const texto = normalizar(saidas.join('\n'))
  for (const x of esp.ferramentas ?? []) if (!ferramentas.includes(x)) f.push(falha(`faltou_ferramenta:${x}`, `a ferramenta ${x} não foi chamada`))
  for (const x of esp.semFerramentas ?? []) if (ferramentas.includes(x)) f.push(falha(`ferramenta_indevida:${x}`, `a ferramenta ${x} não deveria ter sido chamada`))
  if (esp.contemAlgum?.length && !esp.contemAlgum.some((r) => new RegExp(r, 'i').test(texto))) f.push(falha('faltou_texto_esperado', `esperava algum de: ${esp.contemAlgum.join(', ')}`))
  for (const r of esp.naoContem ?? []) if (new RegExp(r, 'i').test(texto)) f.push(falha('texto_proibido', `apareceu ${r}`))
  if (esp.semResposta && saidas.length > 0) f.push(falha('respondeu_quando_devia_calar', `${saidas.length} mensagem(ns)`))
  if (!esp.semResposta && saidas.length === 0) f.push(falha('nenhuma_resposta', 'o agente não respondeu'))
  if (esp.alerta && !temAlerta) f.push(falha('faltou_alerta_ao_dono', 'nenhum alerta foi gravado'))
  return f
}

const reOptout = /^\s*(parar|pare)\b|pare de me|nao quero mais receber|n[ãa]o quero mais receber/i

export async function executar(cen: Cenario, formulacao: number, cfg: Config, banco: Banco, orc: Orcamento): Promise<ResultadoConversa> {
  const dialogo: MensagemDialogo[] = []
  const falhas: Falha[] = []
  let conversaId: string | undefined
  let contatoId: string | undefined
  let pagoDesdeTurno: number | null = cen.preparar?.includes('pedido_pago') ? 1 : null
  let optoutNoTurno: number | null = null
  let tokens = 0
  let custo = 0
  let ferramentas: string[] = []
  const casos: string[] = []
  try {
    for (let i = 0; i < cen.turnos.length; i++) {
      if (orc.estourou) throw new Error('teto de tokens do teste atingido')
      const turno = cen.turnos[i]
      const n = i + 1
      if (pagoDesdeTurno === null && turno.preparar?.includes('pedido_pago')) pagoDesdeTurno = n
      const falasTexto = turno.cliente.map((f) => variante(f.variantes, formulacao))
      if (optoutNoTurno === null && falasTexto.some((t) => reOptout.test(t))) optoutNoTurno = n
      const entradas = montarEntradas(cen, turno, i, formulacao, conversaId)
      const nome = `e2e-${cfg.rodada}-${cen.id}-f${formulacao}-t${n}`
      const caso = await banco.inserir<{ id: string }>('testes_conversa', { nome, descricao: `E2E 8B ${cen.titulo}`, entradas, esperado: { sem_vazamento: true } })
      casos.push(caso.id)
      await respeitarIntervalo(cfg.intervaloMs)
      const resp = await fetch(cfg.n8nTesteUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ caso_id: caso.id, limpar: false }) })
      if (!resp.ok) throw new Error(`webhook de teste respondeu ${resp.status}`)
      const limite = Date.now() + cfg.esperaMaxMs
      let linha: { ultimo_status: string | null; ultimo_resultado: { saidas?: string[]; conversation_id?: string; contact_id?: string } } | undefined
      while (Date.now() < limite) {
        const [l] = await banco.consultar<NonNullable<typeof linha>>('testes_conversa', `id=eq.${caso.id}&select=ultimo_status,ultimo_resultado`)
        if (l?.ultimo_status) { linha = l; break }
        await dormir(2000)
      }
      if (!linha) throw new Error(`o turno ${n} não terminou em ${cfg.esperaMaxMs / 1000}s`)
      conversaId = linha.ultimo_resultado.conversation_id
      contatoId = linha.ultimo_resultado.contact_id
      const saidas = linha.ultimo_resultado.saidas ?? []
      for (const t of falasTexto) dialogo.push({ de: 'cliente', texto: t, turno: n })
      for (const s of saidas) dialogo.push({ de: 'agente', texto: s, turno: n })
      for (const t of falasTexto) await banco.inserir('e2e_mensagens', { rodada: cfg.rodada, cenario: cen.id, formulacao, turno: n, direcao: 'cliente', texto: t, contact_id: contatoId, conversation_id: conversaId })
      for (const s of saidas) await banco.inserir('e2e_mensagens', { rodada: cfg.rodada, cenario: cen.id, formulacao, turno: n, direcao: 'agente', texto: s, contact_id: contatoId, conversation_id: conversaId })

      const logs = await banco.consultar<{ ferramenta: string }>('agent_logs', `conversation_id=eq.${conversaId}&action=eq.ferramenta&select=ferramenta`)
      ferramentas = [...new Set(logs.map((l) => l.ferramenta).filter(Boolean))]
      const alertas = await banco.consultar('alertas', `conversation_id=eq.${conversaId}&select=id&limit=1`)
      falhas.push(...avaliarEspera(turno.espera, n, saidas, ferramentas, alertas.length > 0))
    }
    const exec = await banco.consultar<{ valores_vistos: number[] | null; tokens_entrada: number | null; tokens_saida: number | null; custo_estimado: number | null }>('agente_execucoes', `conversation_id=eq.${conversaId}&select=valores_vistos,tokens_entrada,tokens_saida,custo_estimado`)
    tokens = exec.reduce((s, e) => s + (e.tokens_entrada ?? 0) + (e.tokens_saida ?? 0), 0)
    custo = exec.reduce((s, e) => s + Number(e.custo_estimado ?? 0), 0)
    orc.gastar(tokens)
    const logsResultado = await banco.consultar<{ result: unknown }>('agent_logs', `conversation_id=eq.${conversaId}&select=result`)
    const linksDasFerramentas = JSON.stringify(logsResultado.map((l) => l.result)).match(/https?:\/\/[^\s"\\)]+/g) ?? []
    const orcs = await banco.consultar<{ link_pagamento: string | null }>('orcamentos', `contact_id=eq.${contatoId}&select=link_pagamento`)
    const valoresOrc = (await banco.consultar<Record<string, number | null>>('orcamentos', `contact_id=eq.${contatoId}&select=subtotal,total,frete_valor,arte_valor,desconto_valor`)).flatMap((o) => Object.values(o)).filter((v): v is number => v != null).map(Number)
    const ctx: Contexto = {
      valoresPermitidos: [...exec.flatMap((e) => e.valores_vistos ?? []).map(Number), ...valoresOrc, ...cfg.valoresFixos],
      pagoDesdeTurno,
      linksValidos: [...linksDasFerramentas, ...orcs.map((o) => o.link_pagamento).filter((x): x is string => !!x)],
      ferramentas,
      optoutNoTurno,
    }
    falhas.push(...verificarDialogo(dialogo, ctx))
    await checarTravaDeLucro(banco, contatoId!, falhas)
    return { cenario: cen.id, formulacao, dialogo, ferramentas, tokens, custo, falhasDeterministicas: falhas }
  } catch (e) {
    return { cenario: cen.id, formulacao, dialogo, ferramentas, tokens, custo, falhasDeterministicas: falhas, erro: (e as Error).message }
  } finally {
    for (const id of casos) await banco.apagar('testes_conversa', `id=eq.${id}`).catch(() => undefined)
  }
}

export const checarFalhaDeLucro = (): Falha => ({ codigo: 'preco_abaixo_da_trava_de_lucro', gravidade: 'critica', detalhe: 'item de orçamento abaixo do piso duro ou com lucro líquido negativo', origem: 'deterministica' })

/** Preço abaixo da trava de lucro: nenhum item de orçamento do contato pode ter preço abaixo do piso duro nem lucro negativo. */
export async function checarTravaDeLucro(banco: Banco, contatoId: string, falhas: Falha[]): Promise<void> {
  const orcs = await banco.consultar<{ id: string; numero: string; lucro_liquido: number | null }>('orcamentos', `contact_id=eq.${contatoId}&select=id,numero,lucro_liquido`)
  for (const o of orcs) {
    const itens = await banco.consultar<{ valor_total: number | null; piso_duro: number | null; piso: number | null; lucro_liquido: number | null }>('orcamento_itens', `orcamento_id=eq.${o.id}&select=valor_total,piso_duro,piso,lucro_liquido`)
    for (const it of itens) {
      const abaixoDoDuro = it.piso_duro != null && it.valor_total != null && Number(it.valor_total) + 0.005 < Number(it.piso_duro)
      if (abaixoDoDuro || (it.lucro_liquido != null && Number(it.lucro_liquido) < -0.005)) {
        falhas.push({ codigo: 'preco_abaixo_da_trava_de_lucro', gravidade: 'critica', detalhe: `orçamento ${o.numero}: item abaixo do piso duro ou com lucro negativo`, origem: 'deterministica' })
      }
    }
  }
}
