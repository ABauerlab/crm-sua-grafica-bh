import { useId } from 'react'
import { cn } from '@/lib/utils'

/** Símbolo oficial (três círculos CMY e suas sobreposições). Geometria do brand kit v1.0. */
export function LogoMark({ className }: { className?: string }) {
  const id = useId()
  const c = `${id}-c`
  const m = `${id}-m`
  return (
    <svg viewBox="0 0 335.76 320.75" role="img" aria-label="Sua Gráfica BH" className={cn('h-8 w-auto', className)}>
      <defs>
        <clipPath id={c}>
          <circle cx="112" cy="112" r="100" />
        </clipPath>
        <clipPath id={m}>
          <circle cx="224" cy="112" r="100" />
        </clipPath>
      </defs>
      <circle cx="112" cy="112" r="100" fill="var(--brand-cyan)" />
      <circle cx="224" cy="112" r="100" fill="var(--brand-magenta)" />
      <circle cx="168" cy="208.995" r="100" fill="var(--brand-yellow)" />
      <g clipPath={`url(#${c})`}>
        <circle cx="224" cy="112" r="100" fill="var(--brand-blue)" />
        <circle cx="168" cy="208.995" r="100" fill="var(--brand-green)" />
      </g>
      <g clipPath={`url(#${m})`}>
        <circle cx="168" cy="208.995" r="100" fill="var(--brand-red)" />
      </g>
      <g clipPath={`url(#${c})`}>
        <g clipPath={`url(#${m})`}>
          <circle cx="168" cy="208.995" r="100" fill="var(--brand-ink)" />
        </g>
      </g>
    </svg>
  )
}

/** Versão horizontal: símbolo + nome em Inter Black. `onDark` usa texto branco (fundo escuro). */
export function Logo({ onDark = false, compact = false, className }: { onDark?: boolean; compact?: boolean; className?: string }) {
  return (
    <span className={cn('inline-flex items-center gap-2.5', className)}>
      <LogoMark className="h-8" />
      {!compact && (
        <span className={cn('font-display text-[15px] font-black uppercase leading-none tracking-[-0.01em]', onDark ? 'text-white' : 'text-ink')}>
          Sua Gráfica <span className="text-brand-cyan">BH</span>
        </span>
      )}
    </span>
  )
}
