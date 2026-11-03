import { useState } from 'react'
import { Sheet } from '@/components/ui/sheet'
import { useProfiles } from '@/hooks/queries'
import { tamanhoLegivel, TIPO_ROTULO } from '@/lib/messages'
import type { Message } from '@/lib/types'

const STATUS: Record<string, string> = { sent: 'Enviada', delivered: 'Entregue', read: 'Lida', failed: 'Falhou' }
const completo = (iso: string) => new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'long', timeStyle: 'medium' })

/** "Dados da mensagem": quem enviou, quando, estado, identificadores e detalhes do arquivo. */
export function MessageInfo({ m, onClose }: { m: Message | null; onClose: () => void }) {
  const { data: perfis } = useProfiles()
  const [bruto, setBruto] = useState(false)
  const autor = m?.sent_by ? ((perfis ?? []).find((p: { id: string; name?: string | null }) => p.id === m.sent_by)?.name ?? 'Atendente') : null
  const linhas: [string, string | null | undefined][] = m
    ? [
        ['Tipo', `${TIPO_ROTULO[m.type]}${m.raw_type && m.raw_type !== m.type ? ` (original: ${m.raw_type})` : ''}`],
        ['Sentido', m.direction === 'out' ? 'Enviada por nós' : 'Recebida do cliente'],
        ['Enviada por', m.direction === 'out' ? (autor ?? 'Automação ou sistema') : null],
        ['Data e hora', completo(m.created_at)],
        ['Situação', m.status ? STATUS[m.status] : m.direction === 'in' ? 'Recebida' : null],
        ['Erro', m.error],
        ['Resposta a', m.reply_to_wa_id],
        ['Encaminhada', m.forwarded ? 'Sim' : null],
        ['Arquivo', typeof m.meta?.filename === 'string' ? m.meta.filename : null],
        ['Formato', typeof m.meta?.mime_type === 'string' ? m.meta.mime_type : null],
        ['Tamanho', tamanhoLegivel(m.meta?.tamanho)],
        ['Template', m.template_name],
        ['Apagada no CRM', m.deleted_at ? completo(m.deleted_at) : null],
        ['ID no WhatsApp', m.wa_message_id],
      ]
    : []
  return (
    <Sheet open={!!m} onOpenChange={(o) => !o && onClose()} title="Dados da mensagem" description="O WhatsApp só informa o estado mais recente: enviada, entregue ou lida." className="sm:max-w-md">
      {m && (
        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4 text-sm">
          <dl className="space-y-2">
            {linhas.filter(([, v]) => v).map(([k, v]) => (
              <div key={k}>
                <dt className="text-xs text-muted-foreground">{k}</dt>
                <dd className="break-all font-medium">{v}</dd>
              </div>
            ))}
          </dl>
          <button className="text-xs underline" onClick={() => setBruto((v) => !v)}>{bruto ? 'Ocultar' : 'Ver'} dados técnicos</button>
          {bruto && <pre className="max-h-64 overflow-auto rounded-md bg-secondary p-2 text-[11px]">{JSON.stringify({ meta: m.meta ?? null, raw_type: m.raw_type ?? null }, null, 2)}</pre>}
        </div>
      )}
    </Sheet>
  )
}
