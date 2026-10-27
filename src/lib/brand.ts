/** Paleta do brand kit para contextos que não aceitam variáveis CSS (gráficos em SVG). Mantida igual a src/index.css. */
export const BRAND = {
  cyan: '#00A6D6',
  magenta: '#E6007E',
  yellow: '#FFD500',
  ink: '#171717',
  blue: '#1F2A86',
  green: '#0E8A3E',
  red: '#E3061E',
  orange: '#FF8A00',
  gray: '#A7A7A7',
} as const

/** Ordem fixa das séries categóricas (validada: contraste e separação para daltonismo; sempre com legenda e rótulos). */
export const SERIES = [BRAND.cyan, BRAND.magenta, BRAND.orange, BRAND.green] as const
