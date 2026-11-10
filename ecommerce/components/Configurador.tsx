'use client'
import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { CalendarCheck, Check, Loader2, MapPin, ShoppingCart, Rocket } from 'lucide-react'
import { brl, carrinho, type Arte } from '@/lib/carrinho'
import { rastrear } from '@/lib/meta'
import { ModalWhatsApp } from './ModalWhatsApp'
import type { Opcao } from '@/lib/vitrine'

interface Cotacao {
  ok: boolean; preco: number; total: number; arte: { tipo: Arte; valor: number; texto: string }
  pagamento: { parcela_sem_juros: number; texto: string }
  prazo?: { ok: boolean; data_pronto_texto: string; frase: string }
  frete?: { ok: boolean; frete_gratis: boolean; regiao_central: boolean; falta_para_frete_gratis: number | null; opcoes: { tipo: string; texto: string; valor: number | null }[] } | null
}

const ARTES: { id: Arte; titulo: string; texto: string; valor: string }[] = [
  { id: 'pronta', titulo: 'Já tenho a arte pronta', texto: 'Você envia o arquivo (PDF, CDR, AI, PNG ou JPG) depois do pagamento.', valor: 'Grátis' },
  { id: 'conferencia', titulo: 'Conferência e ajuste técnico', texto: 'Conferimos sangria de 3 mm, margem de segurança, cores para impressão, resolução e fechamos o PDF certinho.', valor: '+ R$ 14,90' },
  { id: 'criacao', titulo: 'Criação completa da arte', texto: 'Nossa equipe cria do zero com as suas informações. Acrescenta 1 dia útil ao prazo.', valor: '+ R$ 39,90' },
]

export interface Irmao { produto_slug: string; impressao: string | null; formato: string | null; a_partir_de: number }

