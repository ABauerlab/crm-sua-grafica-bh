'use client'
import { useEffect, useState } from 'react'
import Link from 'next/link'
import { Loader2, Lock, Minus, Plus, Trash2 } from 'lucide-react'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { SelosSeguranca } from '@/components/SelosSeguranca'
import { brl, carrinho, mascaraWhatsapp, useCarrinho, whatsappValido, type Arte } from '@/lib/carrinho'
import { fotoUrl } from '@/lib/vitrine'
import { rastrear } from '@/lib/meta'

interface Calculo {
  ok: boolean; subtotal: number; total: number; arte: { tipo: Arte; valor: number; texto: string }
  pagamento: { parcela_sem_juros: number }; prazo?: { data_pronto_texto: string } | null
  itens: { ref: string; preco: number; unidades: number }[]
  frete?: { frete_gratis: boolean; opcoes: { tipo: string; texto: string; valor: number | null }[] } | null
}

const ARTES: [Arte, string][] = [['pronta', 'Já tenho a arte pronta (grátis)'], ['conferencia', 'Conferência e ajuste técnico (+ R$ 14,90)'], ['criacao', 'Criação completa da arte (+ R$ 39,90)']]

export function CarrinhoCliente() {
  const { itens, cliente } = useCarrinho()
  const [arte, setArte] = useState<Arte>('pronta')
  const [entrega, setEntrega] = useState<'retirada' | 'entrega'>('retirada')
  const [cep, setCep] = useState('')
  const [calc, setCalc] = useState<Calculo | null>(null)
  const [dados, setDados] = useState({ whatsapp: '', nome: '', email: '', documento: '' })
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState('')

  useEffect(() => { setArte(carrinho.arte()) }, [])
  useEffect(() => { if (cliente) setDados((d) => ({ ...d, whatsapp: d.whatsapp || mascaraWhatsapp(cliente.whatsapp), nome: d.nome || cliente.nome })) }, [cliente])
  const chave = JSON.stringify([itens.map((i) => [i.ref, i.quantidade]), arte, entrega, cep])
  useEffect(() => {
    if (!itens.length) { setCalc(null); return }
    const c = cep.replace(/\D/g, '')
    const ctl = new AbortController()
    fetch('/api/v1/quotes/calculate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ itens: itens.map((i) => ({ ref: i.ref, quantidade: i.quantidade })), arte, cep: entrega === 'entrega' && c.length === 8 ? c : null }) })
      .then((r) => r.json()).then((d: Calculo) => setCalc(d.ok ? d : null)).catch(() => {})
    return () => ctl.abort()
  }, [chave]) // eslint-disable-line react-hooks/exhaustive-deps

  async function finalizar(e: React.FormEvent) {
    e.preventDefault()
    setErro('')
    if (!whatsappValido(dados.whatsapp)) return setErro('Informe um WhatsApp válido com DDD.')
    if (dados.nome.trim().length < 3) return setErro('Informe seu nome completo.')
    if (entrega === 'entrega' && cep.replace(/\D/g, '').length !== 8) return setErro('Informe o CEP para a entrega.')
    setEnviando(true)
    await rastrear('InitiateCheckout', { content_ids: itens.map((i) => i.ref), num_items: itens.length, value: Number(calc?.total ?? 0), currency: 'BRL' })
    carrinho.salvarCliente({ whatsapp: dados.whatsapp.replace(/\D/g, ''), nome: dados.nome.trim() })
    try {
      const r = await fetch('/api/v1/checkout/create-preference', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cliente: dados, itens: itens.map((i) => ({ ref: i.ref, quantidade: i.quantidade })), opcoes: { arte, entrega, cep: entrega === 'entrega' ? cep : null } }),
      })
      const d = await r.json() as { ok?: boolean; link_pagamento?: string; error?: string }
      if (!r.ok || !d.link_pagamento) { setErro(d.error ?? 'Não foi possível criar o pedido. Tente de novo.'); setEnviando(false); return }
      carrinho.limpar()
      window.location.href = d.link_pagamento
    } catch {
      setErro('Sem conexão com o servidor. Tente de novo.')
      setEnviando(false)
    }
  }

  if (!itens.length) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-16 text-center">
        <h1 className="text-2xl font-black">Seu carrinho está vazio</h1>
        <p className="mt-2 text-sm text-black/60">Escolha um produto e configure a quantidade e a arte.</p>
        <Link href="/categorias" className="mt-6 inline-block rounded-lg bg-amarelo px-5 py-3 font-bold">Ver produtos</Link>
      </div>
    )
  }

  const precoDe = (ref: string, padrao: number) => calc?.itens.find((x) => x.ref === ref)?.preco ?? padrao
  return (
    <form onSubmit={finalizar} className="mx-auto grid max-w-7xl gap-8 px-4 py-8 lg:grid-cols-[1fr_400px]">
      <div className="space-y-6">
        <h1 className="text-2xl font-black">Carrinho</h1>
        <ul className="divide-y divide-black/5 rounded-xl2 bg-white shadow-sm">
          {itens.map((i) => {
            const f = fotoUrl(i.foto)
            return (
              <li key={i.ref} className="flex gap-3 p-4">
                {f
                  // eslint-disable-next-line @next/next/no-img-element
                  ? <img src={f} alt="" className="h-20 w-20 shrink-0 rounded-lg object-cover" />
                  : <div className="h-20 w-20 shrink-0 rounded-lg bg-papel" />}
                <div className="flex flex-1 flex-col gap-1">
                  <Link href={`/produto/${i.slug}`} className="text-sm font-bold leading-snug hover:text-magenta">{i.titulo}</Link>
                  <span className="text-xs text-black/55">{`${((i.unidades ?? 1) * i.quantidade).toLocaleString('pt-BR')} ${(i.unidades ?? 1) * i.quantidade === 1 ? 'unidade' : 'unidades'}`}</span>
                  <div className="mt-auto flex items-center justify-between gap-2">
                    <div className="flex items-center rounded-lg border border-black/15">
                      <button type="button" aria-label="Diminuir" onClick={() => carrinho.alterar(i.ref, i.quantidade - 1)} className="p-2"><Minus className="h-4 w-4" /></button>
                      <span className="w-8 text-center text-sm font-semibold">{i.quantidade}</span>
                      <button type="button" aria-label="Aumentar" onClick={() => carrinho.alterar(i.ref, i.quantidade + 1)} className="p-2"><Plus className="h-4 w-4" /></button>
                    </div>
                    <span className="font-black">{brl(Number(precoDe(i.ref, i.preco * i.quantidade)))}</span>
                    <button type="button" aria-label="Remover" onClick={() => carrinho.remover(i.ref)} className="p-2 text-black/40 hover:text-magenta"><Trash2 className="h-4 w-4" /></button>
                  </div>
                </div>
              </li>)
          })}
        </ul>

        <div role="group" className="space-y-2 rounded-xl2 bg-white p-4 shadow-sm">
          <h2 className="text-sm font-black uppercase tracking-wide">Arte do pedido</h2>
          {ARTES.map(([id, t]) => (
            <label key={id} className="flex items-center gap-2 text-sm"><input type="radio" name="arte" checked={arte === id} onChange={() => { setArte(id); carrinho.salvarArte(id) }} className="accent-magenta" />{t}</label>
          ))}
        </div>

        <div role="group" className="space-y-2 rounded-xl2 bg-white p-4 shadow-sm">
          <h2 className="text-sm font-black uppercase tracking-wide">Entrega</h2>
          <label className="flex items-center gap-2 text-sm"><input type="radio" name="entrega" checked={entrega === 'retirada'} onChange={() => setEntrega('retirada')} className="accent-magenta" />Retirada grátis e agendada no balcão da Praça Sete (Centro de BH)</label>
          <label className="flex items-center gap-2 text-sm"><input type="radio" name="entrega" checked={entrega === 'entrega'} onChange={() => setEntrega('entrega')} className="accent-magenta" />Entrega no meu endereço</label>
          {entrega === 'entrega' && (
            <input inputMode="numeric" value={cep} onChange={(e) => setCep(e.target.value.replace(/\D/g, '').slice(0, 8).replace(/^(\d{5})(\d)/, '$1-$2'))}
              placeholder="CEP" aria-label="CEP" className="h-11 w-48 rounded-lg border border-black/15 px-3" />
          )}
          {entrega === 'entrega' && calc?.frete?.opcoes?.filter((o) => o.tipo !== 'retirada').map((o) => <p key={o.tipo} className="text-sm text-black/70">{o.texto}{o.valor === 0 ? ' · grátis' : ''}</p>)}
        </div>

        <CobrimosBanner />
      </div>

      <aside className="space-y-4">
        <div className="space-y-3 rounded-xl2 bg-white p-5 shadow-sm">
          <h2 className="text-sm font-black uppercase tracking-wide">Seus dados</h2>
          <input required inputMode="tel" autoComplete="tel" value={dados.whatsapp} onChange={(e) => setDados({ ...dados, whatsapp: mascaraWhatsapp(e.target.value) })} placeholder="WhatsApp com DDD" aria-label="WhatsApp" className="h-11 w-full rounded-lg border border-black/15 px-3" />
          <input required autoComplete="name" value={dados.nome} onChange={(e) => setDados({ ...dados, nome: e.target.value })} placeholder="Nome completo" aria-label="Nome completo" className="h-11 w-full rounded-lg border border-black/15 px-3" />
          <input type="email" autoComplete="email" value={dados.email} onChange={(e) => setDados({ ...dados, email: e.target.value })} placeholder="E-mail (para a nota fiscal)" aria-label="E-mail" className="h-11 w-full rounded-lg border border-black/15 px-3" />
          <input inputMode="numeric" value={dados.documento} onChange={(e) => setDados({ ...dados, documento: e.target.value })} placeholder="CPF ou CNPJ (para a nota fiscal)" aria-label="CPF ou CNPJ" className="h-11 w-full rounded-lg border border-black/15 px-3" />
        </div>
        <div className="space-y-2 rounded-xl2 bg-tinta p-5 text-white">
          <div className="flex justify-between text-sm"><span>Produtos</span><span>{calc ? brl(Number(calc.subtotal)) : '...'}</span></div>
          <div className="flex justify-between text-sm"><span>Arte</span><span>{calc ? (Number(calc.arte.valor) ? brl(Number(calc.arte.valor)) : 'grátis') : '...'}</span></div>
          <div className="flex justify-between text-sm"><span>Entrega</span><span>{entrega === 'retirada' ? 'retirada grátis' : calc?.frete?.frete_gratis ? 'grátis' : 'a combinar'}</span></div>
          <div className="flex items-end justify-between border-t border-white/15 pt-3"><span className="text-sm">Total no Pix</span><span className="text-3xl font-black">{calc ? brl(Number(calc.total)) : '...'}</span></div>
          {calc && <p className="text-right text-xs text-white/70">ou 2x de {brl(Number(calc.pagamento.parcela_sem_juros))} sem juros no cartão</p>}
          {calc?.prazo && <p className="text-xs text-white/80">Fica pronto <b>{calc.prazo.data_pronto_texto}</b> se pagar e liberar a arte até 10h30 de hoje (dia útil).</p>}
          {erro && <p role="alert" className="rounded-lg bg-magenta/20 p-2 text-sm">{erro}</p>}
          <button disabled={enviando || !calc} data-evento="InitiateCheckout" className="flex h-12 w-full items-center justify-center gap-2 rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro disabled:opacity-60">
            {enviando ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Lock className="h-4 w-4" aria-hidden />}Ir para o pagamento
          </button>
          <p className="text-center text-[11px] text-white/60">Pagamento seguro pelo Mercado Pago: Pix na hora, cartão em até 2x sem juros ou até 12x com juros.</p>
        </div>
        <SelosSeguranca escuro={false} />
      </aside>
    </form>
  )
}
