import { useQuery } from '@tanstack/react-query'
import { Download, FileText, MapPin, User } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Skeleton } from '@/components/ui/skeleton'
import { fetchMedia } from '@/lib/api'
import { tamanhoLegivel } from '@/lib/messages'
import type { Message } from '@/lib/types'

const TIPOS_COM_ARQUIVO = ['image', 'audio', 'document', 'video', 'sticker']

/** Mostra imagem, vídeo, áudio, figurinha ou documento, baixando pelo servidor só quando a mensagem aparece. */
export function MediaView({ message }: { message: Message }) {
  const enabled = !!message.media_id && TIPOS_COM_ARQUIVO.includes(message.type)
  const { data: blob, isLoading, error } = useQuery({
    queryKey: ['media', message.id],
    enabled,
    staleTime: Infinity,
    retry: 0,
    queryFn: () => fetchMedia(message.id),
  })
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    if (!blob) return
    const u = URL.createObjectURL(blob)
    setUrl(u)
    return () => URL.revokeObjectURL(u)
  }, [blob])

  if (!enabled) return null
  if (isLoading) return <Skeleton className="mb-1 h-32 w-48" />
  if (error || !url) return <p className="mb-1 text-xs text-muted-foreground">{error instanceof Error ? error.message : 'Arquivo indisponível.'}</p>
  const nome = typeof message.meta?.filename === 'string' ? message.meta.filename : 'documento'
  if (message.type === 'image') {
    return (
      <a href={url} target="_blank" rel="noreferrer" className="mb-1 block">
        <img src={url} alt="Imagem da conversa" className="max-h-64 rounded-md object-contain" loading="lazy" />
      </a>
    )
  }
  if (message.type === 'sticker') return <img src={url} alt="Figurinha" className="mb-1 h-32 w-32 object-contain" loading="lazy" />
  if (message.type === 'video') return <video src={url} controls preload="metadata" className="mb-1 max-h-64 max-w-full rounded-md" />
  if (message.type === 'audio') return <audio src={url} controls className="mb-1 w-64 max-w-full" />
  const tam = tamanhoLegivel(message.meta?.tamanho)
  return (
    <a href={url} download={nome} className="mb-1 flex items-center gap-2 rounded-md border bg-background/60 px-3 py-2 text-sm font-semibold text-link underline">
      <FileText className="h-4 w-4 shrink-0" aria-hidden /> <span className="min-w-0 break-all">{nome}</span> {tam && <span className="text-xs font-normal text-muted-foreground no-underline">{tam}</span>} <Download className="h-3.5 w-3.5 shrink-0" aria-hidden />
    </a>
  )
}

/** Mensagens de localização chegam como texto com link do mapa. */
export function LocationLink({ body }: { body: string }) {
  const m = /(https:\/\/www\.google\.com\/maps\?q=[-\d.,]+)/.exec(body)
  if (!m) return null
  return (
    <a href={m[1]} target="_blank" rel="noreferrer" className="mb-1 inline-flex items-center gap-1 font-semibold text-link underline">
      <MapPin className="h-4 w-4" aria-hidden /> Abrir no mapa
    </a>
  )
}

/** Cartões de contato compartilhados pelo cliente. */
export function ContactsView({ message }: { message: Message }) {
  const lista = (Array.isArray(message.meta?.contatos) ? message.meta?.contatos : []) as { nome: string; telefones: string[] }[]
  if (!lista.length) return null
  return (
    <ul className="mb-1 space-y-1">
      {lista.map((c, i) => (
        <li key={i} className="flex items-center gap-2 rounded-md border bg-background/60 px-3 py-2 text-sm">
          <User className="h-4 w-4 shrink-0" aria-hidden />
          <span><strong>{c.nome}</strong>{c.telefones?.[0] ? ` · ${c.telefones[0]}` : ''}</span>
        </li>
      ))}
    </ul>
  )
}
