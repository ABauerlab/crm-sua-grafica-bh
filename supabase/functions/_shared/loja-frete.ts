// E-commerce Fase 9: CEP, bairro e cotação do SuperFrete. Funções puras (testadas em Node: npm run test:loja).

export interface EnderecoCep { cep: string; logradouro: string | null; bairro: string | null; cidade: string | null; uf: string | null }
export interface Pacote { peso_kg: number; altura_cm: number; largura_cm: number; comprimento_cm: number }
export interface OpcaoEnvio { servico: 'pac' | 'sedex' | 'mini'; nome: string; valor: number; prazo_dias: number | null }

export const cepLimpo = (v: unknown): string | null => {
  const d = String(v ?? '').replace(/\D/g, '')
  return /^[0-9]{8}$/.test(d) ? d : null
}

/** Resposta do ViaCEP ou da BrasilAPI -> endereço. Null se o CEP não existe. */
export function lerEnderecoCep(cep: string, j: Record<string, unknown> | null): EnderecoCep | null {
  if (!j || j.erro === true || j.erro === 'true') return null
  const s = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, 120) : null)
  const bairro = s(j.bairro) ?? s(j.neighborhood)
  const cidade = s(j.localidade) ?? s(j.city)
  const uf = (s(j.uf) ?? s(j.state))?.toUpperCase().slice(0, 2) ?? null
  if (!cidade && !bairro) return null
  return { cep, logradouro: s(j.logradouro) ?? s(j.street), bairro, cidade, uf }
}

/** Junta os pacotes de cada produto em um só (empilhados): soma peso e altura, usa o maior comprimento e a maior largura. */
export function juntarPacotes(pacotes: Pacote[]): Pacote {
  const p = pacotes.reduce((a, x) => ({
    peso_kg: a.peso_kg + x.peso_kg, altura_cm: a.altura_cm + x.altura_cm,
    largura_cm: Math.max(a.largura_cm, x.largura_cm), comprimento_cm: Math.max(a.comprimento_cm, x.comprimento_cm),
  }), { peso_kg: 0, altura_cm: 0, largura_cm: 0, comprimento_cm: 0 })
  // mínimos aceitos pelas transportadoras
  return { peso_kg: Math.max(p.peso_kg, 0.1), altura_cm: Math.max(p.altura_cm, 2), largura_cm: Math.max(p.largura_cm, 11), comprimento_cm: Math.max(p.comprimento_cm, 16) }
}

export const PESO_MAX_KG = 30
export const SOMA_MAX_CM = 200

/** Cabe nos Correios? (peso até 30 kg, comprimento até 100 cm, soma das três medidas até 200 cm). */
export function pacoteValido(p: Pacote): boolean {
  return p.peso_kg <= PESO_MAX_KG && p.comprimento_cm <= 100 && p.largura_cm <= 100 && p.altura_cm <= 100
    && p.comprimento_cm + p.largura_cm + p.altura_cm <= SOMA_MAX_CM
}

export function corpoSuperFrete(origem: string, destino: string, p: Pacote) {
  return {
    from: { postal_code: origem }, to: { postal_code: destino }, services: '1,2,17',
    options: { own_hand: false, receipt: false, insurance_value: 0, use_insurance_value: false },
    package: { height: Math.ceil(p.altura_cm), width: Math.ceil(p.largura_cm), length: Math.ceil(p.comprimento_cm), weight: Math.round(p.peso_kg * 1000) / 1000 },
  }
}

const SERVICOS: Record<string, OpcaoEnvio['servico']> = { '1': 'pac', '2': 'sedex', '17': 'mini' }
const NOMES = { pac: 'PAC (Correios)', sedex: 'SEDEX (Correios)', mini: 'Mini Envios (Correios)' }

/** Resposta do SuperFrete -> opções válidas, da mais barata para a mais cara. Ignora serviços com erro ou sem preço. */
export function opcoesEnvio(resp: unknown): OpcaoEnvio[] {
  const lista = Array.isArray(resp) ? resp : []
  const out: OpcaoEnvio[] = []
  for (const r of lista as Record<string, any>[]) {
    const servico = SERVICOS[String(r?.id)]
    const valor = Number(r?.price)
    if (!servico || r?.error || !Number.isFinite(valor) || valor <= 0) continue
    const dias = Number(r?.delivery_range?.max ?? r?.delivery_time)
    out.push({ servico, nome: NOMES[servico], valor: Math.round(valor * 100) / 100, prazo_dias: Number.isFinite(dias) && dias > 0 ? Math.trunc(dias) : null })
  }
  return out.sort((a, b) => a.valor - b.valor)
}