export function Configurador({ slug, titulo, foto, opcoes, irmaos = [], formato = null }: { slug: string; titulo: string; foto: string | null; opcoes: Opcao[]; irmaos?: Irmao[]; formato?: string | null }) {
  const mesmoTamanho = irmaos.filter((i) => i.formato === formato)
  const router = useRouter()
  const [ref, setRef] = useState(opcoes[0]?.ref)
  const [arte, setArte] = useState<Arte>('pronta')
  const [cep, setCep] = useState('')
  const [cot, setCot] = useState<Cotacao | null>(null)
  const [carregando, setCarregando] = useState(false)
  const [modal, setModal] = useState<null | 'carrinho' | 'comprar'>(null)
  const [adicionado, setAdicionado] = useState(false)
  const opcao = opcoes.find((o) => o.ref === ref)

  useEffect(() => { setArte(carrinho.arte()) }, [])
  useEffect(() => {
    if (!ref) return
    const c = cep.replace(/\D/g, '')
    if (c && c.length !== 8) return
    const ctl = new AbortController()
    setCarregando(true)
    fetch(`/api/v1/products/${ref}/quote?arte=${arte}${c ? `&cep=${c}` : ''}`, { signal: ctl.signal })
      .then((r) => r.json()).then((d: Cotacao) => setCot(d.ok ? d : null)).catch(() => {}).finally(() => setCarregando(false))
    return () => ctl.abort()
  }, [ref, arte, cep])

  function concluir(destino: 'carrinho' | 'comprar') {
    if (!opcao) return
    carrinho.salvarArte(arte)
    carrinho.adicionar({ ref: opcao.ref, quantidade: 1, titulo, unidades: opcao.quantidade, preco: Number(opcao.preco), foto, slug })
    setAdicionado(true)
    void rastrear('AddToCart', { content_ids: [opcao.ref], content_name: titulo, content_type: 'product', value: Number(cot?.total ?? opcao.preco), currency: 'BRL' })
    if (destino === 'comprar') router.push('/carrinho')
  }
  function acao(destino: 'carrinho' | 'comprar') {
    if (!carrinho.cliente()) return setModal(destino)
    concluir(destino)
  }

  return (
    <div className="space-y-6">
      {mesmoTamanho.length > 1 && (
        <section>
          <h2 className="mb-2 text-sm font-black uppercase tracking-wide">Impressão</h2>
          <div className="flex flex-wrap gap-2">
            {mesmoTamanho.map((i) => (
              <Link key={i.produto_slug} href={`/produto/${i.produto_slug}`} scroll={false} aria-current={i.produto_slug === slug ? 'page' : undefined}
                className={`rounded-lg border-2 px-3 py-2 text-sm ${i.produto_slug === slug ? 'border-magenta bg-magenta/5 font-bold' : 'border-black/10 hover:border-black/30'}`}>
                {i.impressao}<span className="block text-xs font-normal text-black/55">a partir de {brl(Number(i.a_partir_de))}</span>
              </Link>
            ))}
          </div>
        </section>
      )}

      <section>
        <h2 className="mb-2 text-sm font-black uppercase tracking-wide">1. Escolha a tiragem</h2>
        <div role="radiogroup" aria-label="Tiragem" className="overflow-hidden rounded-lg border border-black/10">
          {opcoes.map((o) => {
            const un = o.quantidade ?? 1
            return (
              <button key={o.ref} type="button" role="radio" aria-checked={o.ref === ref} onClick={() => setRef(o.ref)}
                className={`flex min-h-12 w-full items-center justify-between gap-3 border-b border-black/5 px-3 py-2 text-left text-sm last:border-b-0 ${o.ref === ref ? 'bg-magenta/5 font-bold ring-2 ring-inset ring-magenta' : 'hover:bg-papel'}`}>
                <span>{o.quantidade ? `${o.quantidade.toLocaleString('pt-BR')} un.` : '1 un.'}</span>
                <span className="text-xs text-black/60">{brl(Number(o.preco) / un)} cada</span>
                <span>{brl(Number(o.preco))}</span>
              </button>
            )
          })}
        </div>
        {opcao?.sku && <p className="mt-2 text-xs text-black/60">Ref. / SKU: <b className="font-mono text-tinta">{opcao.sku}</b></p>}
      </section>

      <section>
        <h2 className="mb-2 text-sm font-black uppercase tracking-wide">2. Sua arte</h2>
        <div className="space-y-2">
          {ARTES.map((a) => (
            <label key={a.id} className={`flex cursor-pointer gap-3 rounded-lg border-2 p-3 text-sm transition ${arte === a.id ? 'border-magenta bg-magenta/5' : 'border-black/10 hover:border-black/30'}`}>
              <input type="radio" name="arte" value={a.id} checked={arte === a.id} onChange={() => setArte(a.id)} className="mt-1 accent-magenta" />
              <span className="flex-1"><b className="flex justify-between gap-2"><span>{a.titulo}</span><span className="whitespace-nowrap">{a.valor}</span></b>
                <span className="text-xs text-black/60">{a.texto}</span></span>
            </label>
          ))}
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-sm font-black uppercase tracking-wide">3. Entrega (opcional)</h2>
        <label className="flex items-center gap-2 rounded-lg border border-black/15 px-3">
          <MapPin className="h-4 w-4 text-black/40" aria-hidden />
          <input inputMode="numeric" value={cep} onChange={(e) => setCep(e.target.value.replace(/\D/g, '').slice(0, 8).replace(/^(\d{5})(\d)/, '$1-$2'))}
            placeholder="Digite seu CEP" aria-label="CEP" className="h-11 flex-1 outline-none" />
        </label>
        {cot?.frete?.opcoes && (
          <ul className="mt-2 space-y-1 text-sm">
            {cot.frete.opcoes.map((o) => (
              <li key={o.tipo} className="flex items-start gap-2"><Check className="mt-0.5 h-4 w-4 shrink-0 text-[#0E8A3E]" aria-hidden />
                <span>{o.texto}{o.valor === 0 ? ' · grátis' : ''}</span></li>
            ))}
            {cot.frete.regiao_central && !cot.frete.frete_gratis && cot.frete.falta_para_frete_gratis
              ? <li className="text-xs text-black/60">Faltam {brl(Number(cot.frete.falta_para_frete_gratis))} para a entrega grátis na região central.</li> : null}
          </ul>
        )}
      </section>

      <div className="rounded-xl2 bg-tinta p-5 text-white">
        <div className="flex items-end justify-between gap-3">
          <div>
            <span className="text-xs text-white/60">Total no Pix</span>
            <div className="text-3xl font-black">{cot ? brl(Number(cot.total)) : opcao ? brl(Number(opcao.preco)) : '...'}</div>
            <div className="text-xs text-white/70">{cot ? `ou 2x de ${brl(Number(cot.pagamento.parcela_sem_juros))} sem juros` : ' '}</div>
          </div>
          {carregando && <Loader2 className="h-5 w-5 animate-spin text-white/60" aria-label="Calculando" />}
        </div>
        {cot?.prazo?.ok && (
          <p className="mt-3 flex items-start gap-2 text-sm text-white/85"><CalendarCheck className="mt-0.5 h-4 w-4 shrink-0 text-amarelo" aria-hidden />
            <span>Fica pronto <b>{cot.prazo.data_pronto_texto}</b> se pagar e liberar a arte até 10h30 de hoje (dia útil).</span></p>
        )}
        <div className="mt-4 grid gap-2 sm:grid-cols-2">
          <button type="button" onClick={() => acao('comprar')} className="flex h-12 items-center justify-center gap-2 rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro">
            <Rocket className="h-4 w-4" aria-hidden />Comprar agora
          </button>
          <button type="button" onClick={() => acao('carrinho')} data-evento="AddToCart" className="flex h-12 items-center justify-center gap-2 rounded-lg border border-white/30 font-semibold hover:border-white">
            <ShoppingCart className="h-4 w-4" aria-hidden />{adicionado ? 'Adicionado!' : 'Adicionar ao carrinho'}
          </button>
        </div>
        {adicionado && <a href="/carrinho" className="mt-2 block text-center text-sm font-semibold text-amarelo underline">Ver carrinho</a>}
      </div>
      <ModalWhatsApp aberto={!!modal} onFechar={() => setModal(null)} onConfirmar={() => { const d = modal; setModal(null); if (d) concluir(d) }} />
    </div>
  )
}
