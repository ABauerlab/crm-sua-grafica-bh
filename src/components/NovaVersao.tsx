import { RefreshCw } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'

const RE = /\/assets\/index-[A-Za-z0-9_-]+\.js/

/** Arquivo principal que esta aba está rodando (null no modo de desenvolvimento). */
const emUso = () => [...document.scripts].map((s) => RE.exec(s.src)?.[0]).find(Boolean) ?? null

async function publicado(): Promise<string | null> {
  try {
    const r = await fetch(`/index.html?v=${Date.now()}`, { cache: 'no-store' })
    if (!r.ok) return null
    return RE.exec(await r.text())?.[0] ?? null
  } catch {
    return null
  }
}

/** Avisa quando há uma versão nova do CRM publicada e deixa atualizar com um clique (abas abertas ficam com a versão antiga). */
export function NovaVersao() {
  const [nova, setNova] = useState(false)
  useEffect(() => {
    const atual = emUso()
    if (!atual) return
    let vivo = true
    const checar = async () => {
      const p = await publicado()
      if (vivo && p && p !== atual) setNova(true)
    }
    const id = setInterval(checar, 5 * 60_000)
    const aoVoltar = () => { if (document.visibilityState === 'visible') void checar() }
    document.addEventListener('visibilitychange', aoVoltar)
    void checar()
    return () => { vivo = false; clearInterval(id); document.removeEventListener('visibilitychange', aoVoltar) }
  }, [])
  if (!nova) return null
  return (
    <div role="status" className="fixed inset-x-3 bottom-20 z-50 mx-auto flex max-w-md items-center justify-between gap-3 rounded-lg border bg-ink px-4 py-3 text-sm text-white shadow-lg md:bottom-4 md:left-auto md:right-4 md:mx-0">
      <span className="font-semibold">Tem uma versão nova do CRM.</span>
      <Button size="sm" variant="secondary" onClick={() => window.location.reload()}><RefreshCw className="h-4 w-4" aria-hidden /> Atualizar agora</Button>
    </div>
  )
}
