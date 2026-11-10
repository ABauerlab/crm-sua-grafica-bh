import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight, ImageOff, ShieldCheck, Truck, Clock, Palette } from 'lucide-react'
import { Abas } from '@/components/Abas'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { Configurador } from '@/components/Configurador'
import { SelosSeguranca } from '@/components/SelosSeguranca'
import { ViewContent } from '@/components/ViewContent'
import { SITE, brl } from '@/lib/site'
import { CompreJunto } from '@/components/CompreJunto'
import { fotoUrl, modelos, produto } from '@/lib/vitrine'

// Combinações de venda cruzada por categoria (primeira que casar). Padrão: cartões de visita.
const PARES: [RegExp, string][] = [
  [/cartoes|cartao/, 'pastas'], [/panfleto|filipeta|folhas/, 'banners-faixas-lonas-e-tecidos'], [/adesivo|rotulo/, 'sacolas-e-sacos'],
  [/banner|lona|faixa|wind/, 'cartoes-de-visita'], [/pasta/, 'cartoes-de-visita'], [/sacola|caixa|embalagem/, 'adesivos'],
]

export const revalidate = 900

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params
  const p = await produto(slug)
  if (!p) return { title: 'Produto não encontrado' }
  const desc = `${p.titulo} (${p.categoria}). ${p.impressao ?? ''} ${p.formato ?? ''}. A partir de ${brl(Number(p.a_partir_de))} no Pix ou 2x sem juros. Produção rápida em Belo Horizonte e envio para todo o Brasil.`
  const foto = fotoUrl(p.fotos[0])
  return { title: p.titulo, description: desc.replace(/\s+/g, ' ').trim(), alternates: { canonical: `/produto/${slug}` },
    openGraph: { title: p.titulo, description: desc, images: foto ? [foto] : [] } }
}

