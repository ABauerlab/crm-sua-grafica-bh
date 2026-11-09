'use client'
import { useEffect, useState } from 'react'
import { consentimento, definirConsentimento } from '@/lib/meta'

/** Aviso de cookies (LGPD): o Pixel e a medição de anúncios só ligam depois do "Aceitar". */
export function Consentimento() {
  const [mostrar, setMostrar] = useState(false)
  useEffect(() => { setMostrar(consentimento() === null) }, [])
  if (!mostrar) return null
  const escolher = (v: 'sim' | 'nao') => { definirConsentimento(v); setMostrar(false) }
  return (
    <div role="dialog" aria-label="Cookies" className="fixed inset-x-3 bottom-3 z-50 mx-auto max-w-xl rounded-xl2 bg-tinta p-4 text-sm text-white shadow-2xl sm:bottom-6">
      <p>Usamos cookies para medir nossos anúncios e melhorar a loja. Você pode aceitar ou recusar; a compra funciona igual.{' '}
        <a href="https://crm.suagraficabh.com.br/privacidade" className="underline">Política de privacidade</a>.</p>
      <div className="mt-3 flex gap-2">
        <button onClick={() => escolher('sim')} className="rounded-lg bg-amarelo px-4 py-2 font-bold text-tinta">Aceitar</button>
        <button onClick={() => escolher('nao')} className="rounded-lg border border-white/30 px-4 py-2">Recusar</button>
      </div>
    </div>
  )
}
