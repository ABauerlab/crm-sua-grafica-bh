import { Navigate, Outlet, Route, Routes } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import Layout from '@/components/Layout'
import Contacts from '@/pages/Contacts'
import Funnel from '@/pages/Funnel'
import Inbox from '@/pages/Inbox'
import { DataDeletion, Privacy, Terms } from '@/pages/Legal'
import Login from '@/pages/Login'
import Team from '@/pages/Team'
import Templates from '@/pages/Templates'

function RequireStaff() {
  const { loading, session, profile } = useAuth()
  if (loading) return <p className="p-6 text-sm text-muted-foreground">Carregando…</p>
  if (!session || !profile) return <Navigate to="/login" replace />
  return <Outlet />
}

function RequireAdmin() {
  const { profile } = useAuth()
  return profile?.role === 'admin' ? <Outlet /> : <Navigate to="/inbox" replace />
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route path="/privacidade" element={<Privacy />} />
      <Route path="/termos" element={<Terms />} />
      <Route path="/exclusao-de-dados" element={<DataDeletion />} />
      <Route element={<RequireStaff />}>
        <Route element={<Layout />}>
          <Route path="/inbox/:conversationId?" element={<Inbox />} />
          <Route path="/funil" element={<Funnel />} />
          <Route path="/contatos" element={<Contacts />} />
          <Route path="/templates" element={<Templates />} />
          <Route element={<RequireAdmin />}>
            <Route path="/atendentes" element={<Team />} />
          </Route>
        </Route>
      </Route>
      <Route path="*" element={<Navigate to="/inbox" replace />} />
    </Routes>
  )
}
