import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { useProfiles } from '@/hooks/queries'
import { invokeFunction } from '@/lib/api'

export default function Team() {
  const qc = useQueryClient()
  const { data: profiles } = useProfiles()
  const [form, setForm] = useState({ name: '', email: '', password: '', role: 'agent' })

  const create = useMutation({
    mutationFn: () => invokeFunction('admin-create-agent', form),
    onSuccess: () => {
      setForm({ name: '', email: '', password: '', role: 'agent' })
      qc.invalidateQueries({ queryKey: ['profiles'] })
    },
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    create.mutate()
  }

  const set = (k: keyof typeof form) => (e: { target: { value: string } }) => setForm((f) => ({ ...f, [k]: e.target.value }))

  return (
    <div className="h-full overflow-y-auto p-4">
      <h1 className="text-lg font-semibold">Atendentes</h1>
      <p className="mb-4 text-xs text-muted-foreground">Somente administradores criam acessos. Não existe cadastro público.</p>

      <form onSubmit={onSubmit} className="mb-6 grid max-w-xl gap-3 rounded-lg border bg-card p-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="t-name">Nome</Label>
          <Input id="t-name" required value={form.name} onChange={set('name')} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="t-email">E-mail</Label>
          <Input id="t-email" type="email" required value={form.email} onChange={set('email')} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="t-pass">Senha inicial (mín. 8 caracteres)</Label>
          <Input id="t-pass" type="password" autoComplete="new-password" required minLength={8} value={form.password} onChange={set('password')} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="t-role">Perfil</Label>
          <Select id="t-role" value={form.role} onChange={set('role')}>
            <option value="agent">Atendente</option>
            <option value="admin">Administrador</option>
          </Select>
        </div>
        <div className="sm:col-span-2">
          <Button type="submit" disabled={create.isPending}>
            {create.isPending ? 'Criando…' : 'Criar atendente'}
          </Button>
          {create.isError && <p role="alert" className="mt-2 text-sm text-destructive">{create.error.message}</p>}
          {create.isSuccess && <p className="mt-2 text-sm text-primary">Atendente criado.</p>}
        </div>
      </form>

      <ul className="max-w-xl divide-y rounded-lg border bg-card">
        {profiles?.map((p) => (
          <li key={p.id} className="flex items-center justify-between px-4 py-3 text-sm">
            <span>{p.name}</span>
            <span className="text-xs text-muted-foreground">{p.role === 'admin' ? 'Administrador' : 'Atendente'}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
