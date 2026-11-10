import Link from 'next/link'
import { ArrowRight, BadgePercent, Clock, CreditCard, MapPin, Truck } from 'lucide-react'
import { HeroSlider, type Slide } from '@/components/HeroSlider'
import { ModeloCard } from '@/components/ModeloCard'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { ProdutoCard } from '@/components/ProdutoCard'
import { SITE, linkWhatsApp } from '@/lib/site'
import { buscar, fotoUrl, modelos, type ProdutoResumo } from '@/lib/vitrine'

export const revalidate = 3600

const VANTAGENS = [
  { icone: Clock, titulo: 'Produção rápida', texto: 'Pedido pago e arte liberada até 10h30 entra na produção no mesmo dia útil.' },
  { icone: CreditCard, titulo: 'Pix ou 2x sem juros', texto: 'Pix com liberação imediata ou cartão em até 2x sem juros pelo Mercado Pago.' },
  { icone: Truck, titulo: 'Entrega em BH e no Brasil', texto: 'Frete grátis na região central de BH e envio para todo o país.' },
  { icone: BadgePercent, titulo: 'Cobrimos orçamento', texto: 'Tem proposta menor de outra gráfica para o mesmo produto? Mande que a gente avalia.' },
]

// Mais vendidos: um produto por termo (prioriza quem já tem foto)
const MAIS_VENDIDOS = ['cartao de visita', 'panfleto', 'adesivo', 'banner', 'sacola', 'caneca', 'etiqueta', 'cardapio']

async function maisVendidos(): Promise<ProdutoResumo[]> {
  const r = await Promise.all(MAIS_VENDIDOS.map((t) => buscar(t, null, 8)))
  return r.map((x) => x.produtos.find((p) => p.foto) ?? x.produtos[0]).filter((p): p is ProdutoResumo => !!p)
}

// Vitrine da home: cada departamento mostra MODELOS reais (foto, SKU e preço), nunca contagem de produtos
const DEPARTAMENTOS = [
  { titulo: 'Cartões de visita', slug: 'cartoes-de-visita' },
  { titulo: 'Panfletos, flyers e folhetos', slug: 'panfletos-flyers-e-folhetos' },
  { titulo: 'Adesivos', slug: 'adesivos' },
  { titulo: 'Banners, lonas e faixas', slug: 'banners-faixas-lonas-e-tecidos' },
  { titulo: 'Sacolas e embalagens', slug: 'sacolas-e-sacos' },
  { titulo: 'Canecas e brindes', slug: 'caneca-copos-e-tacas' },
]

