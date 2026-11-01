// Testes locais das fotos de produto (Node >= 22): npm run test:fotos
// Cobrem o parser da listagem, o processamento (peso, tamanho, metadados), os limites e o sigilo da origem.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { Image } from 'imagescript'
import {
  aplicarLimites, escolherCartoes, legendaSugerida, lerCartoes, LIMITES, nomeArquivoNeutro, processarImagem, sha256Hex, slugCategoria, vazaOrigem,
} from '../supabase/functions/_shared/fotos.ts'

const lib = { decode: (d: Uint8Array) => Image.decode(d) }

// parser: só cartões de produto (link do item + imagem de serviço); banner e duplicata ficam de fora
const cartoes = lerCartoes(readFileSync(new URL('./fixtures/listagem.html', import.meta.url), 'utf8'))
assert.equal(cartoes.length, 2)
assert.deepEqual(cartoes.map((c) => c.codigo), ['PVCC1', 'CFV10'])
assert.ok(cartoes.every((c) => !c.imagem.includes('?') && /\/servicos\//.test(c.imagem)))
assert.equal(slugCategoria('BLOCOS, COMANDAS, RECEITUÁRIOS E TALÕES'), 'blocos-comandas-receituarios-e-taloes')
assert.equal(slugCategoria('CARTÕES DE VISITA'), 'cartoes-de-visita')

// escolha: o termo manda; sem combinação, espalha
const muitos = Array.from({ length: 30 }, (_, i) => ({ caminho: `/servico/detalhe/adesivos/modelo-${i}/x/COD${i}`, codigo: `COD${i}`, imagem: `https://c.test/servicos/${String(i).padStart(8, '0')}-0000-0000-0000-000000000000.jpg` }))
assert.equal(escolherCartoes(muitos, 'adesivo', 9).itens.length, 9)
assert.equal(escolherCartoes(muitos, 'adesivo', 99).itens.length, 12, 'teto de candidatas')
const esp = escolherCartoes(muitos, 'zzzz', 3)
assert.equal(esp.exato, false)
assert.ok(new Set(esp.itens.map((i) => i.codigo)).size === 3 && esp.itens[2].codigo !== 'COD2', 'sem combinação espalha as escolhas')
const comb = escolherCartoes([...muitos, { caminho: '/servico/detalhe/adesivos/adesivo-de-piso/bopp/COD99', codigo: 'COD99', imagem: 'https://c.test/servicos/99999999-0000-0000-0000-000000000000.jpg' }], 'adesivo de piso', 2)
assert.equal(comb.exato, true)
assert.equal(comb.itens[0].codigo, 'COD99')

// ruído aleatório: JPEG pesado que precisa ser recomprimido até caber no teto
function ruido(w: number, h: number): Image {
  const img = new Image(w, h)
  let s = 12345
  for (let y = 1; y <= h; y++) for (let x = 1; x <= w; x++) { s = (s * 1103515245 + 12345) & 0x7fffffff; img.setPixelAt(x, y, Image.rgbToColor(s & 255, (s >> 8) & 255, (s >> 16) & 255)) }
  return img
}
function degrade(w: number, h: number): Image {
  const img = new Image(w, h)
  for (let y = 1; y <= h; y++) for (let x = 1; x <= w; x++) img.setPixelAt(x, y, Image.rgbToColor(Math.round((x / w) * 255), Math.round((y / h) * 255), 128))
  return img
}

// grande: reduz a 1000 px no maior lado, mantém proporção, fica até 150 KB
const grande = await degrade(2400, 1600).encodeJPEG(95)
const p1 = await processarImagem(grande, lib)
assert.ok(!('descartada' in p1) && !p1.baixaQualidade)
if (!('descartada' in p1)) {
  assert.equal(Math.max(p1.largura, p1.altura), LIMITES.maiorLadoPx)
  assert.equal(p1.largura, 1000); assert.equal(p1.altura, 667)
  assert.ok(p1.tamanho <= LIMITES.metaBytes, `meta de 150 KB: ${p1.tamanho}`)
  // sem metadados: o JPEG gerado não carrega EXIF nem comentários
  const txt = Buffer.from(p1.bytes).toString('latin1')
  assert.ok(!txt.includes('Exif') && !txt.includes('http') && !txt.includes('Photoshop'))
}
// pequena: descartada
// miniatura (como as de 180 px da origem) vale, vira baixa qualidade e é ampliada; ícone de 48 px é descartado
const mini = await processarImagem(await degrade(180, 152).encodeJPEG(90), lib)
assert.ok(!('descartada' in mini) && mini.baixaQualidade && Math.max(mini.largura, mini.altura) === LIMITES.ampliarAtePx && mini.tamanho <= LIMITES.metaBytes)
const media = await processarImagem(await degrade(500, 400).encodeJPEG(90), lib)
assert.ok(!('descartada' in media) && !media.baixaQualidade && media.largura === 640, 'entre 400 e 640 px amplia sem marcar')
assert.deepEqual(await processarImagem(await degrade(48, 48).encodeJPEG(90), lib), { descartada: 'imagem pequena demais (ícone)' })
// ilegível
assert.deepEqual(await processarImagem(new Uint8Array([1, 2, 3, 4]), lib), { descartada: 'imagem ilegível' })
// muito pesada: ruído 1000x1000 nunca chega a 150 KB, mas a regra é recomprimir; se ainda passar de 300 KB, descarta
const p2 = await processarImagem(await ruido(1000, 1000).encodeJPEG(95), lib)
assert.ok('descartada' in p2 ? /300 KB/.test(p2.descartada) : p2.tamanho <= LIMITES.tetoBytes, 'ou cabe no teto de 300 KB, ou é descartada')
// imagem típica de produto já em 1000 px: continua leve
const p3 = await processarImagem(await degrade(1000, 1000).encodeJPEG(100), lib)
assert.ok(!('descartada' in p3) && p3.tamanho <= LIMITES.metaBytes && p3.largura === 1000)

// nome neutro: só hash
const h = await sha256Hex(new Uint8Array([1, 2, 3]))
assert.match(nomeArquivoNeutro(h), /^[0-9a-f]{2}\/[0-9a-f]{32}\.jpg$/)

// limites
assert.deepEqual(aplicarLimites({ pedidosUltimoMinuto: 0, imagensHoje: 0 }, 9), { ok: true, quantidade: 3 })
assert.deepEqual(aplicarLimites({ pedidosUltimoMinuto: 1, imagensHoje: 0 }, 1), { ok: false, motivo: 'muito_rapido' })
assert.deepEqual(aplicarLimites({ pedidosUltimoMinuto: 0, imagensHoje: 10 }, 1), { ok: false, motivo: 'limite_diario' })
assert.deepEqual(aplicarLimites({ pedidosUltimoMinuto: 0, imagensHoje: 8 }, 3), { ok: true, quantidade: 2 }, 'o dia fecha em 10 imagens')

// legenda: ilustrativa quando é do grupo, nunca cita origem, SKU, preço nem fornecedor
const origem = ['origem-interna.example', 'https://www.origem-interna.example']
for (const g of ['CARTÕES DE VISITA', 'ADESIVOS', 'BLOCOS, COMANDAS, RECEITUÁRIOS E TALÕES']) for (const ap of [true, false]) for (let i = 0; i < 3; i++) {
  const l = legendaSugerida(g, ap, i, 3)
  assert.ok(l.length > 5 && l.length < 200, l)
  assert.ok(!vazaOrigem(l, origem) && !/fornecedor|sku|R\$|custo/i.test(l), l)
  if (ap && i === 0) assert.match(l, /ilustrativa/)
}
assert.equal(vazaOrigem('veja em https://www.origem-interna.example/x', origem), true)
assert.equal(vazaOrigem('https://bucket.obs.la-south-2.myhuaweicloud.com/a.jpg', origem), true)
assert.equal(vazaOrigem('Foto ilustrativa de adesivos.', origem), false)

console.log('OK: fotos de produto (parser, processamento, limites, legenda e sigilo da origem)')
