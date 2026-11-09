// E-commerce Fase 2: leitura da ficha técnica da origem e tradução para linguagem de balcão (Node >= 22): npm run test:loja
import assert from 'node:assert/strict'
import { limparJpeg } from '../supabase/functions/_shared/jpeg.ts'
import { cnpjValido, cpfValido, mensagemErro, normalizarWhatsapp, validarPedido } from '../supabase/functions/_shared/loja-validar.ts'
import { citaMarca, espessura, fichaBalcao, lerFicha, limparTitulo, marcasDaOrigem, traduzirAcabamento, traduzirCores } from '../supabase/functions/_shared/ficha-origem.ts'

// marca fictícia: o teste nunca usa o nome real da origem
const marcas = marcasDaOrigem('https://www.fulanografica.com.br')
assert.ok(marcas.includes('fulanografica') && marcas.includes('fulano gráfica') && marcas.includes('fulano'))
assert.equal(citaMarca('Só a Fulano Gráfica entrega rápido.', marcas), true)
assert.equal(citaMarca('Papel firme e bonito.', marcas), false)

const html = `<html><head><title>X | Fulano Gráfica</title><script>var a = 'Descrição técnica';</script></head><body>
<h1>CARTÕES DE VISITA COUCHÊ 300G VERNIZ UV  VERNIZ UV TOTAL FRENTE E VERSO - 4X4 - 1000unid - CFV02</h1>
<h2>Sobre o produto</h2>
<p>Conheça os Mandamentos da Arte da Fulano Gráfica - CLIQUE AQUI!</p>
<b>TIPO DE IMPRESSÃO:</b><span>OFSET</span>
<b>SOBRE O CARTÃO DE VISITA:</b>
<p>O cartão da Fulano Gráfica é produzido com alta qualidade. O cartão couchê 300g é excelente para quem procura requinte. Rapidez só na Fulanografica.</p>
<h3>Descrição técnica</h3>
<dl><dt>Ref.:</dt><dd>CFV02</dd><dt>Papel/Material:</dt><dd>COUCHE BRILHO</dd><dt>Gramatura:</dt><dd>300g</dd><dt>Cores:</dt><dd>4X4</dd>
<dt>Peso:</dt><dd>1392g</dd><dt>Tam. da arte c/ sangria:</dt><dd>91x51mm</dd><dt>Tam. final do material:</dt><dd>88x48mm</dd>
<dt>Acabamento(s) padrão(ões):</dt><dd>VERNIZ TOTAL BRILHO FRENTE E VERSO</dd></dl><button>Comprar</button></body></html>`

const f = lerFicha(html, marcas)
assert.equal(f.titulo, 'Cartões de Visita Couchê 300g Verniz UV Total Frente e Verso')
assert.equal(f.material, 'COUCHE BRILHO')
assert.equal(f.gramatura_g, 300)
assert.equal(f.peso_g, 1392)
assert.equal(f.tamanho_final_mm, '88x48mm')
assert.equal(f.tipo_impressao, 'OFSET')
assert.deepEqual(f.sobre, ['O cartão couchê 300g é excelente para quem procura requinte.'], 'frases com a marca da origem saem')

const b = fichaBalcao(f, marcas)
assert.equal(b.titulo, 'Cartões de Visita Couchê 300g Verniz Brilhante na Frente e no Verso')
assert.equal(b.impressao, 'Colorido Frente e Verso')
assert.equal(b.espessura, 'Papel Extra Firme (300g)')
assert.equal(b.tamanho_final, '88 x 48 mm (8,8 x 4,8 cm)')
assert.equal(b.arte_com_sangria, '91 x 51 mm (9,1 x 5,1 cm)')
assert.equal(b.acabamento, 'Verniz Brilhante na Frente e no Verso')
const saida = JSON.stringify(b)
assert.ok(!citaMarca(saida, marcas), 'a ficha de balcão não cita a origem')
assert.ok(!/CFV02|4X4|ofset/i.test(saida), 'sem SKU, código de cor nem jargão de impressão')

// glossário de balcão pedido pelo dono
assert.equal(traduzirCores('4x0'), 'Colorido Apenas na Frente')
assert.equal(traduzirCores('1X1'), 'Preto e Branco Frente e Verso')
assert.equal(traduzirAcabamento('BOPP BRILHO TOTAL'), 'Película Protetora com Brilho Total')
assert.equal(traduzirAcabamento('FACA ESPECIAL'), 'Corte com Formato Personalizado')
assert.equal(traduzirAcabamento('REFILE'), 'Corte Reto Tradicional')
assert.equal(traduzirAcabamento('4 CANTOS ARREDONDADOS'), 'Bordas Arredondadas Elegantes')
assert.equal(traduzirAcabamento('LAMINAÇÃO FOSCA + VERNIZ LOCALIZADO'), 'Película com Toque Aveludado e Brilho Especial nos Detalhes')
assert.equal(espessura(10, 'ABRIDORES - IMPRESSÃO UV'), null, 'gramatura de brinde não vira "papel fino"')
assert.equal(espessura(250, 'COUCHE FOSCO'), 'Papel Firme (250g)')
assert.equal(limparTitulo('ADESIVOS ADESIVO TERMOCOLANTE COM RELEVO - 4X0 - 1unid - X1'), 'Adesivo Termocolante com Relevo')

