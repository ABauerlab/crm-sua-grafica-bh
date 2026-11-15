'use client'
import { usePathname } from 'next/navigation'
import { MENSAGENS_WHATSAPP, linkWhatsApp } from '@/lib/site'
import { IconeWhatsApp } from './IconeWhatsApp'

/** Botão flutuante do WhatsApp com mensagem conforme a página (home, produto, checkout). */
export function WhatsAppButton() {
  const rota = usePathname() ?? '/'
  const mensagem = rota.startsWith('/checkout') || rota.startsWith('/carrinho')
    ? MENSAGENS_WHATSAPP.checkout
    : rota.startsWith('/produto/')
      ? MENSAGENS_WHATSAPP.produto(typeof document !== 'undefined' ? document.title.split(' | ')[0] : 'deste produto')
      : MENSAGENS_WHATSAPP.home
  return (
    <a
      href={linkWhatsApp(mensagem)}
      target="_blank"
      rel="noopener"
      aria-label="Falar com a Sua Gráfica BH no WhatsApp"
      data-evento="Lead"
      className="fixed bottom-4 right-4 z-50 flex h-14 w-14 items-center justify-center rounded-full bg-[#25d366] text-white shadow-lg shadow-black/25 transition-transform hover:scale-105 motion-safe:animate-[pulso_2.4s_ease-in-out_infinite] sm:bottom-6 sm:right-6"
    >
      <IconeWhatsApp className="h-7 w-7" />
    </a>
  )
}
