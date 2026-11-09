'use client'
import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { Check, CheckCircle2, Copy, CreditCard, Loader2, Lock, MapPin, QrCode, Store, Truck } from 'lucide-react'
import { SelosSeguranca } from '@/components/SelosSeguranca'
import { brl, carrinho, mascaraWhatsapp, salvarCarrinhoNoServidor, useCarrinho, whatsappValido, type Arte, type DadosCheckout } from '@/lib/carrinho'
import { rastrear } from '@/lib/meta'
import { MENSAGENS_WHATSAPP, linkWhatsApp } from '@/lib/site'

interface Calculo { ok: boolean; subtotal: number; total: number; arte: { valor: number; texto: string }; prazo?: { data_pronto_texto: string } | null }
interface OpcaoEnvio { servico: 'pac' | 'sedex' | 'mini'; nome: string; valor: number; prazo_dias: number | null }
interface Frete {
  ok: boolean; error?: string
  endereco: { logradouro: string | null; bairro: string | null; cidade: string | null; uf: string | null }
  frete_gratis: boolean; regiao_central: boolean; grande_bh: boolean; falta_para_frete_gratis: number | null
  envio: { disponivel: boolean; motivo: string | null; opcoes: OpcaoEnvio[] }
}
interface Pix { pagamento_id: string; copia_e_cola: string; qr_base64: string | null; expira_em: string | null }
type Etapa = 1 | 2 | 3 | 'pix' | 'pago'

const maskCep = (v: string) => v.replace(/\D/g, '').slice(0, 8).replace(/^(\d{5})(\d)/, '$1-$2')
const campo = 'h-11 w-full rounded-lg border border-black/15 bg-white px-3'
const PASSOS = ['Seus dados', 'Entrega', 'Pagamento']

