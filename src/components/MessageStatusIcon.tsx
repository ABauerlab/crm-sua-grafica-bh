import { AlertCircle, Check, CheckCheck } from 'lucide-react'
import type { MessageStatus } from '@/lib/types'

const LABELS: Record<MessageStatus, string> = { sent: 'Enviada', delivered: 'Entregue', read: 'Lida', failed: 'Falha' }

export function MessageStatusIcon({ status, error }: { status: MessageStatus | null; error?: string | null }) {
  if (!status) return null
  const label = LABELS[status]
  const title = status === 'failed' && error ? `${label}: ${error}` : label
  return (
    <span title={title} className="inline-flex items-center gap-0.5" role="img" aria-label={title}>
      {status === 'sent' && <Check className="h-3.5 w-3.5 text-muted-foreground" />}
      {status === 'delivered' && <CheckCheck className="h-3.5 w-3.5 text-muted-foreground" />}
      {status === 'read' && <CheckCheck className="h-3.5 w-3.5 text-sky-600" />}
      {status === 'failed' && <AlertCircle className="h-3.5 w-3.5 text-destructive" />}
    </span>
  )
}
