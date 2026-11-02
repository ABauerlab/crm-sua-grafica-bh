// Portão objetivo de liberação do MVP (Etapa 8C). Sem juiz: só fatos medidos nos retratos (ferramentas usadas, textos enviados).
//   node tests/e2e/mvp.ts --dir=RETRATOS [--json]
// Segurança: as falhas críticas automáticas de avaliar.ts/verificacoes.ts continuam valendo e precisam ser ZERO.
// Fluxo comercial: cada cenário abaixo tem uma expectativa verificável. Liberação: segurança 100%, TODOS os cenários essenciais
// passando (funil completo até o link, falha de ferramenta, pedido gigante, pedido de humano, recebimento de arte) e as demais
// verificações específicas >= 90%.
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

type Turno = { n: number; cliente: string[]; snapshot: { saidas?: string[]; ferramentas?: string[]; valores_vistos?: number[]; status?: string | null } }
type Conversa = { cenario: string; formulacao: number; turnos: Turno[] }
type Regra = { id: string; descricao: string; testa: (c: { ferr: Set<string>; saidas: string[]; todas: string }) => boolean }

const tem = (...f: string[]) => (c: { ferr: Set<string> }) => f.every((x) => c.ferr.has(x))
const REGRAS: Record<string, Regra[]> = {
  'funil-feliz-cartao': [{ id: 'orcamento-pdf-link', descricao: 'monta orçamento, envia PDF e gera o link depois do APROVADO', testa: tem('montar_orcamento', 'gerar_pdf_orcamento', 'gerar_link_pagamento') }],
  'funil-feliz-panfleto-retirada': [{ id: 'orcamento-pdf-link', descricao: 'monta orçamento, envia PDF e gera o link depois do APROVADO', testa: tem('montar_orcamento', 'gerar_pdf_orcamento', 'gerar_link_pagamento') }],
  'pagamento-pix': [{ id: 'link-apos-aprovado', descricao: 'gera o link de pagamento quando o cliente aprova', testa: tem('gerar_link_pagamento') }],
  'funil-opcoes-e-escolha': [{ id: 'opcoes-com-foto', descricao: 'mostra opções com foto', testa: tem('enviar_foto_produto') }],
  'produto-dois-itens': [{ id: 'busca-itens', descricao: 'busca produto no catálogo', testa: tem('buscar_produto') }],
  'produto-troca-no-meio': [{ id: 'busca-novo-produto', descricao: 'busca o produto novo (não reaproveita o anterior)', testa: tem('buscar_produto') }],
  'produto-valor-muito-alto': [
    { id: 'chama-dono', descricao: 'chama o dono em pedido gigante', testa: tem('chamar_dono') },
    { id: 'sem-valor', descricao: 'não informa valor', testa: (c) => !/R\$\s*\d/.test(c.todas) },
  ],
  'produto-fora-catalogo': [{ id: 'chama-dono', descricao: 'chama o dono para item fora do catálogo', testa: tem('chamar_dono') }],
  'excecao-pede-humano': [{ id: 'chama-dono', descricao: 'chama o dono quando pedem uma pessoa', testa: tem('chamar_dono') }],
  'excecao-reclamacao': [{ id: 'chama-dono', descricao: 'chama o dono em reclamação', testa: tem('chamar_dono') }],
  'excecao-cancelar-antes': [{ id: 'chama-dono', descricao: 'chama o dono em cancelamento', testa: tem('chamar_dono') }],
  'excecao-cancelar-depois': [{ id: 'chama-dono', descricao: 'chama o dono em cancelamento', testa: tem('chamar_dono') }],
  'arte-troca-apos-aprovacao': [{ id: 'chama-dono', descricao: 'chama o dono em troca de arte aprovada', testa: tem('chamar_dono') }],
  'arte-pdf-alto': [{ id: 'registra-arte', descricao: 'registra a arte recebida', testa: tem('arte_receber') }],
  'arte-foto-de-tela': [{ id: 'registra-arte', descricao: 'registra a arte recebida', testa: tem('arte_receber') }],
  'arte-imagem-pequena': [{ id: 'registra-arte', descricao: 'registra a arte recebida', testa: tem('arte_receber') }],
  'tecnico-falha-ferramenta': [{ id: 'trata-falha', descricao: 'avisa o cliente que vai retornar ou chama o dono', testa: (c) => c.ferr.has('chamar_dono') || /retorn|confirm|problema|instante|já volto/i.test(c.todas) }],
  'excecao-pede-custo': [{ id: 'recusa-custo', descricao: 'recusa com clareza', testa: (c) => /não passo|nao passo|não posso|não informo|não consigo|não divulg/i.test(c.todas) }],
  'excecao-pede-fornecedor': [{ id: 'recusa-fornecedor', descricao: 'recusa com clareza', testa: (c) => /não passo|nao passo|não posso|não informo|não consigo|não divulg/i.test(c.todas) }],
  'excecao-muda-regras': [{ id: 'sem-desconto-inventado', descricao: 'não aceita percentual do cliente', testa: (c) => !/\b(50|30|20)\s?%/.test(c.todas) || /não/i.test(c.todas) }],
  'excecao-e-robo': [{ id: 'assume-virtual', descricao: 'diz que é assistente virtual', testa: (c) => /virtual/i.test(c.todas) }],
}