export function CheckoutCliente() {
  const { itens } = useCarrinho()
  const [etapa, setEtapa] = useState<Etapa>(1)
  const [arte, setArte] = useState<Arte>('pronta')
  const [dados, setDados] = useState<DadosCheckout>({ whatsapp: '', nome: '', email: '', documento: '' })
  const [entrega, setEntrega] = useState<'retirada' | 'entrega'>('retirada')
  const [cep, setCep] = useState('')
  const [frete, setFrete] = useState<Frete | null>(null)
  const [carregandoFrete, setCarregandoFrete] = useState(false)
  const [servico, setServico] = useState<'pac' | 'sedex' | 'mini' | ''>('')
  const [calc, setCalc] = useState<Calculo | null>(null)
  const [metodo, setMetodo] = useState<'pix' | 'cartao'>('pix')
  const [erro, setErro] = useState('')
  const [enviando, setEnviando] = useState(false)
  const [pedido, setPedido] = useState<{ id: string; numero: number } | null>(null)
  const [pix, setPix] = useState<Pix | null>(null)
  const [totalFinal, setTotalFinal] = useState<number | null>(null)
  const [copiado, setCopiado] = useState(false)
  const pronto = useRef(false)

  useEffect(() => {
    setArte(carrinho.arte())
    const d = carrinho.dados()
    const c = carrinho.cliente()
    setDados({ ...d, whatsapp: d.whatsapp || (c ? mascaraWhatsapp(c.whatsapp) : ''), nome: d.nome || c?.nome || '' })
    pronto.current = true
  }, [])

  const chaveItens = JSON.stringify([itens.map((i) => [i.ref, i.quantidade]), arte])
  useEffect(() => {
    if (!itens.length) { setCalc(null); return }
    const ctl = new AbortController()
    fetch('/api/v1/quotes/calculate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ itens: itens.map((i) => ({ ref: i.ref, quantidade: i.quantidade })), arte }) })
      .then((r) => r.json()).then((d: Calculo) => setCalc(d.ok ? d : null)).catch(() => {})
    return () => ctl.abort()
  }, [chaveItens]) // eslint-disable-line react-hooks/exhaustive-deps

  // Frete: consulta quando o CEP fica completo
  const cepLimpo = cep.replace(/\D/g, '')
  useEffect(() => {
    setFrete(null); setServico('')
    if (entrega !== 'entrega' || cepLimpo.length !== 8 || !itens.length) return
    const ctl = new AbortController()
    setCarregandoFrete(true); setErro('')
    fetch('/api/v1/frete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ cep: cepLimpo, arte, itens: itens.map((i) => ({ ref: i.ref, quantidade: i.quantidade })) }) })
      .then((r) => r.json()).then((d: Frete) => { if (d.ok) setFrete(d); else setErro(d.error ?? 'Não foi possível consultar o CEP.') })
      .catch(() => { if (!ctl.signal.aborted) setErro('Sem conexão para consultar o frete.') })
      .finally(() => { if (!ctl.signal.aborted) setCarregandoFrete(false) })
    return () => ctl.abort()
  }, [cepLimpo, entrega, chaveItens]) // eslint-disable-line react-hooks/exhaustive-deps

  const tipoEntrega: 'retirada' | 'entrega' | 'envio' = entrega === 'retirada' ? 'retirada' : frete && !frete.grande_bh ? 'envio' : 'entrega'
  const opcaoEnvio = frete?.envio.opcoes.find((o) => o.servico === servico) ?? null
  const valorFrete = tipoEntrega === 'envio' ? opcaoEnvio?.valor ?? 0 : 0
  const total = calc ? calc.total + valorFrete : null

  // Pix: consulta até o pagamento cair
  useEffect(() => {
    if (etapa !== 'pix' || !pedido) return
    const t = setInterval(() => {
      fetch(`/api/v1/pedido/status?id=${pedido.id}`).then((r) => r.json()).then((d: { pago?: boolean }) => { if (d.pago) setEtapa('pago') }).catch(() => {})
    }, 4000)
    return () => clearInterval(t)
  }, [etapa, pedido])

  function irParaEntrega(e: React.FormEvent) {
    e.preventDefault(); setErro('')
    if (!whatsappValido(dados.whatsapp)) return setErro('Informe um WhatsApp válido com DDD.')
    if (dados.nome.trim().split(/\s+/).length < 2) return setErro('Informe seu nome e sobrenome.')
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(dados.email.trim())) return setErro('Informe um e-mail válido (o Pix e a nota fiscal usam esse e-mail).')
    const doc = dados.documento.replace(/\D/g, '')
    if (doc && doc.length !== 11 && doc.length !== 14) return setErro('CPF tem 11 números e CNPJ tem 14. Pode deixar em branco se preferir.')
    carrinho.salvarDados(dados)
    carrinho.salvarCliente({ whatsapp: dados.whatsapp.replace(/\D/g, ''), nome: dados.nome.trim() })
    salvarCarrinhoNoServidor(itens, dados, { arte, entrega })
    setEtapa(2)
  }

  function irParaPagamento() {
    setErro('')
    if (entrega === 'entrega') {
      if (cepLimpo.length !== 8) return setErro('Informe o CEP para a entrega.')
      if (!frete) return setErro('Aguarde a consulta do CEP.')
      if (tipoEntrega === 'envio' && !opcaoEnvio) return setErro(frete.envio.disponivel ? 'Escolha o serviço de envio.' : 'Vamos calcular o frete para o seu CEP pelo WhatsApp. Chame a gente abaixo ou escolha retirar no balcão.')
    }
    salvarCarrinhoNoServidor(itens, dados, { arte, entrega, cep: entrega === 'entrega' ? cepLimpo : null })
    void rastrear('InitiateCheckout', { content_ids: itens.map((i) => i.ref), num_items: itens.length, value: total ?? 0, currency: 'BRL' })
    setEtapa(3)
  }

  async function pagar() {
    setErro(''); setEnviando(true)
    try {
      // pedido já criado (troca de forma de pagamento ou nova tentativa): não cria outro
      const r = pedido
        ? await fetch('/api/v1/checkout/pay', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pedido_id: pedido.id, metodo, email: dados.email }) })
        : await fetch('/api/v1/checkout/create-preference', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              cliente: dados, itens: itens.map((i) => ({ ref: i.ref, quantidade: i.quantidade })),
              opcoes: { arte, entrega: tipoEntrega, cep: entrega === 'entrega' ? cepLimpo : null, frete_servico: tipoEntrega === 'envio' ? servico : null, pagamento: metodo, sessao: carrinho.sessao() },
            }),
          })
      const d = await r.json() as { ok?: boolean; error?: string; pedido_id?: string; numero?: number; total?: number; link_pagamento?: string; pix?: Pix }
      if (d.pedido_id && d.numero && !pedido) setPedido({ id: d.pedido_id, numero: d.numero })
      if (!r.ok) { setErro(d.error ?? 'Não foi possível concluir. Tente de novo.'); setEnviando(false); return }
      if (d.total) setTotalFinal(d.total)
      if (metodo === 'cartao' && d.link_pagamento) { carrinho.limpar(); window.location.href = d.link_pagamento; return }
      if (metodo === 'pix' && d.pix) {
        carrinho.limpar()
        if (d.pedido_id && d.numero) setPedido({ id: d.pedido_id, numero: d.numero })
        setPix(d.pix); setEtapa('pix'); setEnviando(false); return
      }
      setErro('Resposta inesperada do servidor. Tente de novo.')
    } catch {
      setErro('Sem conexão com o servidor. Tente de novo.')
    }
    setEnviando(false)
  }

  async function trocarParaCartao() {
    if (!pedido) return
    setErro(''); setEnviando(true)
    const r = await fetch('/api/v1/checkout/pay', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pedido_id: pedido.id, metodo: 'cartao' }) }).catch(() => null)
    const d = r ? await r.json().catch(() => ({})) as { link_pagamento?: string; error?: string } : {}
    if (r?.ok && d.link_pagamento) { window.location.href = d.link_pagamento; return }
    setErro(d.error ?? 'Não foi possível abrir o pagamento no cartão.'); setEnviando(false)
  }

  async function copiar() {
    if (!pix) return
    try { await navigator.clipboard.writeText(pix.copia_e_cola) } catch { /* navegador sem permissão */ }
    setCopiado(true); setTimeout(() => setCopiado(false), 2500)
  }

  if (etapa === 'pago') {
    return (
      <div className="mx-auto max-w-xl px-4 py-16 text-center">
        <CheckCircle2 className="mx-auto h-14 w-14 text-green-600" aria-hidden />
        <h1 className="mt-4 text-2xl font-black">Pagamento confirmado!</h1>
        <p className="mt-2 text-black/70">Pedido <b>SG-{String(pedido?.numero ?? '').padStart(4, '0')}</b> recebido. A gente chama você no WhatsApp para confirmar a arte e o prazo.</p>
        <Link href="/" className="mt-6 inline-block rounded-lg bg-amarelo px-5 py-3 font-bold">Voltar para a loja</Link>
      </div>
    )
  }

  if (etapa === 'pix' && pix) {
    return (
      <div className="mx-auto max-w-xl px-4 py-10">
        <h1 className="text-2xl font-black">Pague com Pix</h1>
        <p className="mt-1 text-sm text-black/65">Pedido <b>SG-{String(pedido?.numero ?? '').padStart(4, '0')}</b> · total <b>{brl(totalFinal ?? total ?? 0)}</b>. Abra o app do seu banco, escolha Pix e leia o QR Code ou cole o código.</p>
        <div className="mt-5 space-y-4 rounded-xl2 bg-white p-5 text-center shadow-sm">
          {pix.qr_base64
            // eslint-disable-next-line @next/next/no-img-element
            ? <img src={`data:image/png;base64,${pix.qr_base64}`} alt="QR Code do Pix" className="mx-auto h-56 w-56" />
            : <QrCode className="mx-auto h-24 w-24 text-black/30" aria-hidden />}
          <div>
            <label htmlFor="copia" className="text-xs font-bold uppercase tracking-wide text-black/60">Pix copia e cola</label>
            <textarea id="copia" readOnly value={pix.copia_e_cola} rows={3} onFocus={(e) => e.currentTarget.select()} className="mt-1 w-full rounded-lg border border-black/15 bg-papel p-2 text-xs" />
          </div>
          <button onClick={copiar} className="flex h-12 w-full items-center justify-center gap-2 rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro">
            {copiado ? <Check className="h-4 w-4" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />}{copiado ? 'Código copiado!' : 'Copiar código Pix'}
          </button>
          <p role="status" className="flex items-center justify-center gap-2 text-sm text-black/65"><Loader2 className="h-4 w-4 animate-spin" aria-hidden />Aguardando o pagamento. Esta tela confirma sozinha.</p>
        </div>
        {erro && <p role="alert" className="mt-3 rounded-lg bg-magenta/10 p-2 text-sm">{erro}</p>}
        <button onClick={trocarParaCartao} disabled={enviando} className="mt-4 w-full text-center text-sm font-semibold underline underline-offset-2 disabled:opacity-60">Prefiro pagar no cartão (até 2x sem juros)</button>
        <p className="mt-3 text-center text-xs text-black/50">O Pix vale por 24 horas. Se a tela fechar, o pedido continua salvo e o pagamento é reconhecido do mesmo jeito.</p>
      </div>
    )
  }

  if (!itens.length) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-16 text-center">
        <h1 className="text-2xl font-black">Seu carrinho está vazio</h1>
        <Link href="/categorias" className="mt-6 inline-block rounded-lg bg-amarelo px-5 py-3 font-bold">Ver produtos</Link>
      </div>
    )
  }

  const passo = etapa as 1 | 2 | 3
  return (
    <div className="mx-auto grid max-w-6xl gap-8 px-4 py-8 lg:grid-cols-[1fr_380px]">
      <div className="space-y-5">
        <ol className="flex items-center gap-2 text-sm" aria-label="Etapas">
          {PASSOS.map((p, i) => (
            <li key={p} className={`flex items-center gap-2 font-bold ${passo === i + 1 ? 'text-tinta' : passo > i + 1 ? 'text-green-700' : 'text-black/35'}`} aria-current={passo === i + 1 ? 'step' : undefined}>
              <span className={`flex h-7 w-7 items-center justify-center rounded-full text-xs ${passo === i + 1 ? 'bg-amarelo' : passo > i + 1 ? 'bg-green-600 text-white' : 'bg-black/10'}`}>{passo > i + 1 ? <Check className="h-4 w-4" aria-hidden /> : i + 1}</span>
              <span className="hidden sm:inline">{p}</span>{i < 2 && <span className="mx-1 h-px w-6 bg-black/15" aria-hidden />}
            </li>
          ))}
        </ol>

        {etapa === 1 && (
          <form onSubmit={irParaEntrega} className="space-y-3 rounded-xl2 bg-white p-5 shadow-sm">
            <h1 className="text-xl font-black">Seus dados</h1>
            <p className="text-sm text-black/60">Usamos o WhatsApp para falar da arte e do andamento do pedido.</p>
            <input required inputMode="tel" autoComplete="tel" value={dados.whatsapp} onChange={(e) => setDados({ ...dados, whatsapp: mascaraWhatsapp(e.target.value) })} placeholder="WhatsApp com DDD" aria-label="WhatsApp" className={campo} />
            <input required autoComplete="name" value={dados.nome} onChange={(e) => setDados({ ...dados, nome: e.target.value })} placeholder="Nome completo" aria-label="Nome completo" className={campo} />
            <input required type="email" autoComplete="email" value={dados.email} onChange={(e) => setDados({ ...dados, email: e.target.value })} placeholder="E-mail (Pix e nota fiscal)" aria-label="E-mail" className={campo} />
            <input inputMode="numeric" value={dados.documento} onChange={(e) => setDados({ ...dados, documento: e.target.value })} placeholder="CPF ou CNPJ na nota (opcional)" aria-label="CPF ou CNPJ" className={campo} />
            {erro && <p role="alert" className="rounded-lg bg-magenta/10 p-2 text-sm">{erro}</p>}
            <button className="flex h-12 w-full items-center justify-center rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro">Continuar para a entrega</button>
          </form>
        )}

        {etapa === 2 && (
          <div className="space-y-4 rounded-xl2 bg-white p-5 shadow-sm">
            <h1 className="text-xl font-black">Entrega</h1>
            <label className={`flex cursor-pointer items-start gap-3 rounded-lg border p-3 ${entrega === 'retirada' ? 'border-tinta bg-papel' : 'border-black/15'}`}>
              <input type="radio" name="entrega" checked={entrega === 'retirada'} onChange={() => setEntrega('retirada')} className="mt-1 accent-magenta" />
              <span className="text-sm"><b className="flex items-center gap-1"><Store className="h-4 w-4" aria-hidden />Retirar no balcão · grátis</b>Retirada agendada na Praça Sete, Centro de BH. Avisamos quando estiver pronto.</span>
            </label>
            <label className={`flex cursor-pointer items-start gap-3 rounded-lg border p-3 ${entrega === 'entrega' ? 'border-tinta bg-papel' : 'border-black/15'}`}>
              <input type="radio" name="entrega" checked={entrega === 'entrega'} onChange={() => setEntrega('entrega')} className="mt-1 accent-magenta" />
              <span className="text-sm"><b className="flex items-center gap-1"><Truck className="h-4 w-4" aria-hidden />Receber no meu endereço</b>Entrega grátis nos bairros centrais de BH; Grande BH por aplicativo; todo o Brasil pelos Correios.</span>
            </label>
            {entrega === 'entrega' && (
              <div className="space-y-3">
                <input inputMode="numeric" value={cep} onChange={(e) => setCep(maskCep(e.target.value))} placeholder="Seu CEP" aria-label="CEP" className={`${campo} w-48`} />
                {carregandoFrete && <p className="flex items-center gap-2 text-sm text-black/60"><Loader2 className="h-4 w-4 animate-spin" aria-hidden />Consultando o CEP...</p>}
                {frete && (
                  <div className="space-y-2 text-sm">
                    <p className="flex items-start gap-2"><MapPin className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /><span>{[frete.endereco.logradouro, frete.endereco.bairro, frete.endereco.cidade && `${frete.endereco.cidade}/${frete.endereco.uf}`].filter(Boolean).join(' · ')}</span></p>
                    {frete.frete_gratis && <p className="rounded-lg bg-green-50 p-3 font-semibold text-green-800">Entrega grátis no seu bairro, em horário comercial.</p>}
                    {!frete.frete_gratis && frete.regiao_central && !!frete.falta_para_frete_gratis && (
                      <p className="rounded-lg bg-amarelo/30 p-3">Seu bairro tem entrega grátis: faltam <b>{brl(frete.falta_para_frete_gratis)}</b> no pedido para liberar. Se preferir, a entrega por aplicativo é combinada no WhatsApp.</p>
                    )}
                    {!frete.frete_gratis && frete.grande_bh && <p className="rounded-lg bg-papel p-3">Entrega por aplicativo (moto ou carro). O valor é confirmado com você no WhatsApp antes de sair, e não entra no pagamento de agora.</p>}
                    {!frete.grande_bh && frete.envio.disponivel && (
                      <fieldset className="space-y-2"><legend className="font-bold">Envio pelos Correios</legend>
                        {frete.envio.opcoes.map((o) => (
                          <label key={o.servico} className={`flex cursor-pointer items-center justify-between gap-3 rounded-lg border p-3 ${servico === o.servico ? 'border-tinta bg-papel' : 'border-black/15'}`}>
                            <span className="flex items-center gap-2"><input type="radio" name="servico" checked={servico === o.servico} onChange={() => setServico(o.servico)} className="accent-magenta" />{o.nome}{o.prazo_dias ? <span className="text-black/55"> · até {o.prazo_dias} dias úteis após o envio</span> : null}</span>
                            <b>{brl(o.valor)}</b>
                          </label>))}
                        <p className="text-xs text-black/55">O prazo dos Correios conta depois que o pedido fica pronto.</p>
                      </fieldset>
                    )}
                    {!frete.grande_bh && !frete.envio.disponivel && (
                      <p className="rounded-lg bg-papel p-3">Para o seu CEP calculamos o frete com você pelo WhatsApp. <a className="font-bold underline" target="_blank" rel="noopener" href={linkWhatsApp(MENSAGENS_WHATSAPP.checkout)}>Chamar no WhatsApp</a> ou escolha retirar no balcão.</p>
                    )}
                  </div>
                )}
              </div>
            )}
            {erro && <p role="alert" className="rounded-lg bg-magenta/10 p-2 text-sm">{erro}</p>}
            <div className="flex gap-3">
              <button onClick={() => { setErro(''); setEtapa(1) }} className="h-12 rounded-lg border border-black/20 px-5 font-semibold">Voltar</button>
              <button onClick={irParaPagamento} className="h-12 flex-1 rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro">Continuar para o pagamento</button>
            </div>
          </div>
        )}

        {etapa === 3 && (
          <div className="space-y-4 rounded-xl2 bg-white p-5 shadow-sm">
            <h1 className="text-xl font-black">Pagamento</h1>
            <label className={`flex cursor-pointer items-start gap-3 rounded-lg border p-3 ${metodo === 'pix' ? 'border-tinta bg-papel' : 'border-black/15'}`}>
              <input type="radio" name="metodo" checked={metodo === 'pix'} onChange={() => setMetodo('pix')} className="mt-1 accent-magenta" />
              <span className="text-sm"><b className="flex items-center gap-1"><QrCode className="h-4 w-4" aria-hidden />Pix · {total != null ? brl(total) : '...'}</b>QR Code e copia e cola na próxima tela. Aprovação na hora, de qualquer banco.</span>
            </label>
            <label className={`flex cursor-pointer items-start gap-3 rounded-lg border p-3 ${metodo === 'cartao' ? 'border-tinta bg-papel' : 'border-black/15'}`}>
              <input type="radio" name="metodo" checked={metodo === 'cartao'} onChange={() => setMetodo('cartao')} className="mt-1 accent-magenta" />
              <span className="text-sm"><b className="flex items-center gap-1"><CreditCard className="h-4 w-4" aria-hidden />Cartão · 2x de {total != null ? brl(total / 2) : '...'} sem juros</b>Pagamento seguro pelo Mercado Pago, com opção de mais parcelas com juros.</span>
            </label>
            {erro && <p role="alert" className="rounded-lg bg-magenta/10 p-2 text-sm">{erro}</p>}
            <div className="flex gap-3">
              <button onClick={() => { setErro(''); setEtapa(2) }} disabled={enviando || !!pedido} className="h-12 rounded-lg border border-black/20 px-5 font-semibold disabled:opacity-50">Voltar</button>
              <button onClick={pagar} disabled={enviando || total == null} className="flex h-12 flex-1 items-center justify-center gap-2 rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro disabled:opacity-60">
                {enviando ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Lock className="h-4 w-4" aria-hidden />}{metodo === 'pix' ? 'Gerar Pix' : 'Pagar no cartão'}
              </button>
            </div>
          </div>
        )}
      </div>

      <aside className="space-y-4 lg:sticky lg:top-24 lg:self-start">
        <div className="space-y-2 rounded-xl2 bg-tinta p-5 text-white">
          <h2 className="text-sm font-black uppercase tracking-wide">Resumo</h2>
          <ul className="space-y-1 text-sm text-white/85">{itens.map((i) => <li key={i.ref} className="flex justify-between gap-3"><span className="truncate">{i.quantidade}× {i.titulo}</span></li>)}</ul>
          <div className="flex justify-between border-t border-white/15 pt-2 text-sm"><span>Produtos</span><span>{calc ? brl(calc.subtotal) : '...'}</span></div>
          <div className="flex justify-between text-sm"><span>Arte</span><span>{calc ? (calc.arte.valor ? brl(calc.arte.valor) : 'grátis') : '...'}</span></div>
          <div className="flex justify-between text-sm"><span>Entrega</span><span>{tipoEntrega === 'retirada' ? 'retirada grátis' : tipoEntrega === 'envio' ? (opcaoEnvio ? brl(opcaoEnvio.valor) : 'escolha o envio') : frete?.frete_gratis ? 'grátis' : frete ? 'combinada no WhatsApp' : 'informe o CEP'}</span></div>
          <div className="flex items-end justify-between border-t border-white/15 pt-3"><span className="text-sm">Total no Pix</span><span className="text-3xl font-black">{total != null ? brl(total) : '...'}</span></div>
          {calc?.prazo && <p className="text-xs text-white/80">Fica pronto <b>{calc.prazo.data_pronto_texto}</b> se pagar e liberar a arte até 10h30 de hoje (dia útil).</p>}
        </div>
        <SelosSeguranca escuro={false} />
        <Link href="/carrinho" className="block text-center text-sm underline underline-offset-2">Voltar ao carrinho</Link>
      </aside>
    </div>
  )
}
