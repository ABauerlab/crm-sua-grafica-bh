import Link from 'next/link'

export function Paginacao({ base, pagina, total, porPagina, params = {} }: { base: string; pagina: number; total: number; porPagina: number; params?: Record<string, string | undefined> }) {
  const paginas = Math.ceil(total / porPagina)
  if (paginas <= 1) return null
  const href = (n: number) => {
    const q = new URLSearchParams(Object.entries(params).filter(([, v]) => v) as [string, string][])
    if (n > 1) q.set('pagina', String(n))
    const s = q.toString()
    return s ? `${base}?${s}` : base
  }
  return (
    <nav aria-label="Páginas" className="mt-8 flex items-center justify-center gap-3 text-sm">
      {pagina > 1 && <Link href={href(pagina - 1)} className="rounded-lg border border-black/15 bg-white px-4 py-2 font-semibold hover:border-magenta">Anterior</Link>}
      <span className="text-black/60">Página {pagina} de {paginas}</span>
      {pagina < paginas && <Link href={href(pagina + 1)} className="rounded-lg bg-tinta px-4 py-2 font-semibold text-white hover:bg-magenta">Próxima</Link>}
    </nav>
  )
}
