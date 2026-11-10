import Link from 'next/link'
import { Logo } from './Logo'
import { SelosSeguranca } from './SelosSeguranca'
import { SITE } from '@/lib/site'

export function Footer() {
  const e = SITE.endereco
  return (
    <footer className="mt-16 bg-tinta text-white/80">
      <div className="mx-auto grid max-w-[1440px] gap-10 px-4 py-12 md:grid-cols-4">
        <div className="space-y-4">
          <Logo />
          <p className="text-sm">{SITE.descricao}</p>
          <ul className="flex gap-3 text-sm">
            <li><a href={SITE.redes.instagram} target="_blank" rel="noopener" className="hover:text-amarelo">Instagram</a></li>
            <li><a href={SITE.redes.facebook} target="_blank" rel="noopener" className="hover:text-amarelo">Facebook</a></li>
            <li><a href={SITE.redes.threads} target="_blank" rel="noopener" className="hover:text-amarelo">Threads</a></li>
          </ul>
        </div>
        <div className="text-sm">
          <h2 className="mb-3 font-bold text-white">Retirada no balcão</h2>
          <address className="not-italic leading-relaxed">{e.rua}<br />{e.predio}, {e.bairro}<br />{e.cidade} - {e.uf}, CEP {e.cep}</address>
          <p className="mt-2 text-xs text-white/60">{e.aviso}</p>
        </div>
        <div className="text-sm">
          <h2 className="mb-3 font-bold text-white">Atendimento</h2>
          <ul className="space-y-1">{SITE.horarios.map((h) => <li key={h.dias}>{h.dias}: {h.horas}</li>)}</ul>
          <p className="mt-3">WhatsApp {SITE.telefone}<br /><a href={`mailto:${SITE.email}`} className="hover:text-amarelo">{SITE.email}</a></p>
        </div>
        <div className="text-sm">
          <h2 className="mb-3 font-bold text-white">Ajuda</h2>
          <ul className="space-y-1">
            <li><Link href="/ajuda" className="hover:text-amarelo">Central de ajuda</Link></li>
            <li><Link href="/departamentos" className="hover:text-amarelo">Todos os departamentos</Link></li>
            <li><Link href="/categorias" className="hover:text-amarelo">Todos os produtos</Link></li>
            <li><Link href="/blog" className="hover:text-amarelo">Blog</Link></li>
            <li><a href="https://crm.suagraficabh.com.br/privacidade" className="hover:text-amarelo">Privacidade</a></li>
            <li><a href="https://crm.suagraficabh.com.br/termos" className="hover:text-amarelo">Termos de uso</a></li>
          </ul>
        </div>
      </div>
      <div className="border-t border-white/10">
        <div className="mx-auto flex max-w-[1440px] flex-col gap-4 px-4 py-6 md:flex-row md:items-center md:justify-between">
          <SelosSeguranca />
          <p className="text-xs text-white/60">
            © {new Date().getFullYear()} {SITE.nome} · CNPJ {SITE.cnpj} · Desenvolvido por{' '}
            <a href={SITE.credito.url} target="_blank" rel="noopener" className="font-semibold text-white hover:text-amarelo">{SITE.credito.nome}</a>
          </p>
        </div>
      </div>
    </footer>
  )
}
