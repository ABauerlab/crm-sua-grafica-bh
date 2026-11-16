'use client'
import { useEffect, useState } from 'react'
import Link from 'next/link'
import { ChevronLeft, ChevronRight } from 'lucide-react'

/** Banner em imagem: versão larga (3:1) e versão de celular (5:4). O texto está na própria imagem, por isso o `alt` repete o que ela diz. */
export interface Slide { alt: string; href: string; desktop: string; celular: string }

/** Hero rotativo: troca a cada 6 s, pausa ao passar o mouse, respeita "reduzir movimento" e tem setas e pontos acessíveis. */
export function HeroSlider({ slides, compacto = false }: { slides: Slide[]; compacto?: boolean }) {
  const [i, setI] = useState(0)
  const [pausa, setPausa] = useState(false)
  useEffect(() => {
    if (pausa || slides.length < 2) return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const t = setInterval(() => setI((x) => (x + 1) % slides.length), 6000)
    return () => clearInterval(t)
  }, [pausa, slides.length])
  const ir = (n: number) => setI((n + slides.length) % slides.length)
  return (
    <section aria-roledescription="carrossel" aria-label="Destaques" className={`relative overflow-hidden bg-tinta ${compacto ? 'rounded-xl2' : ''}`} onMouseEnter={() => setPausa(true)} onMouseLeave={() => setPausa(false)} onFocus={() => setPausa(true)} onBlur={() => setPausa(false)}>
      {slides.map((s, n) => (
        <Link
          key={s.href + n}
          href={s.href}
          aria-hidden={n !== i}
          tabIndex={n === i ? 0 : -1}
          className={`${n === i ? 'relative block opacity-100' : 'pointer-events-none absolute inset-0 block opacity-0'} transition-opacity duration-500`}
        >
          <picture>
            <source media="(max-width: 767px)" srcSet={s.celular} width={1000} height={800} />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={s.desktop} alt={s.alt} width={1920} height={640} loading={n === 0 ? 'eager' : 'lazy'} decoding="async" className="block h-auto w-full" />
          </picture>
        </Link>
      ))}
      <div className="absolute inset-x-0 bottom-3 flex items-center justify-center gap-3">
        <button type="button" onClick={() => ir(i - 1)} aria-label="Banner anterior" className="flex h-9 w-9 items-center justify-center rounded-full bg-black/35 text-white hover:bg-black/55"><ChevronLeft className="h-5 w-5" aria-hidden /></button>
        <div className="flex gap-2">{slides.map((s, n) => <button key={s.href + n} type="button" onClick={() => setI(n)} aria-label={`Banner ${n + 1}`} aria-current={n === i} className={`h-2.5 rounded-full transition-all ${n === i ? 'w-6 bg-white' : 'w-2.5 bg-white/55 hover:bg-white/80'}`} />)}</div>
        <button type="button" onClick={() => ir(i + 1)} aria-label="Próximo banner" className="flex h-9 w-9 items-center justify-center rounded-full bg-black/35 text-white hover:bg-black/55"><ChevronRight className="h-5 w-5" aria-hidden /></button>
      </div>
    </section>
  )
}