export default async function PaginaProduto({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params
  const p = await produto(slug)
  if (!p) notFound()
  const foto = fotoUrl(p.fotos[0])
  const par = PARES.find(([re]) => re.test(p.categoria_slug))?.[1] ?? 'cartoes-de-visita'
  const sugestoes = (await modelos([par], { limite: 2 })).modelos.filter((m) => m.ref && m.produto_slug !== p.produto_slug)
  const f = p.ficha ?? {}
  const linhasFicha: [string, string | null | undefined][] = [
    ['Material', f.material], ['Espessura', f.espessura], ['Impressão', f.impressao ?? p.impressao], ['Tamanho final', f.tamanho_final ?? p.formato],
    ['Arte com sangria (3 mm)', f.arte_com_sangria], ['Acabamento', f.acabamento ?? p.acabamentos?.[0]], ['Prazo de produção', p.prazo_dias_uteis ? `${p.prazo_dias_uteis} dias úteis após pagamento e arte liberada` : null],
  ]
  const jsonLd = {
    '@context': 'https://schema.org', '@type': 'Product', name: p.titulo, sku: p.sku ?? undefined, category: p.categoria, image: foto ? [foto] : undefined,
    description: p.especificacao ?? undefined, brand: { '@type': 'Brand', name: SITE.nome },
    offers: { '@type': 'AggregateOffer', priceCurrency: 'BRL', lowPrice: Number(p.a_partir_de), highPrice: Number(p.ate), offerCount: p.opcoes.length,
      availability: 'https://schema.org/InStock', seller: { '@type': 'Organization', name: SITE.nome } },
  }
  return (
    <div className="mx-auto max-w-7xl px-4 py-6">
      <nav aria-label="Caminho" className="mb-4 flex flex-wrap items-center gap-1 text-xs text-black/55">
        <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
        <Link href={`/categoria/${p.categoria_slug}`} className="hover:text-magenta">{p.categoria}</Link><ChevronRight className="h-3 w-3" aria-hidden />
        <span className="text-tinta">{p.titulo}</span>
      </nav>
      <div className="grid gap-8 lg:grid-cols-[1.1fr_1fr]">
        <div className="space-y-4">
          <div className="overflow-hidden rounded-xl2 bg-white shadow-sm">
            {foto
              // eslint-disable-next-line @next/next/no-img-element
              ? <img src={foto} alt={p.titulo} className="aspect-square w-full object-cover" />
              : <div className="flex aspect-square items-center justify-center text-black/25"><ImageOff className="h-16 w-16" aria-hidden /></div>}
          </div>
          <ul className="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
            {[[Clock, 'Pago até 10h30, produz no mesmo dia'], [Truck, 'Entrega em BH e no Brasil'], [Palette, 'Arte pronta, conferida ou criada'], [ShieldCheck, 'Pagamento pelo Mercado Pago']].map(([I, t]) => {
              const Icone = I as typeof Clock
              return <li key={t as string} className="flex items-center gap-2 rounded-lg bg-white p-3 shadow-sm"><Icone className="h-5 w-5 shrink-0 text-magenta" aria-hidden />{t as string}</li>
            })}
          </ul>
        </div>
        <div className="space-y-5">
          <div>
            <span className="text-xs font-semibold uppercase tracking-wide text-magenta">{p.categoria}</span>
            <h1 className="mt-1 text-2xl font-black leading-tight md:text-3xl">{p.titulo}</h1>
            <p className="mt-2 text-sm text-black/65">{[p.impressao, p.formato].filter(Boolean).join(' · ')}</p>
            {p.sku && <p className="mt-1 text-sm font-semibold">Ref. / SKU: <span className="rounded bg-amarelo/60 px-1.5 py-0.5 font-mono">{p.sku}</span></p>}
          </div>
          <Configurador slug={p.produto_slug} titulo={p.titulo} foto={p.fotos[0] ?? null} opcoes={p.opcoes} irmaos={p.irmaos} formato={p.formato} />
          <CobrimosBanner produto={p.titulo} />
          <SelosSeguranca escuro={false} />
        </div>
      </div>

      <div className="mt-10 rounded-xl2 bg-white px-5 shadow-sm">
        <Abas abas={[
          { id: 'descricao', titulo: 'Descrição', conteudo: (
            <div className="space-y-2">
              <p>{p.especificacao ? `${p.titulo}: ${p.especificacao}.` : p.titulo}</p>
              {(f.observacoes ?? []).map((o) => <p key={o}>{o}</p>)}
            </div>) },
          { id: 'ficha', titulo: 'Ficha técnica', conteudo: (
            <dl className="grid gap-x-6 gap-y-2 sm:grid-cols-[200px_1fr]">
              {linhasFicha.filter(([, v]) => v).map(([k, v]) => <div key={k} className="contents"><dt className="font-semibold">{k}</dt><dd>{v}</dd></div>)}
            </dl>) },
          { id: 'arquivo', titulo: 'Arquivo e arte', conteudo: (
            <div className="space-y-2">
              <p>Aceitamos somente PDF em alta qualidade (de preferência PDF/X-1a): 300 DPI, sangria de 3 mm, textos em curva e cores em CMYK. Você anexa o arquivo no checkout.</p>
              {f.arte_com_sangria && <p>Monte a arte em <b>{f.arte_com_sangria}</b> (com 3 mm de sangria) para o tamanho final de <b>{f.tamanho_final ?? p.formato}</b>, e mantenha textos a pelo menos 3 mm da borda.</p>}
              <p>Não tem certeza se está tudo certo? Escolha a <b>Conferência e ajuste técnico (R$ 14,90)</b>. Sem arte? A <b>Criação completa (R$ 39,90)</b> resolve.</p>
              <p>A arte é enviada depois do pagamento, pelo WhatsApp, e você aprova a prova antes da produção.</p>
            </div>) },
          { id: 'entrega', titulo: 'Prazo e entrega', conteudo: (
            <div className="space-y-2">
              <p>Pedidos pagos até <b>10h30 de dia útil</b> começam a ser produzidos no mesmo dia. Depois disso, entram na fila do próximo dia útil.</p>
              <p>Retirada grátis e agendada no balcão da Praça Sete ({SITE.endereco.rua}). Entrega grátis na região central de BH e envio para todo o Brasil.</p>
            </div>) },
        ]} />
      </div>

      <CompreJunto sugestoes={sugestoes} />

      {p.variacoes.length > 0 && (
        <section className="mt-10">
          <h2 className="mb-4 text-xl font-black">Outras opções de {p.categoria}</h2>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
            {p.variacoes.map((v) => {
              const fv = fotoUrl(v.foto)
              return (
                <Link key={v.produto_slug} href={`/produto/${v.produto_slug}`} className="overflow-hidden rounded-xl2 bg-white text-sm shadow-sm hover:shadow-md">
                  {fv
                    // eslint-disable-next-line @next/next/no-img-element
                    ? <img src={fv} alt="" loading="lazy" className="aspect-square w-full object-cover" />
                    : <div className="aspect-square bg-papel" />}
                  <div className="p-2"><b className="line-clamp-2 leading-snug">{v.titulo}</b>
                    <span className="block text-xs text-black/55">{v.impressao}</span>
                    <span className="text-xs">a partir de <b>{brl(Number(v.a_partir_de))}</b></span></div>
                </Link>)
            })}
          </div>
        </section>
      )}
      <ViewContent nome={p.titulo} categoria={p.categoria} valor={Number(p.a_partir_de)} produtoRef={p.opcoes[0]?.ref ?? ''} />
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
    </div>
  )
}
