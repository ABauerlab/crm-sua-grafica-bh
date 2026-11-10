// Central de Ajuda (Fase 8): perguntas e respostas públicas. Valores e regras iguais aos do banco e do atendimento.
import { SITE } from './site'

export interface Pergunta { p: string; r: string }
export interface CategoriaAjuda { id: string; titulo: string; resumo: string; perguntas: Pergunta[] }

const e = SITE.endereco

export const AJUDA: CategoriaAjuda[] = [
  {
    id: 'arquivos', titulo: 'Envio e preparação de arquivos', resumo: 'Formatos, gabaritos, conferência e criação de arte.',
    perguntas: [
      { p: 'Quais formatos de arquivo vocês aceitam?', r: 'Aceitamos somente PDF em alta qualidade (PDF/X-1a, se o seu programa tiver essa opção): 300 dpi, no tamanho final da peça, com sangria de 3 mm, textos em curva e cores em CMYK. Você anexa o PDF no checkout, antes do pagamento.' },
      { p: 'Como preparar a arte para impressão?', r: 'Use cores em CMYK, resolução de 300 dpi, sangria de 3 mm em cada lado, margem de segurança de 3 a 5 mm para textos e logos e fontes convertidas em curvas. Assim nada fica cortado e as cores saem como o esperado.' },
      { p: 'Vocês têm gabarito dos produtos?', r: 'Sim. Peça o gabarito do produto e da medida escolhida pelo WhatsApp que a gente envia na hora, com as áreas de sangria, corte e segurança marcadas.' },
      { p: 'O que é a conferência e ajuste técnico de R$ 14,90?', r: 'Nossa equipe confere sangria, margem de segurança, cores para impressão, resolução e fontes, faz os ajustes técnicos necessários e te manda para aprovar antes de imprimir. Não muda o seu design.' },
      { p: 'Não tenho arte. Vocês criam?', r: 'Criamos. A criação completa custa R$ 39,90: você manda as informações, o logo e as referências, a gente desenvolve a arte e envia para aprovação. A criação acrescenta 1 dia útil ao prazo.' },
      { p: 'Posso mandar a arte pronta sem pagar nada a mais?', r: 'Pode. Arte pronta não tem custo. Nesse caso a responsabilidade pela arte é sua, então vale conferir sangria, margem e erros de digitação antes de enviar.' },
    ],
  },
  {
    id: 'prazos', titulo: 'Prazos de produção', resumo: 'Pago até 10h30 produz no mesmo dia, contagem em dias úteis e criação de arte.',
    perguntas: [
      { p: 'Quando o prazo começa a contar?', r: 'O prazo de produção começa quando o pagamento está confirmado. Pedidos pagos até 10h30 de um dia útil começam a ser produzidos no mesmo dia; depois disso, entram no próximo dia útil.' },
      { p: 'O prazo conta sábado, domingo e feriado?', r: 'Não. Todos os prazos são em dias úteis (segunda a sexta, fora feriados).' },
      { p: 'O prazo inclui a entrega?', r: 'O prazo mostrado no produto é de produção. Para entrega em BH, considere mais 1 dia útil de logística. Para outras cidades, o prazo da transportadora aparece no pedido.' },
      { p: 'Preciso com urgência. Dá para adiantar?', r: 'Chama a gente no WhatsApp antes de fechar o pedido. Vemos a fila de produção e te falamos com sinceridade o que dá para fazer.' },
    ],
  },
  {
    id: 'entrega', titulo: 'Entrega e retirada', resumo: 'Retirada grátis na Praça Sete, entrega em BH e envio para o Brasil.',
    perguntas: [
      { p: 'Posso retirar o pedido pessoalmente?', r: `Pode, e é grátis. A retirada é agendada no nosso balcão: ${e.rua}, ${e.predio}, ${e.bairro}, ${e.cidade}. ${e.aviso} Avise pelo WhatsApp quando quiser buscar.` },
      { p: 'Qual o horário de retirada?', r: SITE.horarios.map((h) => `${h.dias}: ${h.horas}`).join('; ') + '.' },
      { p: 'Vocês entregam em BH?', r: 'Entregamos. Na região central de Belo Horizonte a entrega é grátis a partir do valor mínimo informado no carrinho; nos outros bairros o valor aparece no pedido, antes de pagar.' },
      { p: 'Enviam para outras cidades?', r: 'Sim, enviamos para todo o Brasil. O frete e o prazo de entrega são calculados pelo CEP no pedido.' },
    ],
  },
  {
    id: 'pagamento', titulo: 'Pagamentos', resumo: 'Pix na hora, cartão em 2x sem juros e parcelado no Mercado Pago.',
    perguntas: [
      { p: 'Quais as formas de pagamento?', r: 'Pix (de qualquer banco, com confirmação na hora) e cartão de crédito em até 2x sem juros. Se preferir parcelar mais, o Mercado Pago oferece até 12x com juros da própria operadora, mostrados antes de você confirmar.' },
      { p: 'O pagamento é seguro?', r: 'Sim. Todo pagamento é feito pelo Mercado Pago, em ambiente protegido. A gente não vê nem guarda os dados do seu cartão.' },
      { p: 'Quando meu pedido é confirmado?', r: 'Assim que o Mercado Pago aprova o pagamento. No Pix isso costuma levar poucos segundos; você recebe a confirmação no WhatsApp.' },
      { p: 'Vocês emitem nota fiscal?', r: 'Emitimos. Informe no pedido ou no WhatsApp o CPF ou CNPJ, nome ou razão social, endereço com CEP e e-mail.' },
    ],
  },
  {
    id: 'cobrimos', titulo: 'Cobrimos qualquer orçamento', resumo: 'Achou mais barato? Manda pra gente.',
    perguntas: [
      { p: 'Como funciona o "cobrimos qualquer orçamento"?', r: 'Recebeu um orçamento menor de outra gráfica para o mesmo produto (mesmo material, tamanho, quantidade e acabamento)? Envie o orçamento pelo WhatsApp. Analisamos e, sempre que possível, cobrimos o valor ou oferecemos uma condição especial.' },
      { p: 'Precisa ser um orçamento formal?', r: 'Precisa mostrar o produto, as especificações, o valor e a empresa que fez o orçamento (pode ser print ou PDF). Orçamentos com especificação diferente são comparados com o produto equivalente.' },
      { p: 'Fazem orçamento de produto que não está no site?', r: 'Fazemos. Conte o que você precisa pelo WhatsApp que montamos um orçamento personalizado.' },
    ],
  },
  {
    id: 'garantia', titulo: 'Garantia e pós-venda', resumo: 'Reimpressão em caso de defeito e acompanhamento pelo WhatsApp.',
    perguntas: [
      { p: 'E se o material chegar com defeito ou avariado?', r: 'Se houver defeito de produção ou avaria no transporte, reimprimimos sem custo. Mande fotos pelo WhatsApp assim que receber; pelo Código de Defesa do Consumidor, defeitos aparentes podem ser reclamados em até 30 dias.' },
      { p: 'E se o erro estiver na arte que eu aprovei?', r: 'Erros na arte enviada ou aprovada pelo cliente (texto, telefone, cores escolhidas) não entram na garantia. Por isso sempre enviamos a arte para você conferir antes de imprimir.' },
      { p: 'Como acompanho meu pedido?', r: 'Pelo WhatsApp. Nossa equipe avisa quando o pagamento é confirmado, quando o pedido entra em produção e quando está pronto para retirada ou saiu para entrega.' },
      { p: 'Como falo com uma pessoa?', r: `É só chamar no WhatsApp ${SITE.telefone} e pedir para falar com o atendimento. Também respondemos pelo e-mail ${SITE.email}.` },
    ],
  },
]

/** minúsculas e sem acento, para a busca da central */
export function semAcento(s: string) {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}
