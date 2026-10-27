import { corsHeaders, json, requireStaff, serviceClient } from '../_shared/http.ts'

// Cadastro público está desativado: somente um admin cria atendentes.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  const staff = await requireStaff(req, db)
  if (!staff || staff.role !== 'admin') return json({ error: 'Apenas administradores podem criar atendentes.' }, 403)

  let input: { email?: string; password?: string; name?: string; role?: string }
  try {
    input = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }

  const email = input.email?.trim().toLowerCase()
  const name = input.name?.trim()
  const role = input.role === 'admin' ? 'admin' : 'agent'
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'E-mail inválido.' }, 400)
  if (!name) return json({ error: 'Informe o nome.' }, 400)
  if (!input.password || input.password.length < 8) return json({ error: 'A senha precisa ter ao menos 8 caracteres.' }, 400)

  const { data, error } = await db.auth.admin.createUser({ email, password: input.password, email_confirm: true })
  if (error || !data.user) return json({ error: `Não foi possível criar o usuário: ${error?.message ?? 'erro'}` }, 400)

  const { error: profErr } = await db.from('profiles').insert({ id: data.user.id, name, role })
  if (profErr) {
    await db.auth.admin.deleteUser(data.user.id)
    return json({ error: 'Falha ao criar o perfil do atendente.' }, 500)
  }

  return json({ ok: true, id: data.user.id })
})
