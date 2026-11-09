/** Marca: três círculos em ciano, magenta e amarelo (CMY) + nome. Substituir pelo arquivo do brandkit na Fase 5. */
export function Logo({ claro = true }: { claro?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2" aria-label="Sua Gráfica BH">
      <svg viewBox="0 0 64 64" className="h-10 w-10 shrink-0" aria-hidden>
        <circle cx="22" cy="24" r="16" fill="#00a3e0" />
        <circle cx="42" cy="24" r="16" fill="#e6007e" opacity="0.85" />
        <circle cx="32" cy="41" r="16" fill="#ffd400" opacity="0.85" />
      </svg>
      <span className={`text-lg font-black leading-[0.95] tracking-tight ${claro ? 'text-white' : 'text-tinta'}`}>
        SUA<br />GRÁFICA <span className="font-semibold">BH°</span>
      </span>
    </span>
  )
}
