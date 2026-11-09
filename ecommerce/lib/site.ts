// Dados institucionais públicos da Sua Gráfica BH (decisão do dono, 09/11/2026: endereço do balcão é público).
export const SITE = {
  nome: 'Sua Gráfica BH',
  url: process.env.NEXT_PUBLIC_SITE_URL ?? 'https://suagraficabh.com.br',
  descricao: 'Gráfica digital online em Belo Horizonte: cartões de visita, panfletos, adesivos, banners, embalagens e brindes com produção rápida, Pix e entrega em BH e todo o Brasil.',
  whatsapp: '5531975618243',
  telefone: '(31) 97561-8243',
  email: 'contato@suagraficabh.com.br',
  cnpj: '58.481.181/0001-03',
  endereco: {
    rua: 'Rua Rio de Janeiro, 462, 22º andar, Sala 2217',
    predio: 'Edifício Helena Passig',
    bairro: 'Centro (Praça Sete)',
    cidade: 'Belo Horizonte',
    uf: 'MG',
    cep: '30160-040',
    aviso: 'Somos uma gráfica digital online. Este ponto é exclusivo para retirada agendada de materiais prontos.',
  },
  horarios: [
    { dias: 'Segunda a quinta', horas: '08:00 às 17:00' },
    { dias: 'Sexta', horas: '08:00 às 18:30' },
    { dias: 'Sábado e domingo', horas: 'Fechado' },
  ],
  redes: {
    instagram: 'https://instagram.com/suagraficabh',
    facebook: 'https://www.facebook.com/profile.php?id=61596014576832',
    threads: 'https://www.threads.net/@suagraficabh',
  },
  avaliacaoGoogle: 'https://g.page/r/CZ6eNNGjdgO4EBM/review',
  mapaEmbed: 'https://www.google.com/maps/embed?pb=!1m18!1m12!1m3!1d3751.1431918599087!2d-43.941116823616646!3d-19.918369837948703!2m3!1f0!2f0!3f0!3m2!1i1024!2i768!4f13.1!3m3!1m2!1s0xa699e8cef5ecc7%3A0xb80376a3d1349e9e!2sSua%20Gr%C3%A1fica%20BH!5e0!3m2!1spt-BR!2sbr!4v1793487917041!5m2!1spt-BR!2sbr',
  credito: { nome: 'Bauerlab', url: 'https://bauerlab.com.br/' },
} as const

/** Link do WhatsApp com a mensagem do contexto da página. */
export function linkWhatsApp(mensagem: string) {
  return `https://wa.me/${SITE.whatsapp}?text=${encodeURIComponent(mensagem)}`
}

export const MENSAGENS_WHATSAPP = {
  home: 'Olá! Estive no site da Sua Gráfica BH e gostaria de tirar uma dúvida sobre impressão.',
  produto: (nome: string) => `Olá! Estou vendo o produto ${nome} no site e gostaria de ajuda com o meu pedido.`,
  checkout: 'Olá! Estou no checkout do pedido e preciso de auxílio para finalizar.',
} as const

export const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
