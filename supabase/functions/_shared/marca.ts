/** Verificação whitelabel com um modelo pequeno de visão. Sem chave, devolve null (nada é dado como limpo sozinho). */
export async function conferirMarca(jpeg: Uint8Array, chave: string | undefined): Promise<{ limpa: boolean | null; motivo: string }> {
  if (!chave) return { limpa: null, motivo: 'verificação automática indisponível' }
  let bin = ''
  for (let i = 0; i < jpeg.length; i += 0x8000) bin += String.fromCharCode(...jpeg.subarray(i, i + 0x8000))
  const prompt = 'Olhe esta foto de produto gráfico. Responda SOMENTE em JSON: {"marca": true|false, "motivo": "curto"}. ' +
    'marca = true se houver logotipo, marca, nome de empresa, site, telefone ou qualquer texto que identifique quem fez a foto ou vende o produto. ' +
    'Texto genérico de exemplo (como "Seu Nome Aqui") e arte fictícia da peça NÃO contam como marca.'
  try {
    const ctl = new AbortController()
    const t = setTimeout(() => ctl.abort(), 20000)
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-lite:generateContent?key=${chave}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ contents: [{ parts: [{ text: prompt }, { inline_data: { mime_type: 'image/jpeg', data: btoa(bin) } }] }], generationConfig: { responseMimeType: 'application/json', temperature: 0 } }),
    })
    clearTimeout(t)
    if (!res.ok) return { limpa: null, motivo: 'verificação automática falhou' }
    const j = await res.json()
    const out = JSON.parse(j?.candidates?.[0]?.content?.parts?.[0]?.text ?? '{}')
    if (typeof out.marca !== 'boolean') return { limpa: null, motivo: 'resposta da verificação ilegível' }
    return { limpa: !out.marca, motivo: String(out.motivo ?? '').slice(0, 200) }
  } catch {
    return { limpa: null, motivo: 'verificação automática falhou' }
  }
}
