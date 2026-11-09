import type { Metadata } from 'next'
import { MessageCircle } from 'lucide-react'
import { AjudaCentral } from '@/components/AjudaCentral'
import { AJUDA } from '@/lib/ajuda'
import { SITE, linkWhatsApp, MENSAGENS_WHATSAPP } from '@/lib/site'

export const metadata: Metadata = {
  title: 'Central de ajuda',
  description: 'Tire suas dúvidas sobre arquivos, prazos, entrega e retirada em BH, Pix e cartão, cobertura de orçamento e garantia na Sua Gráfica BH.',
  alternates: { canonical: '/ajuda' },
}

const FAQ = {
  '@context': 'https://schema.org', '@type': 'FAQPage',
  mainEntity: AJUDA.flatMap((c) => c.perguntas.map((x) => ({ '@type': 'Question', name: x.p, acceptedAnswer: { '@type': 'Answer', text: x.r } }))),
}

export default function Ajuda() {
  const e = SITE.endereco
  return (
    <div className="mx-auto max-w-4xl px-4 py-10">
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(FAQ).replace(/</g, '\\u003c') }} />
      <h1 className="text-3xl font-black">Central de ajuda</h1>
      <p className="mt-2 text-black/65">Tudo sobre arquivos, prazos, entrega, pagamento e garantia. Não achou? Fala com a gente no WhatsApp.</p>
      <div className="mt-6"><AjudaCentral /></div>
      <section id="orcamento" className="mt-12 scroll-mt-40 rounded-xl2 bg-tinta p-6 text-white">
        <h2 className="text-xl font-black">Orçamento personalizado</h2>
        <p className="mt-2 text-white/80">Precisa de algo fora do catálogo, uma quantidade diferente ou tem um orçamento menor de outra gráfica? Manda pra gente que respondemos rapidinho.</p>
        <a href={linkWhatsApp(MENSAGENS_WHATSAPP.home)} target="_blank" rel="noopener" className="mt-4 inline-flex items-center gap-2 rounded-lg bg-amarelo px-4 py-2.5 text-sm font-bold text-tinta"><MessageCircle className="h-4 w-4" aria-hidden />WhatsApp {SITE.telefone}</a>
      </section>
      <section className="mt-12 grid gap-6 md:grid-cols-2">
        <div>
          <h2 className="text-xl font-black">Retirada no balcão</h2>
          <address className="mt-2 not-italic text-sm leading-relaxed">{e.rua}<br />{e.predio}, {e.bairro}<br />{e.cidade} - {e.uf}, CEP {e.cep}</address>
          <p className="mt-2 text-xs text-black/60">{e.aviso}</p>
          <ul className="mt-3 text-sm">{SITE.horarios.map((h) => <li key={h.dias}>{h.dias}: {h.horas}</li>)}</ul>
        </div>
        <iframe title="Mapa da Sua Gráfica BH" src={SITE.mapaEmbed} className="h-56 w-full rounded-xl2 border-0" loading="lazy" referrerPolicy="strict-origin-when-cross-origin" />
      </section>
    </div>
  )
}
