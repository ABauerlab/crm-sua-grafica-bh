'use client'
import { useEffect, useState } from 'react'

const ULTIMO_DIA = '2026-11-30'

/** Faixa da campanha Black Friday (arte grátis até 30/11). Some sozinha depois do último dia (data de Brasília). */
export function FaixaBlackFriday() {
  const [dias, setDias] = useState<number | null>(null)
  useEffect(() => {
    const hoje = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Sao_Paulo' })
    const d = Math.round((Date.parse(ULTIMO_DIA) - Date.parse(hoje)) / 86_400_000) + 1
    setDias(d >= 1 ? d : 0)
  }, [])
  if (!dias) return null
  return (
    <div className="bg-tinta px-4 py-2 text-center text-xs font-bold text-white sm:text-sm" role="note">
      <span className="text-amarelo">BLACK FRIDAY:</span> criação de arte GRÁTIS em qualquer pedido até 30/11
      {dias === 1 ? ' · último dia!' : dias <= 4 ? ` · faltam ${dias} dias` : ''}
    </div>
  )
}
