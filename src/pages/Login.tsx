import { useState, type FormEvent } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { supabase } from '@/lib/supabase'

export default function Login() {
  const { session, loading, noAccess, signOut } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  if (session && !loading && !noAccess) return <Navigate to="/inbox" replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    if (error) setError('E-mail ou senha incorretos.')
    setBusy(false)
  }

  return (
    <div className="flex min-h-full items-center justify-center bg-muted px-4">
      <div className="w-full max-w-sm rounded-lg border bg-card p-6 shadow-sm">
        <h1 className="text-xl font-semibold">Sua Gráfica BH</h1>
        <p className="mb-6 text-sm text-muted-foreground">Entre para acessar o atendimento.</p>

        {noAccess ? (
          <div className="space-y-4">
            <p role="alert" className="rounded-md bg-destructive/10 p-3 text-sm text-destructive">
              Seu usuário não tem acesso a este sistema. Peça a um administrador para cadastrá-lo.
            </p>
            <Button variant="outline" className="w-full" onClick={signOut}>
              Sair
            </Button>
          </div>
        ) : (
          <form onSubmit={onSubmit} className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="email">E-mail</Label>
              <Input id="email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="password">Senha</Label>
              <Input
                id="password"
                type="password"
                autoComplete="current-password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </div>
            {error && (
              <p role="alert" className="text-sm text-destructive">
                {error}
              </p>
            )}
            <Button type="submit" className="w-full" disabled={busy}>
              {busy ? 'Entrando…' : 'Entrar'}
            </Button>
          </form>
        )}
        <p className="mt-6 text-center text-xs text-muted-foreground">
          <Link to="/privacidade" className="underline">Política de Privacidade</Link> ·{' '}
          <Link to="/termos" className="underline">Termos de Uso</Link> ·{' '}
          <Link to="/exclusao-de-dados" className="underline">Exclusão de dados</Link>
        </p>
      </div>
    </div>
  )
}
