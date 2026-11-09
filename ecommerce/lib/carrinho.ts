'use client'
// Carrinho e dados do cliente no navegador (localStorage). O preço é sempre recalculado no servidor (/api/v1).
import { useEffect, useState } from 'react'

export interface ItemCarrinho { ref: string; quantidade: number; titulo: string; unidades: number | null; preco: number; foto: string | null; slug: string }
export interface ClienteLocal { whatsapp: string; nome: string }
export type Arte = 'pronta' | 'conferencia' | 'criacao'

const CHAVE = 'sgbh:carrinho:v1'
const CHAVE_CLIENTE = 'sgbh:cliente:v1'
const CHAVE_ARTE = 'sgbh:arte:v1'
const EVENTO = 'sgbh:carrinho'

function ler<T>(k: string, padrao: T): T {
  try { const v = localStorage.getItem(k); return v ? (JSON.parse(v) as T) : padrao } catch { return padrao }
}
function gravar(k: string, v: unknown) {
  try { localStorage.setItem(k, JSON.stringify(v)) } catch { /* navegador sem armazenamento: segue sem salvar */ }
  window.dispatchEvent(new Event(EVENTO))
}

export const carrinho = {
  itens: (): ItemCarrinho[] => ler<ItemCarrinho[]>(CHAVE, []),
  adicionar(item: ItemCarrinho) {
    const itens = carrinho.itens()
    const i = itens.findIndex((x) => x.ref === item.ref)
    if (i >= 0) itens[i] = { ...itens[i], quantidade: Math.min(itens[i].quantidade + item.quantidade, 100) }
    else itens.push(item)
    gravar(CHAVE, itens.slice(0, 10))
  },
  alterar(ref: string, quantidade: number) {
    gravar(CHAVE, carrinho.itens().map((x) => (x.ref === ref ? { ...x, quantidade: Math.max(1, Math.min(quantidade, 100)) } : x)))
  },
  remover(ref: string) { gravar(CHAVE, carrinho.itens().filter((x) => x.ref !== ref)) },
  limpar() { gravar(CHAVE, []) },
  cliente: (): ClienteLocal | null => ler<ClienteLocal | null>(CHAVE_CLIENTE, null),
  salvarCliente(c: ClienteLocal) { gravar(CHAVE_CLIENTE, c) },
  arte: (): Arte => ler<Arte>(CHAVE_ARTE, 'pronta'),
  salvarArte(a: Arte) { gravar(CHAVE_ARTE, a) },
}

/** Estado reativo do carrinho (atualiza em todas as abas e componentes). */
export function useCarrinho() {
  const [itens, setItens] = useState<ItemCarrinho[]>([])
  const [cliente, setCliente] = useState<ClienteLocal | null>(null)
  useEffect(() => {
    const atualizar = () => { setItens(carrinho.itens()); setCliente(carrinho.cliente()) }
    atualizar()
    window.addEventListener(EVENTO, atualizar)
    window.addEventListener('storage', atualizar)
    return () => { window.removeEventListener(EVENTO, atualizar); window.removeEventListener('storage', atualizar) }
  }, [])
  return { itens, cliente }
}

export const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })

/** (31) 97561-8243 */
export function mascaraWhatsapp(v: string) {
  const d = v.replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, '').slice(0, 11)
  if (d.length <= 2) return d
  if (d.length <= 6) return `(${d.slice(0, 2)}) ${d.slice(2)}`
  if (d.length <= 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`
  return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`
}
export const whatsappValido = (v: string) => /^[1-9][0-9]9?[0-9]{8}$/.test(v.replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, ''))
