// Agrupa as categorias da vitrine em departamentos para o menu lateral. A primeira regra que casar com o slug vence.
import type { CategoriaResumo } from './vitrine'

export interface Departamento { id: string; nome: string; categorias: CategoriaResumo[] }

const REGRAS: [string, string, RegExp][] = [
  ['cartoes', 'Cartões', /cartao|cartoes/],
  ['panfletos', 'Panfletos e Folhetos', /panfleto|filipeta|folhas-avulsas|folder|postais|marcador|cartaz/],
  ['adesivos', 'Adesivos e Rótulos', /adesivo|rotulo|etiqueta/],
  ['banners', 'Banners e Comunicação Visual', /banner|faixa|lona|backdrop|placa|totem|bandeira|balcoes|letra-caixa|quadro/],
  ['embalagens', 'Embalagens', /sacola|sacos|caixa|embalagem|^tags$/],
  ['festas', 'Restaurantes, Festas e Eventos', /cardapio|delivery|festa|convite|credencia|ingresso|bottons|cordoes/],
  ['papelaria', 'Papelaria e Escritório', /envelope|pasta|bloco|agenda|caderno|timbrado|capas|certificado|calendario|ficha|carimbo|solapas|cd-e-dvd|reguas/],
  ['brindes', 'Brindes', /caneca|copo|garrafa|squeeze|chaveiro|abridor|caneta|celular|tapete|capacho|estojo|acessorios|atacado|foto-produtos/],
  ['vestuario', 'Vestuário', /vestuario|camis|bone|avental/],
]

export function departamentoDe(slug: string) {
  const r = REGRAS.find(([, , re]) => re.test(slug))
  return r ? { id: r[0], nome: r[1] } : { id: 'outros', nome: 'Outros Produtos' }
}

export function agrupar(cats: CategoriaResumo[]): Departamento[] {
  const mapa = new Map<string, Departamento>()
  for (const [id, nome] of REGRAS.map(([i, n]) => [i, n] as const).concat([['outros', 'Outros Produtos']])) mapa.set(id, { id, nome, categorias: [] })
  for (const c of cats) mapa.get(departamentoDe(c.slug).id)!.categorias.push(c)
  return [...mapa.values()].filter((d) => d.categorias.length).map((d) => ({ ...d, categorias: d.categorias.sort((a, b) => b.produtos - a.produtos) }))
}
