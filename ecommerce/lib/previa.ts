// Fase 2: cliente da página /previa/<token>. Chama só /api/v1/previa/* (service role fica no Supabase).

export interface PreviaStatus {
  ok: boolean
  erro?: string
  status?: 'pendente' | 'processando' | 'pronta' | 'erro' | 'aguardando_limite'
  sku?: string
  produto_descricao?: string | null
  produto_foto_path?: string | null
  briefing?: Record<string, string>
  uploads?: string[]
  feedback?: string | null
  resultado_url?: string | null
  erro_detalhe?: string | null
  geracoes?: number
  ajustes?: number
  pode_gerar_de_novo?: boolean
  pode_ajustar?: boolean
  expira_em?: string
  order_id?: string | null
  motivo?: string
}

export async function chamarPrevia<T = PreviaStatus>(corpo: Record<string, unknown>): Promise<{ status: number; dados: T }> {
  try {
    const res = await fetch('/api/v1/previa/dados', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo), cache: 'no-store' })
    return { status: res.status, dados: (await res.json().catch(() => ({ ok: false, erro: 'resposta_invalida' }))) as T }
  } catch {
    return { status: 0, dados: { ok: false, erro: 'sem_conexao' } as T }
  }
}

export async function enviarImagem(token: string, arquivo: File): Promise<{ ok: boolean; path?: string; mensagem?: string }> {
  try {
    const res = await fetch('/api/v1/previa/upload', {
      method: 'POST',
      headers: { 'Content-Type': arquivo.type || 'application/octet-stream', 'x-token': token },
      body: arquivo,
    })
    return await res.json().catch(() => ({ ok: false, mensagem: 'Resposta inválida do servidor.' }))
  } catch {
    return { ok: false, mensagem: 'Sem conexão. Confira a internet e tente de novo.' }
  }
}

export const fotoPublica = (path: string | null | undefined): string | null => {
  if (!path) return null
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL
  return base ? `${base}/storage/v1/object/public/${path}` : null
}
