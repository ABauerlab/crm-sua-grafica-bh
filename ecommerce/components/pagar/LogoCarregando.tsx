/** Tela de carregamento do checkout: a logo da Sua Gráfica BH (círculos ciano, magenta e amarelo se encontrando) com a mensagem. */
export function LogoCarregando({ mensagem = 'Preparando seu pagamento seguro' }: { mensagem?: string }) {
  return (
    <div role="status" aria-live="polite" className="flex min-h-[70vh] flex-col items-center justify-center gap-6 px-6 text-center">
      <svg viewBox="-70 -70 140 140" className="h-36 w-36" aria-hidden>
        <circle className="logo-c" cx="-13" cy="-10" r="34" fill="#00A6D6" />
        <circle className="logo-m" cx="13" cy="-10" r="34" fill="#E6007E" />
        <circle className="logo-y" cx="0" cy="14" r="34" fill="#FFD500" />
      </svg>
      <div>
        <p className="text-2xl font-black leading-none tracking-tight text-tinta">SUA GRÁFICA <span className="text-magenta">BH</span></p>
        <p className="mt-3 text-sm font-medium text-black/60">{mensagem}</p>
      </div>
      <div className="relative h-1.5 w-48 overflow-hidden rounded-full bg-black/10" aria-hidden>
        <div className="barra-brilho absolute inset-y-0 left-0 w-1/3 rounded-full bg-gradient-to-r from-ciano via-magenta to-amarelo" />
      </div>
    </div>
  )
}
