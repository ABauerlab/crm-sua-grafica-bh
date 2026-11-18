import type { Session } from '@supabase/supabase-js'
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { supabase } from '@/lib/supabase'
import type { Profile } from '@/lib/types'

interface AuthState {
  loading: boolean
  session: Session | null
  profile: Profile | null
  /** Autenticado, mas sem linha em profiles: não tem acesso ao sistema. */
  noAccess: boolean
  signOut: () => Promise<void>
}

const ALLOWED_EMAIL = (import.meta.env.VITE_ALLOWED_EMAIL as string | undefined)?.trim().toLowerCase()

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (!data.session) setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      // renovação de token e foco da aba disparam o evento com o mesmo usuário: não troca o objeto à toa (evita re-render e piscada)
      setSession((atual) => (atual && s && atual.user.id === s.user.id && atual.access_token === s.access_token ? atual : s))
      if (!s) {
        setProfile(null)
        setLoading(false)
      }
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  const userId = session?.user.id
  useEffect(() => {
    if (!userId) return
    let cancelled = false
    setLoading(true)
    let tentativa = 0
    const buscar = () => {
      supabase
        .from('profiles')
        .select('*')
        .eq('id', userId)
        .maybeSingle()
        .then(({ data, error }) => {
          if (cancelled) return
          // falha de rede NÃO pode virar "sem acesso" (derrubava o atendente para o login): tenta de novo
          if (error && tentativa < 3) {
            tentativa += 1
            setTimeout(buscar, 800 * tentativa)
            return
          }
          if (!error) setProfile((data as Profile | null) ?? null)
          setLoading(false)
        })
    }
    buscar()
    return () => {
      cancelled = true
    }
  }, [userId])

  const value: AuthState = {
    loading,
    session,
    profile,
    noAccess: !!session && !loading && (!profile || (!!ALLOWED_EMAIL && session.user.email?.toLowerCase() !== ALLOWED_EMAIL)),
    signOut: async () => {
      await supabase.auth.signOut()
      try {
        localStorage.removeItem('sgbh.remember')
        sessionStorage.removeItem('sgbh.remember')
      } catch {
        /* armazenamento indisponível */
      }
    },
  }
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth fora do AuthProvider')
  return ctx
}
