'use client'
import dynamic from 'next/dynamic'
import { useCallback, useEffect, useState } from 'react'
import { ChevronDown, CreditCard, Lock, MessageCircle, QrCode, ShieldCheck } from 'lucide-react'
import { Logo } from '@/components/Logo'
import { brl, linkWhatsApp, MENSAGENS_WHATSAPP } from '@/lib/site'
import { chamar, type Checkout, type OpcaoArte } from '@/lib/pagar'
import { ArteUpsell } from './ArteUpsell'
import { BannerCheckout } from './BannerCheckout'
import { Confirmado } from './Confirmado'
import { DadosCliente } from './DadosCliente'
import { Estado } from './Estados'
import { LogoCarregando } from './LogoCarregando'
import { PagamentoPix } from './PagamentoPix'
import { Resumo } from './Resumo'
import { Quantidades } from './Quantidades'
import { Sugestoes } from './Sugestoes'

// O SDK do Mercado Pago só roda no navegador
const PagamentoCartao = dynamic(() => import('./PagamentoCartao'), { ssr: false })

type Fase = { tipo: 'carregando' } | { tipo: 'erro' } | { tipo: 'invalido' } | { tipo: 'ok'; c: Checkout }

/** Checkout próprio da Sua Gráfica BH: dados, arte, Pix e cartão (até 2x sem juros) sem sair do nosso site. */
export function CheckoutCliente({ token }: { token: string }) {
  const [fase, setFase] = useState<Fase>({ tipo: 'carregando' })
  const [aba, setAba] = useState<'pix' | 'cartao'>('pix')
  const [ocupado, setOcupado] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)
  const [erroPag, setErroPag] = useState<string | null>(null)
  const [analise, setAnalise] = useState(false)

  const carregar = useCallback(async (silencioso = false) => {
    if (!silencioso) setFase((f) => (f.tipo === 'ok' ? f : { tipo: 'carregando' }))
    const r = await chamar<Checkout & { erro?: string }>('dados', { acao: 'carregar', token })
    if (r.status === 404) return setFase({ tipo: 'invalido' })
    if (!r.dados.ok) return setFase((f) => (silencioso && f.tipo === 'ok' ? f : { tipo: 'erro' }))
    setFase({ tipo: 'ok', c: r.dados })
  }, [token])

  useEffect(() => { void carregar() }, [carregar])

  // Confirmação em tempo real: confere o pagamento a cada 4 s enquanto a página está aberta
  const estado = fase.tipo === 'ok' ? fase.c.estado : null
  useEffect(() => {
    if (estado !== 'aberto' && estado !== 'em_analise') return
    const t = setInterval(async () => {
      if (document.hidden) return
      const r = await chamar<{ ok?: boolean; pago?: boolean }>('dados', { acao: 'status', token })
      if (r.dados.ok && r.dados.pago) void carregar(true)
    }, 4000)
    return () => clearInterval(t)
  }, [estado, token, carregar])

  async function acao(corpo: Record<string, unknown>) {
    setOcupado(true); setAviso(null)
    const r = await chamar('dados', { token, ...corpo })
    if (!r.dados.ok) setAviso(String(r.dados.mensagem ?? ({ link_expirado: 'Este link venceu.', limite_de_itens: 'Você já adicionou o máximo de sugestões.', ja_no_pedido: 'Este item já está no seu pedido.', arte_incluida: 'A arte já está inclusa.' } as Record<string, string>)[String(r.dados.erro)] ?? 'Não foi possível atualizar o pedido.'))
    await carregar(true)
    setOcupado(false)
  }

  if (fase.tipo === 'carregando') return <LogoCarregando />
  if (fase.tipo === 'invalido') return <Estado tipo="invalido" />
  if (fase.tipo === 'erro') return <Estado tipo="erro" onTentar={() => void carregar()} />
  const c = fase.c
  if (c.estado === 'cancelado') return <Estado tipo="cancelado" />
  if (c.estado === 'expirado') return <Estado tipo="expirado" />

  const topo = (
    <header className="border-b border-black/10 bg-tinta text-white">
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4 py-3">
        <Logo />
        <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1.5 text-xs font-semibold sm:text-sm"><Lock className="h-4 w-4 text-amarelo" aria-hidden />Pagamento seguro</span>
      </div>
    </header>
  )
  if (c.estado === 'pago') return <>{topo}<main className="mx-auto max-w-6xl px-4 py-8"><Confirmado c={c} /></main></>

  const dadosOk = c.faltando.length === 0
  const chave = c.mp.chave_publica
  const emAnalise = analise || c.estado === 'em_analise'

  const aba_cls = (ativa: boolean) => `flex h-14 flex-1 items-center justify-center gap-2 rounded-lg border-2 px-3 text-sm font-black transition-colors sm:text-base ${ativa ? 'border-magenta bg-magenta/5 text-tinta' : 'border-black/10 bg-white text-black/60 hover:border-magenta/40'}`

  return (
    <>
      {topo}
      <main className="mx-auto max-w-6xl px-4 pb-24 pt-4 sm:pt-6">
        <BannerCheckout />
        {c.pedido.teste && <p className="mt-3 rounded-lg bg-amarelo px-3 py-2 text-center text-sm font-black">PEDIDO DE TESTE</p>}
        <h1 className="mb-1 mt-5 text-2xl font-black sm:text-3xl">Finalize o seu pedido</h1>
        <p className="mb-4 text-sm text-black/65">Falta pouco: confira os dados, escolha como está a sua arte e pague. Leva menos de 2 minutos.</p>

        {/* Resumo recolhido no celular */}
        <details className="group mb-4 rounded-xl2 bg-white shadow-sm lg:hidden">
          <summary className="flex min-h-14 cursor-pointer list-none items-center justify-between gap-3 px-4 py-3">
            <span className="font-bold">Ver resumo do pedido <span className="font-normal text-black/55">({c.pedido.numero})</span></span>
            <span className="flex items-center gap-2 text-lg font-black">{brl(c.total)}<ChevronDown className="h-5 w-5 transition-transform group-open:rotate-180" aria-hidden /></span>
          </summary>
          <div className="px-1 pb-1"><Resumo c={c} onRemover={(id) => acao({ acao: 'remover', item: id })} ocupado={ocupado} /></div>
        </details>

        <div className="grid grid-cols-[minmax(0,1fr)] gap-5 lg:grid-cols-[minmax(0,1fr)_380px]">
          <div className="space-y-5">
            {aviso && <p role="alert" className="rounded-lg bg-red-50 p-3 text-sm font-semibold text-red-700">{aviso}</p>}
            <DadosCliente key={dadosOk ? 'ok' : 'falta'} token={token} c={c} onSalvo={() => void carregar(true)} />
            <Quantidades itens={c.quantidades} ocupado={ocupado} onTrocar={(item, ref) => acao({ acao: 'trocar', item, ref })} />
            <ArteUpsell c={c} ocupado={ocupado} onEscolher={(a: OpcaoArte['codigo']) => acao({ acao: 'arte', arte: a })} />

            <section aria-labelledby="pag-t" className="rounded-xl2 bg-white p-5 shadow-sm">
              <h2 id="pag-t" className="text-lg font-black">3. Pagamento</h2>
              {!dadosOk ? (
                <p className="mt-3 rounded-lg bg-papel p-4 text-sm text-black/70"><Lock className="mr-1 inline h-4 w-4" aria-hidden />Preencha e salve os seus dados acima para liberar o pagamento.</p>
              ) : emAnalise ? (
                <p className="entra mt-3 rounded-lg bg-amarelo/30 p-4 text-sm font-semibold">Estamos analisando o seu pagamento. Esta tela atualiza sozinha e a confirmação chega no seu WhatsApp assim que for aprovado.</p>
              ) : (
                <>
                  <div role="tablist" aria-label="Forma de pagamento" className="mt-3 flex gap-2">
                    <button role="tab" aria-selected={aba === 'pix'} type="button" onClick={() => setAba('pix')} className={aba_cls(aba === 'pix')}><QrCode className="h-5 w-5" aria-hidden />Pix<span className="hidden rounded-full bg-[#0E8A3E] px-2 py-0.5 text-[10px] text-white sm:inline">na hora</span></button>
                    <button role="tab" aria-selected={aba === 'cartao'} type="button" onClick={() => setAba('cartao')} className={aba_cls(aba === 'cartao')}><CreditCard className="h-5 w-5" aria-hidden />Cartão<span className="hidden rounded-full bg-amarelo px-2 py-0.5 text-[10px] text-tinta sm:inline">2x sem juros · até {c.pagamento.max_parcelas}x</span></button>
                  </div>
                  {erroPag && <p role="alert" className="entra mt-3 rounded-lg bg-red-50 p-3 text-sm font-semibold text-red-700">{erroPag}</p>}
                  <div className="mt-4" role="tabpanel">
                    {aba === 'pix' && <PagamentoPix key={Math.round(c.total * 100)} token={token} total={c.total} onErro={setErroPag} />}
                    {aba === 'cartao' && (chave
                      ? <PagamentoCartao token={token} total={c.total} email={c.cliente.email} chavePublica={chave} maxParcelas={c.pagamento.max_parcelas} semJuros={c.pagamento.parcelas_sem_juros} onAprovado={() => void carregar(true)} onAnalise={() => { setAnalise(true); void carregar(true) }} onErro={setErroPag} />
                      : <p className="rounded-lg bg-papel p-4 text-sm text-black/70">O pagamento no cartão está indisponível agora. Pague no Pix ou <a className="font-bold text-magenta underline" href={linkWhatsApp(MENSAGENS_WHATSAPP.checkout)} target="_blank" rel="noopener">fale com a gente</a>.</p>)}
                  </div>
                </>
              )}
              <p className="mt-4 flex items-center justify-center gap-1.5 text-xs text-black/55"><ShieldCheck className="h-4 w-4" aria-hidden />Ambiente protegido. Os dados do cartão vão direto ao Mercado Pago e nunca passam pelo nosso servidor.</p>
            </section>

            <Sugestoes itens={c.sugestoes} ocupado={ocupado} onAdicionar={(ref) => acao({ acao: 'adicionar', ref })} />
          </div>

          <aside className="hidden lg:block">
            <div className="sticky top-4 space-y-4">
              <Resumo c={c} onRemover={(id) => acao({ acao: 'remover', item: id })} ocupado={ocupado} />
              <a href={linkWhatsApp(MENSAGENS_WHATSAPP.checkout)} target="_blank" rel="noopener" className="flex items-center justify-center gap-2 rounded-xl2 bg-white p-4 text-sm font-bold shadow-sm hover:text-magenta"><MessageCircle className="h-5 w-5 text-[#25d366]" aria-hidden />Precisa de ajuda? Fale com a gente</a>
            </div>
          </aside>
        </div>
        <p className="mt-6 text-center text-xs text-black/50">Sua Gráfica BH · CNPJ 58.481.181/0001-03 · <a className="underline" href={linkWhatsApp(MENSAGENS_WHATSAPP.checkout)} target="_blank" rel="noopener">Ajuda pelo WhatsApp</a></p>
      </main>
      <a href={linkWhatsApp(MENSAGENS_WHATSAPP.checkout)} target="_blank" rel="noopener" aria-label="Ajuda pelo WhatsApp" className="fixed bottom-4 right-4 z-40 flex h-12 w-12 items-center justify-center rounded-full bg-[#25d366] text-white shadow-lg lg:hidden"><MessageCircle className="h-6 w-6" aria-hidden /></a>
    </>
  )
}
