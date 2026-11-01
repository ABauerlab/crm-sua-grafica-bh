import * as Dialog from '@radix-ui/react-dialog'
import {
  AlertTriangle,
  BarChart3,
  Bot,
  Volume2,
  VolumeX,
  Bell,
  ChevronsLeft,
  ClipboardList,
  Palette,
  ChevronsRight,
  CreditCard,
  FileText,
  KanbanSquare,
  ListChecks,
  LogOut,
  Megaphone,
  Menu as MenuIcon,
  MessageSquare,
  Package,
  Search,
  Settings,
  Users,
  type LucideIcon,
} from 'lucide-react'
import { useEffect, useState, type FormEvent } from 'react'
import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { Logo, LogoMark } from '@/components/brand/Logo'
import { Menu, MenuContent, MenuItem, MenuLabel, MenuSeparator, MenuTrigger } from '@/components/ui/menu'
import { useAlertasPendentes, useMarcarLidos } from '@/hooks/alertas'
import { useConversations, useQualityAlerts, useRealtimeSync } from '@/hooks/queries'
import { atualizarSelo } from '@/lib/push'
import { DEFAULTS, useSaveSetting, useSetting } from '@/hooks/settings'
import { setSoundEnabled, soundEnabled } from '@/lib/notify'
import { useToast } from '@/components/ui/toast'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'
import { useQuery } from '@tanstack/react-query'

const NAV: { to: string; label: string; icon: LucideIcon }[] = [
  { to: '/painel', label: 'Painel', icon: BarChart3 },
  { to: '/kanban', label: 'Kanban', icon: KanbanSquare },
  { to: '/pedidos', label: 'Pedidos', icon: ClipboardList },
  { to: '/arte', label: 'Fila da arte', icon: Palette },
  { to: '/inbox', label: 'Conversas', icon: MessageSquare },
  { to: '/templates', label: 'Templates', icon: FileText },
  { to: '/contatos', label: 'Contatos', icon: Users },
  { to: '/catalogo', label: 'Catálogo e Kits', icon: Package },
  { to: '/campanhas', label: 'Campanhas', icon: Megaphone },
  { to: '/pagamentos', label: 'Pagamentos', icon: CreditCard },
  { to: '/tarefas', label: 'Tarefas', icon: ListChecks },
  { to: '/configuracoes', label: 'Configurações', icon: Settings },
]

function NavList({ collapsed, onNavigate }: { collapsed: boolean; onNavigate?: () => void }) {
  return (
    <nav aria-label="Principal" className="flex flex-1 flex-col gap-0.5 px-2">
      {NAV.map(({ to, label, icon: Icon }) => (
        <NavLink
          key={to}
          to={to}
          title={collapsed ? label : undefined}
          onClick={onNavigate}
          className={({ isActive }) =>
            cn(
              'relative flex min-h-11 items-center gap-3 rounded-md px-3 text-sm font-medium text-sidebar-foreground/75 transition-colors hover:bg-white/10 hover:text-white md:min-h-10',
              collapsed && 'justify-center px-0',
              isActive && 'bg-white/10 text-white before:absolute before:inset-y-2 before:left-0 before:w-[3px] before:rounded-r before:bg-brand-cyan',
            )
          }
        >
          <Icon className="h-[18px] w-[18px] shrink-0" aria-hidden />
          <span className={cn(collapsed && 'sr-only')}>{label}</span>
        </NavLink>
      ))}
    </nav>
  )
}

function useWhatsAppStatus() {
  return useQuery({
    queryKey: ['wa-status'],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('messages').select('created_at').order('created_at', { ascending: false }).limit(1)
      if (error) throw error
      return (data?.[0]?.created_at as string | undefined) ?? null
    },
  })
}

function timeAgo(iso: string): string {
  const mins = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000))
  if (mins < 1) return 'agora'
  if (mins < 60) return `${mins} min`
  if (mins < 48 * 60) return `${Math.round(mins / 60)} h`
  return `${Math.round(mins / 1440)} d`
}

