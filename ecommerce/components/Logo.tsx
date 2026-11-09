/** Marca oficial (brandkit): símbolo CMY com sobreposições + nome. */
export function Logo({ claro = true, tamanho = 'md' }: { claro?: boolean; tamanho?: 'md' | 'lg' }) {
  const h = tamanho === 'lg' ? 'h-14 w-14' : 'h-10 w-10'
  return (
    <span className="inline-flex items-center gap-2" aria-label="Sua Gráfica BH">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/marca/simbolo.svg" alt="" className={`${h} shrink-0`} width={44} height={42} />
      <span className={`font-black leading-[0.92] tracking-tight ${tamanho === 'lg' ? 'text-2xl' : 'text-lg'} ${claro ? 'text-white' : 'text-tinta'}`}>
        SUA<br />GRÁFICA<br /><span className="font-semibold">BH®</span>
      </span>
    </span>
  )
}
