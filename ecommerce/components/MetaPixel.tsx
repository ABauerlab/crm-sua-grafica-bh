'use client'
import { useEffect, useState } from 'react'
import { usePathname, useSearchParams } from 'next/navigation'
import Script from 'next/script'
import { consentimento, rastrear } from '@/lib/meta'

const PIXEL = process.env.NEXT_PUBLIC_META_PIXEL_ID

/** Carrega o Pixel (se configurado e com consentimento), dispara PageView a cada página e Lead nos cliques para o WhatsApp. */
export function MetaPixel() {
  const rota = usePathname()
  const busca = useSearchParams()
  const [ok, setOk] = useState(false)
  useEffect(() => {
    const ler = () => setOk(consentimento() === 'sim')
    ler()
    window.addEventListener('sgbh:consentimento', ler)
    return () => window.removeEventListener('sgbh:consentimento', ler)
  }, [])
  useEffect(() => { if (ok) void rastrear('PageView') }, [ok, rota, busca])
  useEffect(() => {
    if (!ok) return
    const clique = (e: MouseEvent) => {
      const a = (e.target as HTMLElement).closest('a[href*="wa.me"], [data-evento="Lead"]')
      if (a) void rastrear('Lead', { content_name: document.title })
    }
    document.addEventListener('click', clique)
    return () => document.removeEventListener('click', clique)
  }, [ok])
  if (!ok || !PIXEL) return null
  return (
    <Script id="meta-pixel" strategy="afterInteractive">{`
!function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?n.callMethod.apply(n,arguments):n.queue.push(arguments)};
if(!f._fbq)f._fbq=n;n.push=n;n.loaded=!0;n.version='2.0';n.queue=[];t=b.createElement(e);t.async=!0;
t.src=v;s=b.getElementsByTagName(e)[0];s.parentNode.insertBefore(t,s)}(window,document,'script','https://connect.facebook.net/en_US/fbevents.js');
fbq('init','${PIXEL}');`}</Script>
  )
}
