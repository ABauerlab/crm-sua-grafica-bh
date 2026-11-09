'use client'
import { usePathname } from 'next/navigation'
import { MENSAGENS_WHATSAPP, linkWhatsApp } from '@/lib/site'

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
      <svg viewBox="0 0 32 32" className="h-7 w-7" fill="currentColor" aria-hidden>
        <path d="M16.04 3C9.4 3 4 8.38 4 15c0 2.34.68 4.62 1.96 6.58L4 29l7.62-1.94A12.06 12.06 0 0 0 16.04 27C22.68 27 28 21.62 28 15S22.68 3 16.04 3Zm0 21.8c-1.86 0-3.68-.5-5.28-1.46l-.38-.22-4.52 1.16 1.2-4.4-.24-.4A9.7 9.7 0 0 1 6.3 15c0-5.38 4.38-9.76 9.74-9.76 5.38 0 9.74 4.38 9.74 9.76s-4.36 9.8-9.74 9.8Zm5.34-7.3c-.3-.14-1.74-.86-2-.96-.28-.1-.48-.14-.68.14-.2.3-.78.96-.96 1.16-.18.2-.36.22-.66.08-.3-.14-1.24-.46-2.36-1.46-.88-.78-1.46-1.74-1.64-2.04-.18-.3-.02-.46.12-.6.14-.14.3-.36.44-.54.14-.18.2-.3.3-.5.1-.2.04-.38-.02-.52-.08-.14-.68-1.64-.94-2.24-.24-.58-.5-.5-.68-.5h-.58c-.2 0-.52.08-.8.38-.28.3-1.04 1.02-1.04 2.48 0 1.46 1.06 2.88 1.22 3.08.14.2 2.1 3.2 5.08 4.48.7.3 1.26.48 1.7.62.72.22 1.36.2 1.88.12.58-.08 1.74-.72 2-1.4.24-.7.24-1.28.16-1.4-.06-.12-.26-.2-.56-.34Z" />
      </svg>
    </a>
  )
}
