'use client'
import { useEffect } from 'react'
import { rastrear } from '@/lib/meta'

export function ViewContent({ nome, categoria, valor, produtoRef }: { nome: string; categoria: string; valor: number; produtoRef: string }) {
  useEffect(() => {
    void rastrear('ViewContent', { content_name: nome, content_category: categoria, content_ids: [produtoRef], content_type: 'product', value: valor, currency: 'BRL' })
  }, [nome, categoria, valor, produtoRef])
  return null
}
