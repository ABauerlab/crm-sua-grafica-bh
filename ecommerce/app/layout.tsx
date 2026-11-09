import type { Metadata, Viewport } from 'next'
import { Montserrat } from 'next/font/google'
import { Footer } from '@/components/Footer'
import { Header } from '@/components/Header'
import { WhatsAppButton } from '@/components/WhatsAppButton'
import { SITE } from '@/lib/site'
import './globals.css'

const fonte = Montserrat({ subsets: ['latin'], variable: '--fonte', display: 'swap' })

export const metadata: Metadata = {
  metadataBase: new URL(SITE.url),
  title: { default: 'Sua Gráfica BH | Gráfica online em Belo Horizonte', template: '%s | Sua Gráfica BH' },
  description: SITE.descricao,
  openGraph: { type: 'website', locale: 'pt_BR', siteName: SITE.nome, url: SITE.url },
  alternates: { canonical: '/' },
}

export const viewport: Viewport = { themeColor: '#0b0b0f', width: 'device-width', initialScale: 1 }

// Dados estruturados da empresa (SEO local e GEO)
const jsonLd = {
  '@context': 'https://schema.org',
  '@type': 'LocalBusiness',
  name: SITE.nome,
  url: SITE.url,
  telephone: '+55 31 97561-8243',
  email: SITE.email,
  taxID: SITE.cnpj,
  address: { '@type': 'PostalAddress', streetAddress: SITE.endereco.rua, addressLocality: SITE.endereco.cidade, addressRegion: SITE.endereco.uf, postalCode: SITE.endereco.cep, addressCountry: 'BR' },
  openingHoursSpecification: [
    { '@type': 'OpeningHoursSpecification', dayOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday'], opens: '08:00', closes: '17:00' },
    { '@type': 'OpeningHoursSpecification', dayOfWeek: 'Friday', opens: '08:00', closes: '18:30' },
  ],
  sameAs: Object.values(SITE.redes),
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-BR" className={fonte.variable}>
      <body className="font-sans">
        <a href="#conteudo" className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded focus:bg-amarelo focus:px-3 focus:py-2">Pular para o conteúdo</a>
        <Header />
        <main id="conteudo">{children}</main>
        <Footer />
        <WhatsAppButton />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
      </body>
    </html>
  )
}
