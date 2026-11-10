'use client'
import { useEffect, useState } from 'react'
import Link from 'next/link'
import { ArrowRight, ChevronLeft, ChevronRight } from 'lucide-react'

export interface Slide { titulo: string; texto: string; href: string; botao: string; foto: string | null; fundo: string; destaque: string }

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
    <section aria-roledescription="carrossel" aria-label="Destaques" className={`relative overflow-hidden text-white ${compacto ? 'rounded-xl2' : ''}`} onMouseEnter={() => setPausa(true)} onMouseLeave={() => setPausa(false)}>
      {slides.map((s, n) => (
        <div key={s.titulo} aria-hidden={n !== i} className={`${n === i ? 'relative opacity-100' : 'pointer-events-none absolute inset-0 opacity-0'} transition-opacity duration-500 ${s.fundo}`}>
          <div className={`mx-auto grid max-w-[1440px] items-center gap-6 px-4 md:grid-cols-[1.2fr_1fr] ${compacto ? 'min-h-[12rem] px-5 pb-12 pt-6 md:min-h-[14rem]' : 'min-h-[22rem] pb-16 pt-10 md:min-h-[28rem] md:pb-20 md:pt-14'}`}>
            <div>
              <h2 className={`font-black leading-[1.05] ${compacto ? 'text-xl md:text-3xl' : 'text-3xl md:text-5xl'}`}>{s.titulo}</h2>
              <p className="mt-4 max-w-lg text-base text-white/90 md:text-lg">{s.texto}</p>
              <Link href={s.href} tabIndex={n === i ? 0 : -1} className={`mt-6 inline-flex items-center gap-2 rounded-lg px-5 py-3 font-bold ${s.destaque}`}>{s.botao}<ArrowRight className="h-4 w-4" aria-hidden /></Link>
            </div>
            {s.foto && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={s.foto} alt="" loading={n === 0 ? 'eager' : 'lazy'} className={`mx-auto hidden aspect-square rotate-3 rounded-2xl object-cover shadow-2xl md:block ${compacto ? 'w-36' : 'w-72 lg:w-80'}`} />
            )}
          </div>
        </div>
      ))}
      <div className="absolute inset-x-0 bottom-3 flex items-center justify-center gap-3">
        <button type="button" onClick={() => ir(i - 1)} aria-label="Banner anterior" className="flex h-9 w-9 items-center justify-center rounded-full bg-black/30 hover:bg-black/50"><ChevronLeft className="h-5 w-5" aria-hidden /></button>
        <div className="flex gap-2">{slides.map((s, n) => <button key={s.titulo} type="button" onClick={() => setI(n)} aria-label={`Banner ${n + 1}`} aria-current={n === i} className={`h-2.5 rounded-full transition-all ${n === i ? 'w-6 bg-amarelo' : 'w-2.5 bg-white/50'}`} />)}</div>
        <button type="button" onClick={() => ir(i + 1)} aria-label="Próximo banner" className="flex h-9 w-9 items-center justify-center rounded-full bg-black/30 hover:bg-black/50"><ChevronRight className="h-5 w-5" aria-hidden /></button>
      </div>
    </section>
  )
}