/** Estado global do agente de IA com botão para pausar todo o atendimento automático. */
function AgentSwitch() {
  const toast = useToast()
  const { data } = useSetting('agent')
  const save = useSaveSetting('agent')
  const agent = data ?? DEFAULTS.agent
  const on = agent.enabled

  function toggle() {
    if (on && !window.confirm('Pausar a IA em todas as conversas? Ninguém será respondido automaticamente até você ligar de novo.')) return
    save.mutate(
      { ...agent, enabled: !on },
      {
        onSuccess: () => {
          void supabase.from('agent_logs').insert({ actor: 'humano', action: on ? 'pausou_ia' : 'ligou_ia', detail: {}, result: 'ok' })
          toast('ok', on ? 'IA pausada em todas as conversas.' : 'IA ligada.')
        },
        onError: (e) => toast('error', e.message),
      },
    )
  }

  return (
    <button
      onClick={toggle}
      disabled={save.isPending}
      aria-pressed={on}
      title={on ? 'A IA está atendendo. Clique para pausar tudo.' : 'A IA está pausada. Clique para ligar.'}
      className={cn(
        'flex min-h-11 items-center gap-2 rounded-md border px-2.5 text-xs font-bold md:min-h-9',
        on ? 'border-brand-blue bg-brand-blue text-white' : 'border-brand-yellow bg-brand-yellow/30 text-ink',
      )}
    >
      <Bot className="h-4 w-4" aria-hidden />
      <span className="hidden sm:inline">{on ? 'IA ligada · Pausar IA' : 'IA pausada · Ligar IA'}</span>
      <span className="sm:hidden">{on ? 'IA' : 'Pausada'}</span>
    </button>
  )
}

function Topbar({ onMenu }: { onMenu: () => void }) {
  const { session, signOut } = useAuth()
  const navigate = useNavigate()
  const { data: convs } = useConversations()
  const { data: lastMsg, isError } = useWhatsAppStatus()
  const [q, setQ] = useState('')
  const [sound, setSound] = useState(soundEnabled)
  const unread = (convs ?? []).reduce((n, c) => n + c.unread_count, 0)
  const recent = lastMsg && Date.now() - new Date(lastMsg).getTime() < 24 * 3_600_000

  function onSearch(e: FormEvent) {
    e.preventDefault()
    const t = q.trim()
    if (t) navigate(`/kanban?q=${encodeURIComponent(t)}`)
  }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        document.querySelector<HTMLInputElement>('input[aria-label="Busca global"]')?.focus()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  useEffect(() => {
    document.title = unread > 0 ? `(${unread}) Sua Gráfica BH | CRM` : 'Sua Gráfica BH | CRM'
  }, [unread])

  return (
    <header className="flex h-14 shrink-0 items-center gap-2 border-b bg-background px-3">
      <button onClick={onMenu} aria-label="Abrir menu" className="flex h-11 w-11 items-center justify-center rounded-md hover:bg-secondary md:hidden">
        <MenuIcon className="h-5 w-5" />
      </button>
      <form onSubmit={onSearch} role="search" className="relative min-w-0 flex-1 md:max-w-md">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
        <input
          type="search"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Buscar pedido, cliente ou produto (Ctrl+K)"
          aria-label="Busca global"
          className="h-10 w-full rounded-md border border-input bg-secondary/60 pl-9 pr-3 text-base placeholder:text-muted-foreground md:text-sm"
        />
      </form>
      <div className="ml-auto flex items-center gap-1">
        <AgentSwitch />
        <span
          className="hidden items-center gap-2 rounded-md border px-2.5 py-1.5 text-xs font-medium sm:flex"
          title={lastMsg ? `Última mensagem há ${timeAgo(lastMsg)}` : 'Nenhuma mensagem ainda'}
        >
          <span className={cn('h-2 w-2 rounded-full', isError ? 'bg-brand-red' : recent ? 'bg-brand-green' : 'bg-brand-yellow')} aria-hidden />
          WhatsApp {isError ? 'sem conexão' : recent ? 'ativo' : lastMsg ? `parado há ${timeAgo(lastMsg)}` : 'sem mensagens'}
        </span>
        <Link to="/inbox" aria-label={unread ? `${unread} mensagens não lidas` : 'Notificações'} className="relative flex h-11 w-11 items-center justify-center rounded-md hover:bg-secondary md:h-10 md:w-10">
          <Bell className="h-5 w-5" />
          {unread > 0 && (
            <span className="absolute right-1 top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-brand-magenta px-1 text-[10px] font-bold text-white tabular">
              {unread > 99 ? '99+' : unread}
            </span>
          )}
        </Link>
        <Menu>
          <MenuTrigger aria-label="Menu da conta" className="flex h-11 w-11 items-center justify-center rounded-full bg-ink text-sm font-black text-white md:h-10 md:w-10">
            {(session?.user.email ?? 'U').slice(0, 1).toUpperCase()}
          </MenuTrigger>
          <MenuContent align="end">
            <MenuLabel className="px-2.5 py-1.5 text-xs text-muted-foreground">{session?.user.email}</MenuLabel>
            <MenuSeparator />
            <MenuItem onSelect={() => navigate('/configuracoes')}>
              <Settings className="h-4 w-4" /> Configurações
            </MenuItem>
            <MenuItem
              onSelect={(e) => {
                e.preventDefault()
                setSound((v) => {
                  setSoundEnabled(!v)
                  return !v
                })
              }}
            >
              {sound ? <Volume2 className="h-4 w-4" /> : <VolumeX className="h-4 w-4" />} Som de mensagem: {sound ? 'ligado' : 'desligado'}
            </MenuItem>
            <MenuItem onSelect={signOut}>
              <LogOut className="h-4 w-4" /> Sair
            </MenuItem>
          </MenuContent>
        </Menu>
      </div>
    </header>
  )
}