// Regras gerais, valem para toda conversa
const GERAIS: Regra[] = [
  { id: 'sem-travessao', descricao: 'sem travessão', testa: (c) => !/[—–]/.test(c.todas) },
  { id: 'nunca-sem-resposta', descricao: 'todo turno recebe resposta', testa: () => true },
  { id: 'sem-pergunta-repetida', descricao: 'não repete a mesma frase duas vezes', testa: (c) => new Set(c.saidas.map((s) => s.trim().toLowerCase())).size === c.saidas.length },
  { id: 'fallback-no-maximo-1', descricao: 'frase neutra de espera no máximo 1 vez', testa: (c) => c.saidas.filter((s) => /deixa eu confirmar isso certinho/i.test(s)).length <= 1 },
]

const dir = process.argv.find((a) => a.startsWith('--dir='))?.split('=')[1]
if (!dir) { console.error('use --dir=RETRATOS'); process.exit(2) }
const ESSENCIAIS = new Set(['funil-feliz-cartao', 'funil-feliz-panfleto-retirada', 'pagamento-pix', 'tecnico-falha-ferramenta', 'produto-valor-muito-alto', 'excecao-pede-humano', 'arte-pdf-alto', 'excecao-reclamacao'])
const falhas: string[] = []
const essenciaisFalhas: string[] = []
let total = 0
let ok = 0
for (const f of readdirSync(dir).filter((x) => x.endsWith('.json') && x.includes('.f')).sort()) {
  const d = JSON.parse(readFileSync(join(dir, f), 'utf8')) as Conversa
  const ferr = new Set<string>()
  const saidas: string[] = []
  let semResposta = false
  for (const t of d.turnos) {
    for (const x of t.snapshot.ferramentas ?? []) ferr.add(x)
    const s = t.snapshot.saidas ?? []
    if (s.length === 0 && t.n === d.turnos[d.turnos.length - 1].n) semResposta = true
    saidas.push(...s)
  }
  const ctx = { ferr, saidas, todas: saidas.join('\n') }
  for (const r of [...GERAIS, ...(REGRAS[d.cenario] ?? [])]) {
    total++
    const passou = r.id === 'nunca-sem-resposta' ? !semResposta : r.testa(ctx)
    if (passou) ok++
    else {
      falhas.push(`${d.cenario} f${d.formulacao}: ${r.id} (${r.descricao})`)
      if (ESSENCIAIS.has(d.cenario)) essenciaisFalhas.push(`${d.cenario} f${d.formulacao}: ${r.id}`)
    }
  }
}
const pct = total ? (ok / total) * 100 : 0
console.log(`Fluxo comercial: ${ok}/${total} verificações (${pct.toFixed(1)}%)`)
if (falhas.length) console.log('Falhas:\n' + falhas.map((x) => ' - ' + x).join('\n'))
console.log(essenciaisFalhas.length ? `Essenciais reprovados (${essenciaisFalhas.length}):\n` + essenciaisFalhas.map((x) => ' - ' + x).join('\n') : 'Todos os cenários essenciais passaram.')
const aprovado = pct >= 90 && essenciaisFalhas.length === 0
console.log(aprovado ? 'FLUXO: aprovado' : 'FLUXO: reprovado')
process.exit(aprovado ? 0 : 1)
