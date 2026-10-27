import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

if (!url || !anonKey) {
  throw new Error('Defina VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY no arquivo .env (veja .env.example).')
}

/**
 * "Continuar conectado": a sessão vai para o localStorage (persiste ao fechar o navegador).
 * Sem a opção, vai para o sessionStorage (some ao fechar a aba). A escolha fica registrada na própria
 * área de armazenamento correspondente, para o refresh automático do token gravar no lugar certo.
 */
const REMEMBER_KEY = 'sgbh.remember'

function safe<T>(fn: () => T, fallback: T): T {
  try {
    return fn()
  } catch {
    return fallback
  }
}

function pickStore(): Storage {
  return safe(() => (sessionStorage.getItem(REMEMBER_KEY) === '0' ? sessionStorage : localStorage), localStorage)
}

const authStorage = {
  getItem: (key: string) => safe(() => localStorage.getItem(key) ?? sessionStorage.getItem(key), null),
  setItem: (key: string, value: string) =>
    safe(() => {
      const store = pickStore()
      const other = store === localStorage ? sessionStorage : localStorage
      store.setItem(key, value)
      other.removeItem(key)
    }, undefined),
  removeItem: (key: string) =>
    safe(() => {
      localStorage.removeItem(key)
      sessionStorage.removeItem(key)
    }, undefined),
}

/** Chamar antes de entrar com a senha. */
export function setRemember(remember: boolean) {
  safe(() => {
    if (remember) {
      sessionStorage.removeItem(REMEMBER_KEY)
      localStorage.setItem(REMEMBER_KEY, '1')
    } else {
      localStorage.removeItem(REMEMBER_KEY)
      sessionStorage.setItem(REMEMBER_KEY, '0')
    }
  }, undefined)
}

export function getRemember(): boolean {
  return safe(() => sessionStorage.getItem(REMEMBER_KEY) !== '0', true)
}

export const supabase = createClient(url, anonKey, {
  auth: { storage: authStorage, persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
})