export default async function Home() {
  const [vendidos, ...vitrines] = await Promise.all([maisVendidos(), ...DEPARTAMENTOS.map((d) => modelos([d.slug], { limite: 4 }))])
  const foto = (i: number) => fotoUrl(vitrines[i]?.modelos.find((m) => m.foto)?.foto)
  const slides: Slide[] = [
    { titulo: 'Impressos rápidos com corte às 10h30 e frete grátis na região central de BH', texto: 'Pagou e liberou a arte até 10h30 em dia útil? A produção começa no mesmo dia.', href: '/categoria/cartoes-de-visita', botao: 'Ver cartões de visita', foto: foto(0), fundo: 'bg-tinta', destaque: 'bg-amarelo text-tinta hover:bg-amarelo-escuro' },
    { titulo: 'Kits comerciais para lojas com parcelamento em até 2x sem juros', texto: 'Cartões, sacolas, etiquetas e adesivos para a sua loja. Pix na hora ou 2x sem juros no cartão.', href: '/categoria/sacolas-e-sacos', botao: 'Montar o kit da minha loja', foto: foto(4), fundo: 'bg-magenta', destaque: 'bg-white text-tinta hover:bg-papel' },
    { titulo: 'Cobrimos qualquer orçamento comprovado da concorrência', texto: 'Achou mais barato em outra gráfica para o mesmo produto? Mande o orçamento e a gente avalia.', href: '/ajuda#orcamento', botao: 'Enviar orçamento para cobrir', foto: foto(2), fundo: 'bg-ciano', destaque: 'bg-tinta text-white hover:bg-black' },
    { titulo: 'Retirada física agendada no Edifício Helena Passig, na Praça Sete', texto: 'Retire seus materiais prontos no centro de BH, com hora marcada. Sem pagar frete.', href: '/categorias', botao: 'Escolher meus produtos', foto: foto(1), fundo: 'bg-tinta', destaque: 'bg-amarelo text-tinta hover:bg-amarelo-escuro' },
  ]
  return (
    <>
      <HeroSlider slides={slides} />

      <section aria-label="Vantagens" className="relative z-10 mx-auto -mt-8 max-w-7xl px-4">
        <ul className="grid gap-3 rounded-xl2 bg-white p-4 shadow-lg sm:grid-cols-2 lg:grid-cols-4">
          {VANTAGENS.map(({ icone: I, titulo, texto }) => (
            <li key={titulo} className="flex gap-3 p-2"><I className="mt-0.5 h-6 w-6 shrink-0 text-magenta" aria-hidden /><span><b className="block text-sm">{titulo}</b><span className="text-xs text-black/60">{texto}</span></span></li>
          ))}
        </ul>
      </section>

      {DEPARTAMENTOS.map((d, i) => vitrines[i].modelos.length > 0 && (
        <section key={d.slug} className="mx-auto max-w-7xl px-4 pt-12">
          <div className="mb-4 flex items-end justify-between gap-4">
            <h2 className="text-2xl font-black md:text-3xl">{d.titulo}</h2>
            <Link href={`/categoria/${d.slug}`} className="text-sm font-semibold text-magenta hover:underline">Ver todos os modelos</Link>
          </div>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">{vitrines[i].modelos.map((m) => <ModeloCard key={m.produto_slug} m={m} />)}</div>
        </section>
      ))}

      {vendidos.length > 0 && (
        <section className="mx-auto max-w-7xl px-4 pt-14">
          <div className="mb-5 flex items-end justify-between gap-4">
            <div><h2 className="text-2xl font-black md:text-3xl">Mais vendidos</h2><p className="text-sm text-black/60">Os produtos mais pedidos pelos nossos clientes.</p></div>
            <Link href="/categorias" className="text-sm font-semibold text-magenta hover:underline">Ver todos</Link>
          </div>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">{vendidos.map((p) => <ProdutoCard key={p.produto_slug} p={p} />)}</div>
        </section>
      )}

      <section className="mx-auto max-w-7xl px-4 pt-10"><CobrimosBanner /></section>

      <section className="mx-auto max-w-7xl px-4 pt-14">
        <div className="grid overflow-hidden rounded-xl2 bg-white shadow-sm md:grid-cols-2">
          <div className="p-6 md:p-10">
            <h2 className="flex items-center gap-2 text-2xl font-black"><MapPin className="h-6 w-6 text-magenta" aria-hidden />Retirada grátis na Praça Sete</h2>
            <p className="mt-3 text-sm text-black/70">{SITE.endereco.aviso}</p>
            <address className="mt-4 text-sm not-italic">{SITE.endereco.rua}, {SITE.endereco.predio}<br />{SITE.endereco.bairro}, {SITE.endereco.cidade} - {SITE.endereco.uf}</address>
            <ul className="mt-4 space-y-1 text-sm">{SITE.horarios.map((h) => <li key={h.dias}><b>{h.dias}:</b> {h.horas}</li>)}</ul>
          </div>
          <iframe title="Mapa da Sua Gráfica BH" src={SITE.mapaEmbed} className="h-72 w-full border-0 md:h-full" loading="lazy" referrerPolicy="strict-origin-when-cross-origin" />
        </div>
      </section>
    </>
  )
}
