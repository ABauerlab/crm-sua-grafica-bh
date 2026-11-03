// Tipos do teste ponta a ponta do atendimento (Etapa 8B).

export type Categoria =
  | 'anuncio' | 'funil' | 'objecao' | 'produto' | 'entrega' | 'pagamento'
  | 'arte' | 'excecao' | 'tecnico' | 'followup'

/** Uma fala do cliente. `variantes` tem as 3 formulações (índice 0 a 2); se faltar, usa a primeira. */
export interface FalaCliente {
  tipo?: 'text' | 'audio' | 'image' | 'document'
  /** Texto (ou transcrição, no caso de áudio) por formulação. */
  variantes: string[]
}

/** Um turno: o cliente manda uma ou mais mensagens picadas (juntadas pelo debounce) e o agente responde. */
export interface Turno {
  cliente: FalaCliente[]
  /** Ações de preparo antes do turno (mesma lista de `agente_teste_preparar`: orcamento_aberto, pedido_pago, optout, falha_ferramenta:x, sem_falha). */
  preparar?: string[]
  /** Verificações específicas deste turno, em cima das respostas dele. */
  espera?: Espera
}

export interface Espera {
  /** Ferramentas que precisam ter sido chamadas até aqui. */
  ferramentas?: string[]
  /** Ferramentas que NÃO podem ter sido chamadas neste turno. */
  semFerramentas?: string[]
  /** Alguma destas expressões tem de aparecer nas respostas do turno (regex, sem acento e minúsculas). */
  contemAlgum?: string[]
  /** Nenhuma destas expressões pode aparecer. */
  naoContem?: string[]
  /** O agente não pode responder neste turno (opt-out, modo humano, pagamento confirmado). */
  semResposta?: boolean
  /** Exige alerta ao dono. */
  alerta?: boolean
}

export interface Cenario {
  id: string
  categoria: Categoria
  titulo: string
  persona: string
  /** Falha crítica possível: roda no subconjunto --critico. */
  critico?: boolean
  /** Anúncio de origem (referral) ou nenhum. */
  anuncio?: { headline: string; source_id: string; source_type?: string; body?: string } | null
  /** Preparo inicial (orcamento_aberto, pedido_pago, modo_humano, optout...). */
  preparar?: string[]
  turnos: Turno[]
  /** O que o juiz deve olhar com mais atenção neste cenário. */
  foco?: string
  /** Cenários só de banco (sem modelo): consulta SQL que precisa devolver `ok = true`. */
  sql?: string
}

export type Gravidade = 'critica' | 'alta' | 'media' | 'baixa'

export interface Falha {
  codigo: string
  gravidade: Gravidade
  frase?: string
  detalhe?: string
  origem: 'deterministica' | 'juiz'
}

export interface MensagemDialogo {
  de: 'cliente' | 'agente'
  texto: string
  turno: number
}

export interface Contexto {
  /** Valores em R$ que as ferramentas devolveram ou que são fixos (arte, pedido mínimo...). */
  valoresPermitidos: number[]
  /** Número do turno (1 a N) a partir do qual o contato já pagou; null se nunca pagou. */
  pagoDesdeTurno: number | null
  /** Links de pagamento que o banco registrou como válidos (validar_margem passou). */
  linksValidos: string[]
  /** Ferramentas chamadas na conversa inteira. */
  ferramentas: string[]
  /** Turno em que o cliente pediu para parar (opt-out); null se não pediu. */
  optoutNoTurno: number | null
}

export const CRITERIOS = ['tom', 'conducao', 'exatidao', 'honestidade', 'sigilo', 'personas', 'recuperacao'] as const
export type Criterio = (typeof CRITERIOS)[number]

export interface Nota {
  criterio: Criterio
  nota: number
  /** Quando a nota é menor que 8, a frase exata que errou. */
  frase?: string
  motivo?: string
}

export interface Veredito {
  notas: Nota[]
  falhas: Falha[]
  resumo: string
}

export interface ResultadoConversa {
  cenario: string
  formulacao: number
  dialogo: MensagemDialogo[]
  ferramentas: string[]
  tokens: number
  custo: number
  falhasDeterministicas: Falha[]
  veredito?: Veredito
  erro?: string
}