export default function Layout() {
  useRealtimeSync()
  const { data: alerts } = useQualityAlerts()
  const location = useLocation()
  const navigate = useNavigate()
  const { data: pendentes } = useAlertasPendentes()
  const marcarLidos = useMarcarLidos()

  // selo com o número de pendências no ícone do app (iPhone 16.4 ou superior, app instalado)
  useEffect(() => { atualizarSelo(pendentes ?? 0) }, [pendentes])

  // toque na notificação com o app já aberto: o service worker pede para abrir o pedido ou a conversa (sem recarregar)
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return
    const ouvir = (e: MessageEvent) => {
      const d = e.data as { tipo?: string; url?: string } | undefined
      if (d?.tipo === 'abrir' && typeof d.url === 'string' && d.url.startsWith('/')) navigate(d.url)
    }
    navigator.serviceWorker.addEventListener('message', ouvir)
    return () => navigator.serviceWorker.removeEventListener('message', ouvir)
  }, [navigate])

  // abrir o pedido ou a conversa de um aviso marca o aviso como lido
  useEffect(() => {
    const alvo = location.pathname + location.search
    if (/^\/kanban\?pedido=|^\/inbox\/[0-9a-f-]{36}/.test(alvo)) {
      void supabase.from('alertas').update({ lido_em: new Date().toISOString() }).is('lido_em', null).like('dados->>url', `%${alvo}`).then(() => marcarLidos.reset())
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.pathname, location.search])
  const [collapsed, setCollapsed] = useState(() => {
    try {
      return localStorage.getItem('sgbh.nav.collapsed') === '1'
    } catch {
      return false
    }
  })
  const [mobileOpen, setMobileOpen] = useState(false)

  useEffect(() => {
    try {
      localStorage.setItem('sgbh.nav.collapsed', collapsed ? '1' : '0')
    } catch {
      /* ignora */
    }
  }, [collapsed])

  return (
    <div className="flex h-full">
      <aside className={cn('hidden shrink-0 flex-col bg-sidebar py-4 text-sidebar-foreground transition-[width] duration-200 md:flex', collapsed ? 'w-16' : 'w-60')}>
        <div className={cn('mb-5 flex h-8 items-center px-4', collapsed && 'justify-center px-0')}>
          {collapsed ? <LogoMark className="h-7" /> : <Logo onDark />}
        </div>
        <NavList collapsed={collapsed} />
        <button
          onClick={() => setCollapsed((c) => !c)}
          aria-label={collapsed ? 'Expandir menu' : 'Recolher menu'}
          className="mx-2 mt-2 flex h-10 items-center justify-center gap-2 rounded-md text-xs font-medium text-sidebar-foreground/70 hover:bg-white/10 hover:text-white"
        >
          {collapsed ? <ChevronsRight className="h-4 w-4" /> : <><ChevronsLeft className="h-4 w-4" /> Recolher</>}
        </button>
      </aside>

      <Dialog.Root open={mobileOpen} onOpenChange={setMobileOpen}>
        <Dialog.Portal>
          <Dialog.Overlay className="fixed inset-0 z-40 bg-ink/50 md:hidden" />
          <Dialog.Content className="fixed inset-y-0 left-0 z-50 flex w-72 flex-col bg-sidebar py-4 text-sidebar-foreground outline-none md:hidden" aria-describedby={undefined}>
            <Dialog.Title className="sr-only">Menu</Dialog.Title>
            <div className="mb-5 px-4">
              <Logo onDark />
            </div>
            <NavList collapsed={false} onNavigate={() => setMobileOpen(false)} />
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>

      <div className="flex min-w-0 flex-1 flex-col">
        <Topbar onMenu={() => setMobileOpen(true)} />
        {alerts?.map((a) => (
          <div
            key={a.title}
            role="alert"
            className={cn('flex items-start gap-2 border-b px-4 py-2 text-sm', a.level === 'danger' ? 'bg-brand-red/10' : 'bg-brand-yellow/25')}
          >
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
            <p>
              <strong>{a.title}.</strong> {a.detail}
            </p>
          </div>
        ))}
        <main key={location.pathname.split('/')[1]} className="min-h-0 flex-1">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
