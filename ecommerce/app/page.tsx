import Link from 'next/link'
import { ArrowRight, BadgePercent, Clock, CreditCard, MapPin, Truck } from 'lucide-react'
import { CategoriaCard } from '@/components/CategoriaCard'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { ProdutoCard } from '@/components/ProdutoCard'
import { SITE, linkWhatsApp } from '@/lib/site'
import { buscar, categorias, fotoUrl, type CategoriaResumo, type ProdutoResumo } from '@/lib/vitrine'

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

const BANNERS = [
  { slug: 'cartoes-de-visita', titulo: 'Papelaria corporativa', texto: 'Cartões, timbrados e envelopes com acabamento de alto padrão.', cor: 'bg-tinta text-white', botao: 'bg-amarelo text-tinta' },
  { slug: 'caneca-copos-e-tacas', titulo: 'Personalize do seu jeito', texto: 'Canecas, copos, garrafas e brindes com a sua marca.', cor: 'bg-amarelo text-tinta', botao: 'bg-tinta text-white' },
  { slug: 'banners-faixas-lonas-e-tecidos', titulo: 'Grandes formatos', texto: 'Banners, lonas, faixas e placas com visibilidade de verdade.', cor: 'bg-magenta text-white', botao: 'bg-white text-tinta' },
]

export default async function Home() {
  const [cats, vendidos] = await Promise.all([categorias(), maisVendidos()])
  const destaque = cats.filter((c) => c.foto).slice(0, 12)
  const fotoDe = (slug: string) => fotoUrl(cats.find((c: CategoriaResumo) => c.slug === slug)?.foto)
  return (
    <>
      <section className="relative overflow-hidden bg-tinta text-white">
        <div aria-hidden className="pointer-events-none absolute -right-40 -top-40 h-72 w-72 rounded-full bg-ciano/40 mix-blend-screen md:-right-24 md:-top-24 md:h-[28rem] md:w-[28rem] md:bg-ciano/70" />
        <div aria-hidden className="pointer-events-none absolute -right-24 top-6 h-56 w-56 rounded-full bg-magenta/40 mix-blend-screen md:-right-2 md:top-24 md:h-[24rem] md:w-[24rem] md:bg-magenta/70" />
        <div aria-hidden className="pointer-events-none absolute right-40 top-56 hidden h-[20rem] w-[20rem] rounded-full bg-amarelo/80 mix-blend-screen md:block" />
        <div className="relative mx-auto max-w-7xl px-4 py-16 md:py-24">
          <p className="mb-4 text-xs font-semibold uppercase tracking-[0.25em] text-white/70">Ideias impressas em todo lugar</p>
          <h1 className="max-w-2xl text-4xl font-black leading-[1.02] md:text-6xl">
            Impressão de qualidade para o <span className="text-magenta">seu negócio</span><span className="text-amarelo">.</span>
          </h1>
          <p className="mt-5 max-w-xl text-base text-white/85 md:text-lg">Cartões, panfletos, adesivos, banners, embalagens e brindes. Preço fechado no site, Pix na hora e retirada no centro de BH.</p>
          <div className="mt-8 flex flex-wrap gap-3">
            <Link href="/categorias" className="inline-flex items-center gap-2 rounded-lg bg-amarelo px-5 py-3 font-bold text-tinta hover:bg-amarelo-escuro">Ver todos os produtos <ArrowRight className="h-4 w-4" aria-hidden /></Link>
            <a href={linkWhatsApp('Olá! Estive no site da Sua Gráfica BH e gostaria de um orçamento.')} target="_blank" rel="noopener" className="inline-flex items-center gap-2 rounded-lg border border-white/30 px-5 py-3 font-semibold hover:border-white">Falar no WhatsApp</a>
          </div>
        </div>
      </section>

      <section aria-label="Vantagens" className="relative z-10 mx-auto -mt-8 max-w-7xl px-4">
        <ul className="grid gap-3 rounded-xl2 bg-white p-4 shadow-lg sm:grid-cols-2 lg:grid-cols-4">
          {VANTAGENS.map(({ icone: I, titulo, texto }) => (
            <li key={titulo} className="flex gap-3 p-2"><I className="mt-0.5 h-6 w-6 shrink-0 text-magenta" aria-hidden /><span><b className="block text-sm">{titulo}</b><span className="text-xs text-black/60">{texto}</span></span></li>
          ))}
        </ul>
      </section>

      <section className="mx-auto max-w-7xl px-4 pt-14">
        <div className="mb-5 flex items-end justify-between gap-4">
          <h2 className="text-2xl font-black md:text-3xl">Categorias em destaque</h2>
          <Link href="/categorias" className="text-sm font-semibold text-magenta hover:underline">Ver todas</Link>
        </div>
        {destaque.length ? (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">{destaque.map((c, i) => <CategoriaCard key={c.slug} c={c} i={i} />)}</div>
        ) : (
          <p className="rounded-xl2 bg-white p-6 text-sm text-black/60">Catálogo em atualização. Fale com a gente pelo WhatsApp {SITE.telefone}.</p>
        )}
      </section>

      {vendidos.length > 0 && (
        <section className="mx-auto max-w-7xl px-4 pt-14">
          <div className="mb-5 flex items-end justify-between gap-4">
            <div><h2 className="text-2xl font-black md:text-3xl">Mais vendidos</h2><p className="text-sm text-black/60">Os produtos mais pedidos pelos nossos clientes.</p></div>
            <Link href="/categorias" className="text-sm font-semibold text-magenta hover:underline">Ver todos</Link>
          </div>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">{vendidos.map((p) => <ProdutoCard key={p.produto_slug} p={p} />)}</div>
        </section>
      )}

      <section className="mx-auto grid max-w-7xl gap-3 px-4 pt-14 md:grid-cols-3">
        {BANNERS.map((b) => {
          const f = fotoDe(b.slug)
          return (
            <Link key={b.slug} href={`/categoria/${b.slug}`} className={`group relative flex min-h-56 flex-col justify-end overflow-hidden rounded-xl2 p-6 ${b.cor}`}>
              {f && (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={f} alt="" loading="lazy" className="absolute -right-8 -top-6 h-48 w-48 rotate-6 rounded-2xl object-cover opacity-90 shadow-xl transition group-hover:rotate-3" />
              )}
              <h3 className="relative max-w-[60%] text-2xl font-black leading-tight">{b.titulo}</h3>
              <p className="relative mt-1 max-w-[70%] text-sm opacity-85">{b.texto}</p>
              <span className={`relative mt-4 inline-flex w-fit items-center gap-1 rounded-lg px-3 py-2 text-sm font-bold ${b.botao}`}>Ver produtos <ArrowRight className="h-4 w-4" aria-hidden /></span>
            </Link>)
        })}
      </section>

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
