import { AlertTriangle, Kanban, LogOut, MessageSquare, Users, FileText, UserCog } from 'lucide-react'
import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { Button } from '@/components/ui/button'
import { useQualityAlerts, useRealtimeSync } from '@/hooks/queries'
import { cn } from '@/lib/utils'

const links = [
  { to: '/inbox', label: 'Conversas', icon: MessageSquare },
  { to: '/funil', label: 'Funil', icon: Kanban },
  { to: '/contatos', label: 'Contatos', icon: Users },
  { to: '/templates', label: 'Templates', icon: FileText },
]

export default function Layout() {
  const { profile, signOut } = useAuth()
  useRealtimeSync()
  const { data: alerts } = useQualityAlerts()

  const items = profile?.role === 'admin' ? [...links, { to: '/atendentes', label: 'Atendentes', icon: UserCog }] : links

  return (
    <div className="flex h-full flex-col md:flex-row">
      <nav className="flex shrink-0 items-center justify-between border-b bg-card px-2 py-1 md:w-52 md:flex-col md:items-stretch md:justify-start md:border-b-0 md:border-r md:px-3 md:py-4">
        <div className="hidden px-2 pb-4 md:block">
          <p className="text-sm font-semibold leading-tight">Sua Gráfica BH</p>
          <p className="text-xs text-muted-foreground">Atendimento WhatsApp</p>
        </div>
        <div className="flex flex-1 gap-1 md:flex-col">
          {items.map(({ to, label, icon: Icon }) => (
            <NavLink
              key={to}
              to={to}
              aria-label={label}
              className={({ isActive }) =>
                cn(
                  'flex items-center gap-2 rounded-md px-3 py-2 text-sm text-muted-foreground transition-colors hover:bg-accent',
                  isActive && 'bg-accent font-medium text-accent-foreground',
                )
              }
            >
              <Icon className="h-4 w-4" />
              <span className="hidden sm:inline">{label}</span>
            </NavLink>
          ))}
        </div>
        <div className="flex items-center gap-2 md:flex-col md:items-stretch md:border-t md:pt-3">
          <p className="hidden truncate px-2 text-xs text-muted-foreground md:block">{profile?.name}</p>
          <Button variant="ghost" size="sm" onClick={signOut} className="justify-start">
            <LogOut className="h-4 w-4" />
            <span className="hidden sm:inline">Sair</span>
          </Button>
        </div>
      </nav>
      <main className="flex min-h-0 flex-1 flex-col">
        {alerts?.map((a) => (
          <div
            key={a.title}
            role="alert"
            className={cn(
              'flex items-start gap-2 border-b px-4 py-2 text-sm',
              a.level === 'danger' ? 'bg-rose-50 text-rose-900' : 'bg-amber-50 text-amber-900',
            )}
          >
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <p>
              <strong>{a.title}.</strong> {a.detail}
            </p>
          </div>
        ))}
        <div className="min-h-0 flex-1">
          <Outlet />
        </div>
      </main>
    </div>
  )
}
