import { Eye, EyeOff, Loader2 } from 'lucide-react'
import { useEffect, useState, type FormEvent } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { Logo, LogoMark } from '@/components/brand/Logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { lockSeconds } from '@/lib/lock'
import { setRemember, supabase } from '@/lib/supabase'

const LOCK_KEY = 'sgbh.login.lock'

interface LockState {
  fails: number
  until: number
}

function readLock(): LockState {
  try {
    return JSON.parse(localStorage.getItem(LOCK_KEY) ?? '') as LockState
  } catch {
    return { fails: 0, until: 0 }
  }
}

function writeLock(l: LockState) {
  try {
    localStorage.setItem(LOCK_KEY, JSON.stringify(l))
  } catch {
    /* sem armazenamento: sem bloqueio local, o Supabase ainda limita */
  }
}

export default function Login() {
  const { session, loading, noAccess, signOut } = useAuth()
  const location = useLocation()
  const from = (location.state as { from?: string } | null)?.from ?? '/painel'
  const [mode, setMode] = useState<'login' | 'forgot'>('login')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [show, setShow] = useState(false)
  const [keep, setKeep] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [info, setInfo] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [lock, setLock] = useState<LockState>(readLock)
  const [now, setNow] = useState(Date.now())

  useEffect(() => {
    if (lock.until <= Date.now()) return
    const id = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(id)
  }, [lock.until])

  const waitSeconds = Math.max(0, Math.ceil((lock.until - now) / 1000))

  if (session && !loading && !noAccess) return <Navigate to={from} replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (busy || waitSeconds > 0) return
    setBusy(true)
    setError(null)
    setRemember(keep)
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    if (error) {
      const fails = readLock().fails + 1
      const next = { fails, until: Date.now() + lockSeconds(fails) * 1000 }
      writeLock(next)
      setLock(next)
      setNow(Date.now())
      setError(
        error.status === 429
          ? 'Muitas tentativas. Aguarde alguns minutos e tente de novo.'
          : lockSeconds(fails) > 0
            ? `E-mail ou senha incorretos. Por segurança, aguarde ${lockSeconds(fails)} segundos para tentar de novo.`
            : 'E-mail ou senha incorretos.',
      )
    } else {
      writeLock({ fails: 0, until: 0 })
    }
    setBusy(false)
  }

  async function onForgot(e: FormEvent) {
    e.preventDefault()
    if (busy) return
    setBusy(true)
    setError(null)
    await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/redefinir-senha` })
    // Resposta igual exista o e-mail ou não (não revela quem tem acesso)
    setInfo('Se esse e-mail tiver acesso ao sistema, você vai receber um link para criar uma nova senha.')
    setBusy(false)
  }

  return (
    <div className="grid min-h-full lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
      <aside className="relative hidden overflow-hidden bg-ink p-10 text-white lg:flex lg:flex-col lg:justify-between">
        <Logo onDark />
        <div className="relative z-10">
          <p className="text-xs font-medium uppercase tracking-[0.3em] text-brand-cyan">Impressão que dá forma às suas ideias</p>
          <h2 className="mt-4 font-display text-5xl font-black leading-[1] tracking-tight">Ideias impressas em todo lugar.</h2>
          <p className="mt-4 max-w-sm text-base text-white/70">Atendimento, pedidos e vendas da Sua Gráfica BH em um só lugar.</p>
        </div>
        <LogoMark className="pointer-events-none absolute -right-24 -top-24 h-[28rem] opacity-95" />
      </aside>

      <main className="flex items-center justify-center px-4 py-10">
        <div className="w-full max-w-sm">
          <div className="mb-8 lg:hidden">
            <Logo />
          </div>

          {noAccess ? (
            <div className="space-y-4">
              <h1 className="text-2xl font-black">Sem acesso</h1>
              <p role="alert" className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm">
                Este usuário não tem acesso ao sistema. O CRM é de uso exclusivo do dono da Sua Gráfica BH.
              </p>
              <Button variant="outline" className="w-full" onClick={signOut}>
                Sair
              </Button>
            </div>
          ) : mode === 'login' ? (
            <form onSubmit={onSubmit} className="space-y-5" noValidate>
              <div>
                <h1 className="text-2xl font-black">Entrar</h1>
                <p className="mt-1 text-sm text-muted-foreground">Bem-vindo de volta. Entre para acessar o atendimento e os pedidos.</p>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="email">E-mail</Label>
                <Input id="email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="password">Senha</Label>
                <div className="relative">
                  <Input
                    id="password"
                    type={show ? 'text' : 'password'}
                    autoComplete="current-password"
                    required
                    className="pr-12"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                  />
                  <button
                    type="button"
                    onClick={() => setShow((v) => !v)}
                    aria-label={show ? 'Ocultar senha' : 'Mostrar senha'}
                    aria-pressed={show}
                    className="absolute right-0 top-0 flex h-11 w-11 items-center justify-center text-muted-foreground hover:text-foreground md:h-9 md:w-10"
                  >
                    {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>
              </div>
              <div className="flex items-center justify-between gap-3">
                <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm md:min-h-0">
                  <input type="checkbox" checked={keep} onChange={(e) => setKeep(e.target.checked)} className="h-5 w-5 accent-[var(--brand-blue)] md:h-4 md:w-4" />
                  Continuar conectado
                </label>
                <button
                  type="button"
                  onClick={() => {
                    setMode('forgot')
                    setError(null)
                  }}
                  className="min-h-11 text-sm font-semibold text-link underline md:min-h-0"
                >
                  Esqueci minha senha
                </button>
              </div>
              {error && (
                <p role="alert" className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-foreground">
                  {error}
                </p>
              )}
              <Button type="submit" className="w-full" disabled={busy || waitSeconds > 0}>
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
                {busy ? 'Entrando…' : waitSeconds > 0 ? `Aguarde ${waitSeconds}s` : 'Entrar'}
              </Button>
            </form>
          ) : (
            <form onSubmit={onForgot} className="space-y-5">
              <div>
                <h1 className="text-2xl font-black">Recuperar senha</h1>
                <p className="mt-1 text-sm text-muted-foreground">Informe o e-mail de acesso e enviaremos um link para criar uma nova senha.</p>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="f-email">E-mail</Label>
                <Input id="f-email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
              </div>
              {info && (
                <p role="status" className="rounded-md border border-brand-green/30 bg-brand-green/5 p-3 text-sm">
                  {info}
                </p>
              )}
              <Button type="submit" className="w-full" disabled={busy}>
                {busy ? 'Enviando…' : 'Enviar link'}
              </Button>
              <button
                type="button"
                onClick={() => {
                  setMode('login')
                  setInfo(null)
                }}
                className="w-full min-h-11 text-sm font-semibold text-link underline"
              >
                Voltar para o login
              </button>
            </form>
          )}

          <p className="mt-10 text-center text-xs text-muted-foreground">
            <a href="/privacidade" className="underline">Privacidade</a> · <a href="/termos" className="underline">Termos de Uso</a> ·{' '}
            <a href="/exclusao-de-dados" className="underline">Exclusão de dados</a>
          </p>
        </div>
      </main>
    </div>
  )
}