// página sem ficha não quebra
assert.equal(lerFicha('<html><body>nada</body></html>', marcas).material, null)

// JPEG: tira EXIF (APP1) e comentário sem decodificar; mantém JFIF, tamanho e dados da imagem
{
  const seg = (m: number, corpo: number[]) => [0xff, m, (corpo.length + 2) >> 8, (corpo.length + 2) & 255, ...corpo]
  const sof = seg(0xc0, [8, 0x01, 0x2c, 0x03, 0xe8, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1]) // 1000 x 300
  const exif = seg(0xe1, [...Buffer.from('Exif\0\0origem-secreta')])
  const com = seg(0xfe, [...Buffer.from('comentario')])
  const jfif = seg(0xe0, [...Buffer.from('JFIF\0'), 1, 1, 0, 0, 1, 0, 1, 0, 0])
  const dados = [0xff, 0xda, 0, 2, 9, 9, 9, 0xff, 0xd9]
  const entrada = new Uint8Array([0xff, 0xd8, ...jfif, ...exif, ...com, ...sof, ...dados])
  const r = limparJpeg(entrada)
  assert.ok(r)
  assert.equal(r.info?.largura, 1000)
  assert.equal(r.info?.altura, 300)
  const txt = Buffer.from(r.bytes).toString('latin1')
  assert.ok(!txt.includes('origem-secreta') && !txt.includes('comentario'), 'metadados removidos')
  assert.ok(txt.includes('JFIF'), 'cabeçalho JFIF mantido')
  assert.equal(r.bytes.length, entrada.length - exif.length - com.length)
  assert.equal(limparJpeg(new Uint8Array([0x89, 0x50, 0x4e, 0x47])), null, 'PNG não é tratado como JPEG')
}

// Checkout do site (Fase 4): validação do pedido
assert.equal(normalizarWhatsapp('(31) 97561-8243'), '5531975618243')
assert.equal(normalizarWhatsapp('+55 31 97561-8243'), '5531975618243')
assert.equal(normalizarWhatsapp('3133334444'), '553133334444')
assert.equal(normalizarWhatsapp('97561-8243'), null, 'sem DDD não vale')
assert.equal(cpfValido('529.982.247-25'), true)
assert.equal(cpfValido('111.111.111-11'), false)
assert.equal(cnpjValido('58.481.181/0001-03'), true, 'CNPJ da Sua Gráfica BH')
assert.equal(cnpjValido('58.481.181/0001-04'), false)
{
  const base = { cliente: { whatsapp: '(31) 97561-8243', nome: 'Maria da Silva', email: 'MARIA@exemplo.com', documento: '529.982.247-25' },
    itens: [{ ref: 'a1b2c3d4e5f6', quantidade: 2 }], opcoes: { arte: 'conferencia', entrega: 'retirada' } }
  const ok = validarPedido(base)
  assert.ok(ok.ok)
  if (ok.ok) {
    assert.equal(ok.pedido.cliente.email, 'maria@exemplo.com')
    assert.equal(ok.pedido.cliente.documento, '52998224725')
    assert.equal(ok.pedido.opcoes.cep, null)
  }
  const ruim = validarPedido({ ...base, cliente: { ...base.cliente, documento: '123' }, itens: [{ ref: 'CFV02', quantidade: 0 }], opcoes: { arte: 'gratis', entrega: 'entrega' } })
  assert.ok(!ruim.ok)
  if (!ruim.ok) {
    for (const m of ['CPF ou CNPJ inválido.', 'Produto inválido no carrinho.', 'Quantidade inválida no carrinho.', 'Escolha uma opção de arte.', 'Informe o CEP para a entrega.']) assert.ok(ruim.erros.includes(m), m)
  }
  assert.equal(mensagemErro('muitas_tentativas').status, 429)
  assert.ok(!/custo|piso|margem|sku|fornecedor/i.test(JSON.stringify(['orcamento_bloqueado', 'produto_nao_encontrado', 'x'].map(mensagemErro))), 'mensagens ao cliente sem dado interno')
}

console.log('OK: ficha técnica da loja (leitura, sigilo da origem e linguagem de balcão)')
