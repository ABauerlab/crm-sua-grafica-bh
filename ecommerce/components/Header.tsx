import Link from 'next/link'
import { FileText, MessageCircle, Search } from 'lucide-react'
import { Logo } from './Logo'
import { CarrinhoIcone } from './CarrinhoIcone'
import { MENSAGENS_WHATSAPP, linkWhatsApp, SITE } from '@/lib/site'
import { arvore } from '@/lib/vitrine'
import { itensDeBusca } from '@/lib/menu'
import { BotaoDepartamentos } from './BotaoDepartamentos'
import { BuscaHeader } from './BuscaHeader'

const CURTO: Record<string, string> = { papelaria: 'Papelaria', embalagens: 'Embalagens', rotulos: 'Rótulos e Tags', editorial: 'Editorial', visual: 'Comunicação Visual', brindes: 'Brindes', festas: 'Festas e Delivery' }

export async function Header() {
  const todas = await arvore()
  const verticais = todas.filter((v) => v.id !== 'mostruario')
  const mostruario = todas.find((v) => v.id === 'mostruario')?.categorias[0]
  const itens = itensDeBusca(todas)
  return (
    <header className="z-40 bg-tinta text-white md:sticky md:-top-8">
      <div className="hidden border-b border-white/10 text-xs text-white/70 md:block">
        <div className="mx-auto flex h-8 max-w-[1440px] items-center justify-between px-4">
          <span>Produção rápida e entrega em BH · Pix ou até 2x sem juros</span>
          <span className="flex gap-4"><Link href="/blog">Blog</Link><Link href="/ajuda">Dúvidas frequentes</Link><a href={linkWhatsApp(MENSAGENS_WHATSAPP.home)}>Acompanhe seu pedido</a></span>
        </div>
      </div>
      <div className="mx-auto flex max-w-[1440px] items-center gap-3 px-4 py-2">
        <Link href="/" className="shrink-0" aria-label="Página inicial"><Logo /></Link>
        <BuscaHeader itens={itens} placeholder="O que você quer imprimir hoje?" className="hidden flex-1 md:block" />
        <a href={linkWhatsApp(MENSAGENS_WHATSAPP.home)} target="_blank" rel="noopener" className="ml-auto hidden items-center gap-2 text-xs leading-tight lg:flex">
          <MessageCircle className="h-5 w-5" aria-hidden /><span>Atendimento<br />{SITE.telefone}</span>
        </a>
        <div className="ml-auto flex items-center gap-1 lg:ml-0">
          <CarrinhoIcone />
          <Link href="/ajuda#orcamento" className="inline-flex items-center gap-2 rounded-lg bg-amarelo px-3 py-2.5 text-sm font-bold text-tinta hover:bg-amarelo-escuro md:ml-0 md:px-4">
            <FileText className="h-4 w-4" aria-hidden /><span className="hidden sm:inline">Solicitar orçamento</span><span className="sm:hidden">Orçamento</span>
          </Link>
        </div>
      </div>
      <div className="px-4 pb-2 md:hidden"><BuscaHeader itens={itens} placeholder="O que você quer imprimir hoje?" /></div>
      <nav aria-label="Departamentos" className="border-t border-white/10">
        <ul className="relative mx-auto flex max-w-[1440px] items-center gap-0.5 overflow-x-auto px-4 text-sm text-white/85 [scrollbar-width:none] lg:overflow-visible">
          <li className="shrink-0 py-0.5"><BotaoDepartamentos verticais={todas} /></li>
          {verticais.map((v) => (
            <li key={v.id} className="group whitespace-nowrap">
              <Link href={`/categorias?vertical=${v.id}`} className="flex min-h-10 items-center px-2 hover:text-amarelo">{CURTO[v.id] ?? v.nome}</Link>
              <div className="invisible absolute left-4 top-full z-50 w-[min(44rem,90vw)] rounded-b-xl2 bg-white p-4 text-tinta opacity-0 shadow-xl transition group-focus-within:visible group-focus-within:opacity-100 group-hover:visible group-hover:opacity-100 max-lg:hidden">
                <p className="text-sm font-black">{v.nome}</p><p className="mb-3 text-xs text-black/55">{v.descricao}</p>
                <ul className="grid grid-cols-2 gap-x-4 gap-y-0.5 whitespace-normal">
                  {v.categorias.slice(0, 16).map((c) => <li key={c.slug}><Link href={`/categoria/${c.slug}`} className="flex min-h-9 items-center justify-between rounded px-2 text-sm hover:bg-papel hover:text-magenta">{c.nome}<span className="text-xs text-black/40">{c.modelos}</span></Link></li>)}
                </ul>
                <Link href={`/categorias?vertical=${v.id}`} className="mt-3 inline-block text-xs font-bold text-magenta underline">Ver tudo em {CURTO[v.id] ?? v.nome}</Link>
              </div>
            </li>
          ))}
          {mostruario && <li className="whitespace-nowrap"><Link href={`/categoria/${mostruario.slug}`} className="flex min-h-10 items-center rounded px-2 font-semibold text-amarelo">Kit de Mostruário</Link></li>}
          <li className="whitespace-nowrap"><a href={linkWhatsApp('Olá! Quero um projeto sob medida / atendimento consultivo.')} target="_blank" rel="noopener" className="flex min-h-10 items-center px-2 hover:text-amarelo">Projetos sob medida</a></li>
        </ul>
      </nav>
    </header>
  )
}
