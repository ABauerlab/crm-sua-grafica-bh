'use client'
import { useEffect, useState } from 'react'
import Link from 'next/link'
import { Lock, Minus, Plus, Trash2 } from 'lucide-react'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { SelosSeguranca } from '@/components/SelosSeguranca'
import { brl, carrinho, salvarCarrinhoNoServidor, useCarrinho, type Arte } from '@/lib/carrinho'
import { fotoUrl } from '@/lib/vitrine'

interface Calculo {
  ok: boolean; subtotal: number; total: number; arte: { tipo: Arte; valor: number; texto: string }
  pagamento: { parcela_sem_juros: number }; prazo?: { data_pronto_texto: string } | null
  itens: { ref: string; preco: number; unidades: number }[]
}

const ARTES: [Arte, string][] = [['pronta', 'Já tenho a arte pronta (grátis)'], ['conferencia', 'Conferência e ajuste técnico (+ R$ 14,90)'], ['criacao', 'Criação completa da arte (+ R$ 39,90)']]

export function CarrinhoCliente() {
  const { itens } = useCarrinho()
  const [arte, setArte] = useState<Arte>('pronta')
  const [calc, setCalc] = useState<Calculo | null>(null)

  useEffect(() => { setArte(carrinho.arte()) }, [])
  const chave = JSON.stringify([itens.map((i) => [i.ref, i.quantidade]), arte])
  useEffect(() => {
    if (!itens.length) { setCalc(null); return }
    const ctl = new AbortController()
    fetch('/api/v1/quotes/calculate', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ itens: itens.map((i) => ({ ref: i.ref, quantidade: i.quantidade })), arte }),
    }).then((r) => r.json()).then((d: Calculo) => setCalc(d.ok ? d : null)).catch(() => {})
    // carrinho abandonado: grava depois de um instante parado (com os dados que a pessoa já informou, se houver)
    const t = setTimeout(() => salvarCarrinhoNoServidor(itens, carrinho.dados(), { arte, entrega: 'retirada' }), 4000)
    return () => { ctl.abort(); clearTimeout(t) }
  }, [chave]) // eslint-disable-line react-hooks/exhaustive-deps

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
    <div className="mx-auto grid max-w-7xl gap-8 px-4 py-8 lg:grid-cols-[1fr_400px]">
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

        <CobrimosBanner />
      </div>

      <aside className="space-y-4">
        <div className="space-y-2 rounded-xl2 bg-tinta p-5 text-white">
          <div className="flex justify-between text-sm"><span>Produtos</span><span>{calc ? brl(Number(calc.subtotal)) : '...'}</span></div>
          <div className="flex justify-between text-sm"><span>Arte</span><span>{calc ? (Number(calc.arte.valor) ? brl(Number(calc.arte.valor)) : 'grátis') : '...'}</span></div>
          <div className="flex justify-between text-sm"><span>Entrega</span><span className="text-white/70">no próximo passo</span></div>
          <div className="flex items-end justify-between border-t border-white/15 pt-3"><span className="text-sm">Total no Pix</span><span className="text-3xl font-black">{calc ? brl(Number(calc.total)) : '...'}</span></div>
          {calc && <p className="text-right text-xs text-white/70">ou 2x de {brl(Number(calc.pagamento.parcela_sem_juros))} sem juros no cartão</p>}
          {calc?.prazo && <p className="text-xs text-white/80">Fica pronto <b>{calc.prazo.data_pronto_texto}</b> se pagar e liberar a arte até 10h30 de hoje (dia útil).</p>}
          <Link href="/checkout" aria-disabled={!calc} className={`flex h-12 w-full items-center justify-center gap-2 rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro ${calc ? '' : 'pointer-events-none opacity-60'}`}>
            <Lock className="h-4 w-4" aria-hidden />Continuar para a finalização
          </Link>
          <p className="text-center text-[11px] text-white/60">Em 3 passos: seus dados, entrega e pagamento. Pix na hora ou cartão em até 2x sem juros.</p>
        </div>
        <SelosSeguranca escuro={false} />
      </aside>
    </div>
  )
}
