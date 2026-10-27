import { useMemo, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { useTemplates } from '@/hooks/queries'
import { templateVariables } from '@/lib/format'

interface Props {
  sending: boolean
  onSend: (t: { name: string; language: string; variables: string[] }) => void
}

export function TemplatePicker({ sending, onSend }: Props) {
  const { data: templates, isLoading } = useTemplates()
  const approved = useMemo(() => (templates ?? []).filter((t) => t.status === 'APPROVED'), [templates])
  const [key, setKey] = useState('')
  const [values, setValues] = useState<Record<number, string>>({})

  const selected = approved.find((t) => `${t.name}|${t.language}` === key)
  const vars = templateVariables(selected?.body ?? null)
  const preview = selected?.body?.replace(/\{\{(\d+)\}\}/g, (_m, n) => values[Number(n)]?.trim() || `{{${n}}}`)
  const ready = !!selected && vars.every((n) => values[n]?.trim())

  return (
    <div className="space-y-3">
      <div className="space-y-1.5">
        <Label htmlFor="tpl">Template aprovado</Label>
        <Select
          id="tpl"
          value={key}
          onChange={(e) => {
            setKey(e.target.value)
            setValues({})
          }}
        >
          <option value="">{isLoading ? 'Carregando…' : approved.length ? 'Selecione um template' : 'Nenhum template aprovado (sincronize em Templates)'}</option>
          {approved.map((t) => (
            <option key={`${t.name}|${t.language}`} value={`${t.name}|${t.language}`}>
              {t.name} ({t.language})
            </option>
          ))}
        </Select>
      </div>

      {selected && (
        <>
          {vars.length > 0 && (
            <div className="grid gap-2 sm:grid-cols-2">
              {vars.map((n) => (
                <div key={n} className="space-y-1">
                  <Label htmlFor={`var-${n}`}>Variável {`{{${n}}}`}</Label>
                  <Input id={`var-${n}`} value={values[n] ?? ''} onChange={(e) => setValues((v) => ({ ...v, [n]: e.target.value }))} />
                </div>
              ))}
            </div>
          )}
          <p className="whitespace-pre-wrap rounded-md bg-muted p-3 text-sm">{preview}</p>
          <Button
            disabled={!ready || sending}
            onClick={() => onSend({ name: selected.name, language: selected.language, variables: vars.map((n) => values[n].trim()) })}
          >
            {sending ? 'Enviando…' : 'Enviar template'}
          </Button>
        </>
      )}
    </div>
  )
}
