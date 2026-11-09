// Limpeza de JPEG sem decodificar (barato em CPU): remove metadados (EXIF, XMP, IPTC, comentários) e mantém a imagem.
// Usado pela loja-fichas para não estourar o limite de CPU da Edge Function decodificando cada foto.

export interface InfoJpeg { largura: number; altura: number }

/** Remove os segmentos APP1..APP15 e COM. Devolve null se não for um JPEG válido. */
export function limparJpeg(bytes: Uint8Array): { bytes: Uint8Array; info: InfoJpeg | null } | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null
  const partes: Uint8Array[] = [bytes.subarray(0, 2)]
  let info: InfoJpeg | null = null
  let i = 2
  while (i + 4 <= bytes.length) {
    if (bytes[i] !== 0xff) return null
    const marcador = bytes[i + 1]
    if (marcador === 0xda) { partes.push(bytes.subarray(i)); break } // início dos dados da imagem: o resto vai inteiro
    const tam = (bytes[i + 2] << 8) | bytes[i + 3]
    if (tam < 2 || i + 2 + tam > bytes.length) return null
    if (marcador >= 0xc0 && marcador <= 0xcf && marcador !== 0xc4 && marcador !== 0xc8 && marcador !== 0xcc) {
      info = { altura: (bytes[i + 5] << 8) | bytes[i + 6], largura: (bytes[i + 7] << 8) | bytes[i + 8] }
    }
    const descartar = (marcador >= 0xe1 && marcador <= 0xef) || marcador === 0xfe
    if (!descartar) partes.push(bytes.subarray(i, i + 2 + tam))
    i += 2 + tam
  }
  const total = partes.reduce((s, p) => s + p.length, 0)
  const out = new Uint8Array(total)
  let o = 0
  for (const p of partes) { out.set(p, o); o += p.length }
  return { bytes: out, info }
}
