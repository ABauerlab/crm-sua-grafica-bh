import { lazy, Suspense } from 'react'
import { Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import Layout from '@/components/Layout'
import { Skeleton } from '@/components/ui/skeleton'
import { DataDeletion, Privacy, Terms } from '@/pages/Legal'
import Login from '@/pages/Login'

const Dashboard = lazy(() => import('@/pages/Dashboard'))
const Kanban = lazy(() => import('@/pages/Kanban'))
const Orders = lazy(() => import('@/pages/Orders'))
const ArteQueue = lazy(() => import('@/pages/ArteQueue'))
const Inbox = lazy(() => import('@/pages/Inbox'))
const Contacts = lazy(() => import('@/pages/Contacts'))
const Templates = lazy(() => import('@/pages/Templates'))
const Settings = lazy(() => import('@/pages/Settings'))
const Team = lazy(() => import('@/pages/Team'))
const ResetPassword = lazy(() => import('@/pages/ResetPassword'))
const Catalog = lazy(() => import('@/pages/Catalog'))
const Campaigns = lazy(() => import('@/pages/Campaigns'))
const Payments = lazy(() => import('@/pages/Payments'))
const Tasks = lazy(() => import('@/pages/Tasks'))
const PaymentThanks = lazy(() => import('@/pages/PaymentThanks'))

function PageFallback() {
  return (
    <div className="space-y-3 p-4" aria-busy="true">
      <Skeleton className="h-8 w-48" />
      <Skeleton className="h-40 w-full" />
    </div>
  )
}

/** Sem sessão válida: manda para o login e guarda a rota para voltar depois de entrar. */
function RequireStaff() {
  const { loading, session, profile, noAccess } = useAuth()
  const location = useLocation()
  if (loading) return <PageFallback />
  if (!session || !profile || noAccess) return <Navigate to="/login" replace state={{ from: location.pathname + location.search }} />
  return <Outlet />
}

function RequireAdmin() {
  const { profile } = useAuth()
  return profile?.role === 'admin' ? <Outlet /> : <Navigate to="/painel" replace />
}

export default function App() {
  return (
    <Suspense fallback={<PageFallback />}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/redefinir-senha" element={<ResetPassword />} />
        <Route path="/privacidade" element={<Privacy />} />
        <Route path="/termos" element={<Terms />} />
        <Route path="/exclusao-de-dados" element={<DataDeletion />} />
        <Route path="/pagamento/obrigado" element={<PaymentThanks />} />
        <Route element={<RequireStaff />}>
          <Route element={<Layout />}>
            <Route path="/painel" element={<Dashboard />} />
            <Route path="/kanban" element={<Kanban />} />
            <Route path="/pedidos" element={<Orders />} />
            <Route path="/arte" element={<ArteQueue />} />
            <Route path="/inbox/:conversationId?" element={<Inbox />} />
            <Route path="/contatos" element={<Contacts />} />
            <Route path="/catalogo" element={<Catalog />} />
            <Route path="/campanhas" element={<Campaigns />} />
            <Route path="/pagamentos" element={<Payments />} />
            <Route path="/tarefas" element={<Tasks />} />
            <Route path="/templates" element={<Templates />} />
            <Route path="/configuracoes" element={<Settings />} />
            <Route path="/funil" element={<Navigate to="/kanban" replace />} />
            <Route element={<RequireAdmin />}>
              <Route path="/atendentes" element={<Team />} />
            </Route>
          </Route>
        </Route>
        <Route path="*" element={<Navigate to="/painel" replace />} />
      </Routes>
    </Suspense>
  )
}
