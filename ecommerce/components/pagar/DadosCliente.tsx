'use client'
import { useState } from 'react'
import { Check, Pencil } from 'lucide-react'
import { apenasDigitos, chamar, documentoValido, emailValido, mascaraDocumento, type Checkout } from '@/lib/pagar'

/** Coleta inteligente: só pede o que falta no cadastro. Dados confirmados ficam recolhidos e podem ser editados. */
export function DadosCliente({ token, c, onSalvo }: { token: string; c: Checkout; onSalvo: () => void }) {
  const completo = c.faltando.length === 0
  const [editando, setEditando] = useState(!completo)
  const [nome, setNome] = useState(c.cliente.nome ?? '')
  const [email, setEmail] = useState(c.cliente.email ?? '')
  const [doc, setDoc] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [salvando, setSalvando] = useState(false)
  // o documento salvo nunca volta inteiro para o navegador: só os 3 últimos dígitos
  const docSalvo = c.cliente.tem_documento && doc === ''

  async function salvar(e: React.FormEvent) {
    e.preventDefault()
    setErro(null)
    if (nome.trim().length < 3) return setErro('Informe seu nome completo.')
    if (!emailValido(email)) return setErro('Confira o e-mail.')
    if (docSalvo) return setErro('Digite o CPF ou CNPJ para confirmar a alteração.')
    if (!documentoValido(doc)) return setErro('CPF ou CNPJ inválido. Confira os números.')
    setSalvando(true)
    const r = await chamar('dados', { acao: 'salvar', token, nome, email, documento: apenasDigitos(doc) })
    setSalvando(false)
    if (r.dados.ok) { setEditando(false); onSalvo() } else setErro(String(r.dados.mensagem ?? 'Não foi possível salvar. Tente de novo.'))
  }

  if (!editando && completo) {
    return (
      <section className="flex items-center gap-3 rounded-xl2 bg-white p-4 shadow-sm" aria-label="Seus dados">
        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#0E8A3E] text-white"><Check className="h-5 w-5" aria-hidden /></span>
        <div className="min-w-0 flex-1 text-sm"><p className="truncate font-bold">{c.cliente.nome}</p><p className="truncate text-black/60">{c.cliente.email} · documento final {c.cliente.documento_final}</p></div>
        <button type="button" onClick={() => setEditando(true)} className="inline-flex h-10 items-center gap-1 rounded-lg px-3 text-sm font-semibold text-magenta hover:bg-magenta/10"><Pencil className="h-4 w-4" aria-hidden />Editar</button>
      </section>
    )
  }
  const campo = 'mt-1 h-12 w-full rounded-lg border border-black/20 bg-white px-3 outline-none focus:border-magenta focus:ring-2 focus:ring-magenta/25'
  return (
    <form onSubmit={salvar} className="rounded-xl2 bg-white p-5 shadow-sm" aria-labelledby="dados-t" noValidate>
      <h2 id="dados-t" className="text-lg font-black">Seus dados</h2>
      <p className="mb-3 text-sm text-black/60">Usamos para emitir a nota fiscal e confirmar o pagamento. Seus dados ficam protegidos.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-semibold sm:col-span-2">Nome completo<input className={campo} value={nome} onChange={(e) => setNome(e.target.value)} autoComplete="name" /></label>
        <label className="text-sm font-semibold">E-mail<input className={campo} type="email" inputMode="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" /></label>
        <label className="text-sm font-semibold">CPF ou CNPJ<input className={campo} inputMode="numeric" value={doc} onChange={(e) => setDoc(mascaraDocumento(e.target.value))} placeholder={c.cliente.tem_documento ? `salvo, termina em ${c.cliente.documento_final}` : '000.000.000-00'} autoComplete="off" /></label>
      </div>
      {erro && <p role="alert" className="mt-3 rounded-lg bg-red-50 p-3 text-sm font-semibold text-red-700">{erro}</p>}
      <button type="submit" disabled={salvando} className="mt-4 inline-flex h-12 w-full items-center justify-center rounded-lg bg-tinta px-5 font-bold text-white hover:bg-magenta disabled:opacity-60 sm:w-auto">{salvando ? 'Salvando...' : 'Salvar e liberar o pagamento'}</button>
    </form>
  )
}
