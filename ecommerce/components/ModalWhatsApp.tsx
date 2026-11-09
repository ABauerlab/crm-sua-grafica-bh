'use client'
import { useEffect, useRef, useState } from 'react'
import { MessageCircle, X } from 'lucide-react'
import { carrinho, mascaraWhatsapp, whatsappValido } from '@/lib/carrinho'

/** Primeiro passo de compra: pede WhatsApp e nome (identificam o pedido e permitem retomar o carrinho). Sem senha. */
export function ModalWhatsApp({ aberto, onFechar, onConfirmar }: { aberto: boolean; onFechar: () => void; onConfirmar: () => void }) {
  const [whatsapp, setWhatsapp] = useState('')
  const [nome, setNome] = useState('')
  const [erro, setErro] = useState('')
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const c = carrinho.cliente()
    if (c) { setWhatsapp(mascaraWhatsapp(c.whatsapp)); setNome(c.nome) }
    const d = ref.current
    if (!d) return
    if (aberto && !d.open) d.showModal()
    if (!aberto && d.open) d.close()
  }, [aberto])
  function enviar(e: React.FormEvent) {
    e.preventDefault()
    if (!whatsappValido(whatsapp)) return setErro('Informe um WhatsApp válido com DDD.')
    if (nome.trim().length < 3) return setErro('Informe seu nome.')
    carrinho.salvarCliente({ whatsapp: whatsapp.replace(/\D/g, ''), nome: nome.trim() })
    setErro('')
    onConfirmar()
  }
  return (
    <dialog ref={ref} onClose={onFechar} className="w-[min(92vw,420px)] rounded-xl2 p-0 backdrop:bg-black/60">
      <form onSubmit={enviar} className="space-y-4 p-6">
        <div className="flex items-start justify-between gap-4">
          <h2 className="flex items-center gap-2 text-lg font-black"><MessageCircle className="h-5 w-5 text-[#25d366]" aria-hidden />Seu WhatsApp</h2>
          <button type="button" onClick={onFechar} aria-label="Fechar" className="rounded p-1 hover:bg-black/5"><X className="h-5 w-5" /></button>
        </div>
        <p className="text-sm text-black/65">É por lá que enviamos o resumo do pedido, a aprovação da arte e o andamento. Sem cadastro e sem senha.</p>
        <label className="block text-sm font-semibold">WhatsApp com DDD
          <input inputMode="tel" autoComplete="tel" required value={whatsapp} onChange={(e) => setWhatsapp(mascaraWhatsapp(e.target.value))}
            placeholder="(31) 99999-9999" className="mt-1 h-11 w-full rounded-lg border border-black/15 px-3 outline-none ring-magenta focus:ring-2" />
        </label>
        <label className="block text-sm font-semibold">Nome
          <input autoComplete="name" required value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Seu nome completo"
            className="mt-1 h-11 w-full rounded-lg border border-black/15 px-3 outline-none ring-magenta focus:ring-2" />
        </label>
        {erro && <p role="alert" className="text-sm font-semibold text-magenta">{erro}</p>}
        <button className="h-12 w-full rounded-lg bg-amarelo font-bold text-tinta hover:bg-amarelo-escuro">Continuar</button>
      </form>
    </dialog>
  )
}
