import type { Metadata } from 'next'
import { SITE, linkWhatsApp, MENSAGENS_WHATSAPP } from '@/lib/site'

export const metadata: Metadata = { title: 'Central de ajuda', description: 'Retirada, horários, pagamento e orçamento na Sua Gráfica BH.', alternates: { canonical: '/ajuda' } }

// Versão inicial; a central completa (6 categorias com busca) entra na Fase 8.
export default function Ajuda() {
  return (
    <section className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-3xl font-black">Central de ajuda</h1>
      <div className="mt-6 space-y-6 rounded-xl2 bg-white p-6 text-sm shadow-sm">
        <div><h2 className="text-lg font-bold">Retirada no balcão</h2><p className="mt-1">{SITE.endereco.aviso}</p><p className="mt-1">{SITE.endereco.rua}, {SITE.endereco.predio}, {SITE.endereco.bairro}, {SITE.endereco.cidade} - {SITE.endereco.uf}, CEP {SITE.endereco.cep}.</p></div>
        <div><h2 className="text-lg font-bold">Horários</h2><ul className="mt-1">{SITE.horarios.map((h) => <li key={h.dias}>{h.dias}: {h.horas}</li>)}</ul></div>
        <div><h2 className="text-lg font-bold">Pagamento</h2><p className="mt-1">Pix com liberação imediata ou cartão de crédito em até 2x sem juros, sempre pelo Mercado Pago.</p></div>
        <div id="orcamento"><h2 className="text-lg font-bold">Orçamento personalizado</h2><p className="mt-1">Precisa de algo fora do catálogo ou tem um orçamento menor de outra gráfica? <a className="font-semibold text-magenta underline" href={linkWhatsApp(MENSAGENS_WHATSAPP.home)} target="_blank" rel="noopener">Fale no WhatsApp {SITE.telefone}</a>.</p></div>
      </div>
      <iframe title="Mapa da Sua Gráfica BH" src={SITE.mapaEmbed} className="mt-6 h-56 w-full rounded-xl2 border-0" loading="lazy" referrerPolicy="strict-origin-when-cross-origin" />
    </section>
  )
}
