import Link from 'next/link'
import { FileText, MessageCircle, Search } from 'lucide-react'
import { Logo } from './Logo'
import { MENSAGENS_WHATSAPP, linkWhatsApp, SITE } from '@/lib/site'

// As páginas de categoria entram na Fase 5; por ora o menu leva às âncoras de /categorias
const MENU = [
  ['Cartões de Visita', '/categorias#cartoes-de-visita'],
  ['Panfletos', '/categorias#panfletos-flyers-e-folhetos'],
  ['Adesivos e Etiquetas', '/categorias#adesivos-e-etiquetas'],
  ['Comunicação Visual', '/categorias#comunicacao-visual'],
  ['Embalagens', '/categorias#embalagens'],
  ['Brindes', '/categorias#brindes-personalizados'],
] as const

export function Header() {
  return (
    <header className="sticky top-0 z-40 bg-tinta text-white">
      <div className="hidden border-b border-white/10 text-xs text-white/70 md:block">
        <div className="mx-auto flex max-w-7xl items-center justify-between px-4 py-1.5">
          <span>Produção rápida e entrega em BH · Pix ou até 2x sem juros</span>
          <span className="flex gap-4"><Link href="/ajuda">Dúvidas frequentes</Link><a href={linkWhatsApp(MENSAGENS_WHATSAPP.home)}>Acompanhe seu pedido</a></span>
        </div>
      </div>
      <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3">
        <Link href="/" className="shrink-0" aria-label="Página inicial"><Logo /></Link>
        <form action="/categorias" className="relative hidden flex-1 md:block" role="search">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-black/40" aria-hidden />
          <input name="q" placeholder="O que você quer imprimir hoje?" aria-label="Buscar produto" className="h-11 w-full rounded-lg bg-white pl-9 pr-3 text-sm text-tinta outline-none ring-amarelo focus:ring-2" />
        </form>
        <a href={linkWhatsApp(MENSAGENS_WHATSAPP.home)} target="_blank" rel="noopener" className="ml-auto hidden items-center gap-2 text-xs leading-tight lg:flex">
          <MessageCircle className="h-5 w-5" aria-hidden /><span>Atendimento<br />{SITE.telefone}</span>
        </a>
        <Link href="/ajuda#orcamento" className="ml-auto inline-flex items-center gap-2 rounded-lg bg-amarelo px-3 py-2.5 text-sm font-bold text-tinta hover:bg-amarelo-escuro md:ml-0 md:px-4">
          <FileText className="h-4 w-4" aria-hidden /><span className="hidden sm:inline">Solicitar orçamento</span><span className="sm:hidden">Orçamento</span>
        </Link>
      </div>
      <nav aria-label="Categorias" className="border-t border-white/10">
        <ul className="mx-auto flex max-w-7xl gap-5 overflow-x-auto px-4 py-2 text-sm text-white/85 [scrollbar-width:none]">
          <li className="whitespace-nowrap"><Link href="/categorias" className="font-semibold text-white">Todos os produtos</Link></li>
          {MENU.map(([nome, href]) => <li key={nome} className="whitespace-nowrap"><Link href={href} className="hover:text-amarelo">{nome}</Link></li>)}
        </ul>
      </nav>
    </header>
  )
}
