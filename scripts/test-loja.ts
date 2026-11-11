// E-commerce Fase 2: leitura da ficha técnica da origem e tradução para linguagem de balcão (Node >= 22): npm run test:loja
import assert from 'node:assert/strict'
import { limparJpeg } from '../supabase/functions/_shared/jpeg.ts'
import { cepLimpo, corpoSuperFrete, juntarPacotes, lerEnderecoCep, opcoesEnvio, pacoteValido } from '../supabase/functions/_shared/loja-frete.ts'
import { corpoPix, lerPix } from '../supabase/functions/_shared/mp-pix.ts'
import { cnpjValido, cpfValido, mensagemErro, normalizarWhatsapp, validarPedido } from '../supabase/functions/_shared/loja-validar.ts'
import { hrefFiltros, lerFiltros, lerOrdem } from '../ecommerce/lib/filtros.ts'
import { acabamentoLegivel, impressaoComCodigo, materialLegivel } from '../ecommerce/lib/vitrine.ts'
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
assert.equal(materialLegivel('couche'), 'Papel Couchê')
assert.equal(materialLegivel('bopp'), 'BOPP')
assert.equal(impressaoComCodigo('Colorido Apenas na Frente', '4X0'), 'Colorido Apenas na Frente (4x0)')
assert.equal(acabamentoLegivel('fosca'), 'Laminação Fosca')
assert.equal(acabamentoLegivel('brilho'), 'Laminação Brilho')

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

// Fase 9: checkout em 3 passos (envio, Pix, sessão)
{
  const cli = { whatsapp: '(31) 97561-8243', nome: 'Maria da Silva', email: 'maria@exemplo.com', documento: '' }
  const itens = [{ ref: 'a1b2c3d4e5f6', quantidade: 1 }]
  const envio = validarPedido({ cliente: cli, itens, opcoes: { arte: 'pronta', entrega: 'envio', cep: '01310-100', frete_servico: 'pac', pagamento: 'pix', sessao: 'abcdefgh-1234-5678-abcd' } })
  assert.ok(envio.ok)
  if (envio.ok) { assert.equal(envio.pedido.opcoes.frete_servico, 'pac'); assert.equal(envio.pedido.opcoes.cep, '01310100'); assert.equal(envio.pedido.opcoes.sessao, 'abcdefgh-1234-5678-abcd') }
  const semServico = validarPedido({ cliente: cli, itens, opcoes: { arte: 'pronta', entrega: 'envio', cep: '01310100' } })
  assert.ok(!semServico.ok && semServico.erros.includes('Escolha o serviço de envio.'))
  const pixSemEmail = validarPedido({ cliente: { ...cli, email: '' }, itens, opcoes: { arte: 'pronta', entrega: 'retirada' } })
  assert.ok(!pixSemEmail.ok && pixSemEmail.erros.includes('Informe um e-mail para gerar o Pix.'), 'Pix é o padrão e precisa de e-mail')
  const cartaoSemEmail = validarPedido({ cliente: { ...cli, email: '' }, itens, opcoes: { arte: 'pronta', entrega: 'retirada', pagamento: 'cartao' } })
  assert.ok(cartaoSemEmail.ok, 'cartão não exige e-mail')
  const semCep = validarPedido({ cliente: cli, itens, opcoes: { arte: 'pronta', entrega: 'entrega' } })
  assert.ok(!semCep.ok && semCep.erros.includes('Informe o CEP para a entrega.'))
  const sessaoRuim = validarPedido({ cliente: cli, itens, opcoes: { arte: 'pronta', entrega: 'retirada', sessao: '<script>' } })
  assert.ok(sessaoRuim.ok && sessaoRuim.pedido.opcoes.sessao === null, 'sessão inválida é descartada')
  assert.equal(mensagemErro('frete_indisponivel').status, 409)
}

// CEP e SuperFrete
assert.equal(cepLimpo('30160-040'), '30160040')
assert.equal(cepLimpo('123'), null)
assert.equal(lerEnderecoCep('30160040', { erro: true }), null, 'ViaCEP responde erro:true para CEP inexistente')
assert.deepEqual(lerEnderecoCep('30130010', { logradouro: 'Avenida Afonso Pena', bairro: 'Centro', localidade: 'Belo Horizonte', uf: 'MG' }),
  { cep: '30130010', logradouro: 'Avenida Afonso Pena', bairro: 'Centro', cidade: 'Belo Horizonte', uf: 'MG' })
assert.equal(lerEnderecoCep('30130010', { street: 'Rua A', neighborhood: 'Savassi', city: 'Belo Horizonte', state: 'mg' })?.bairro, 'Savassi', 'formato da BrasilAPI')
{
  const junto = juntarPacotes([{ peso_kg: 1, altura_cm: 5, largura_cm: 11, comprimento_cm: 16 }, { peso_kg: 2, altura_cm: 7, largura_cm: 20, comprimento_cm: 30 }])
  assert.deepEqual(junto, { peso_kg: 3, altura_cm: 12, largura_cm: 20, comprimento_cm: 30 })
  assert.equal(juntarPacotes([{ peso_kg: 0.01, altura_cm: 1, largura_cm: 1, comprimento_cm: 1 }]).comprimento_cm, 16, 'respeita o mínimo dos Correios')
  assert.equal(pacoteValido(junto), true)
  assert.equal(pacoteValido({ peso_kg: 31, altura_cm: 10, largura_cm: 10, comprimento_cm: 10 }), false, 'acima de 30 kg')
  assert.equal(pacoteValido({ peso_kg: 5, altura_cm: 90, largura_cm: 90, comprimento_cm: 90 }), false, 'soma das medidas acima de 200 cm')
  const c = corpoSuperFrete('30160040', '01310100', { peso_kg: 0.278, altura_cm: 4.2, largura_cm: 11, comprimento_cm: 16 })
  assert.equal(c.package.height, 5); assert.equal(c.package.weight, 0.278); assert.equal(c.services, '1,2,17')
  const ops = opcoesEnvio([
    { id: 2, name: 'SEDEX', price: 41.9, delivery_range: { min: 1, max: 2 } },
    { id: 1, name: 'PAC', price: 23.5, delivery_range: { min: 3, max: 6 } },
    { id: 17, name: 'Mini', error: 'fora do peso' }, { id: 99, price: 5 }, { id: 1, price: 0 },
  ])
  assert.deepEqual(ops.map((o) => [o.servico, o.valor, o.prazo_dias]), [['pac', 23.5, 6], ['sedex', 41.9, 2]], 'ordenado por preço, sem serviço com erro')
  assert.deepEqual(opcoesEnvio(null), [])
}

// Pix direto
{
  const corpo = corpoPix({ valor: 166.8, referencia: 'SG-0230', descricao: 'Pedido SG-0230', notificationUrl: 'https://x.test/mp-webhook', expiraEm: new Date('2026-11-10T12:00:00Z'),
    pagador: { email: 'maria@exemplo.com', nome: 'Maria da Silva Santos', documento: '529.982.247-25' } })
  assert.equal(corpo.payment_method_id, 'pix'); assert.equal(corpo.transaction_amount, 166.8); assert.equal(corpo.external_reference, 'SG-0230')
  assert.equal(corpo.payer.first_name, 'Maria'); assert.equal(corpo.payer.last_name, 'da Silva Santos')
  assert.deepEqual(corpo.payer.identification, { type: 'CPF', number: '52998224725' })
  assert.equal(corpo.date_of_expiration, '2026-11-10T12:00:00.000+00:00')
  assert.equal(corpoPix({ valor: 1, referencia: 'SG-1', descricao: 'x', notificationUrl: 'u', expiraEm: new Date(), pagador: { email: 'a@b.co', nome: 'Ana', documento: null } }).payer.last_name, 'Ana')
  assert.ok(!('identification' in corpoPix({ valor: 1, referencia: 'SG-1', descricao: 'x', notificationUrl: 'u', expiraEm: new Date(), pagador: { email: 'a@b.co', nome: 'Ana', documento: '123' } }).payer))
  const pix = lerPix({ id: 123456, date_of_expiration: '2026-11-10T09:00:00.000-03:00', point_of_interaction: { transaction_data: { qr_code: '00020126...', qr_code_base64: 'iVBOR...' } } })
  assert.deepEqual(pix, { pagamento_id: '123456', copia_e_cola: '00020126...', qr_base64: 'iVBOR...', expira_em: '2026-11-10T09:00:00.000-03:00' })
  assert.equal(lerPix({ id: 1, point_of_interaction: {} }), null, 'sem copia e cola não há Pix para mostrar')
  assert.equal(lerPix(null), null)
}

{
  // Fase 12: filtros facetados na URL
  const f = lerFiltros({ sub: 'couche-250g,outro', acab: 'soft-touch,uv', gram: 'encorpado', x: 'ignorado', preco: "ate-50'; drop" })
  assert.deepEqual(f.sub, ['couche-250g'], 'sub é uma só')
  assert.deepEqual(f.acab, ['soft-touch', 'uv'])
  assert.deepEqual(f.preco, ['ate-50drop'].map((x) => x.replace(/[^a-z0-9-]/g, '')), 'valores são limpos')
  assert.equal(lerOrdem({ ordem: 'menor_preco' }), 'menor_preco')
  assert.equal(lerOrdem({ ordem: 'hack' }), 'relevancia')
  assert.equal(hrefFiltros('/categoria/x', f, { q: 'cartao' }, { faceta: 'acab', valor: 'uv' }), '/categoria/x?q=cartao&sub=couche-250g&acab=soft-touch&gram=encorpado&preco=ate-50drop')
  assert.equal(hrefFiltros('/categoria/x', f, {}, { limpar: true }), '/categoria/x')
  assert.equal(hrefFiltros('/categoria/x', {}, { ordem: 'maior_preco' }, { faceta: 'sub', valor: 'a' }), '/categoria/x?ordem=maior_preco&sub=a')
  assert.equal(hrefFiltros('/categorias?vertical=visual', {}, {}, { faceta: 'acab', valor: 'uv' }), '/categorias?vertical=visual&acab=uv', 'mantém a vertical na URL')
}

console.log('OK: ficha técnica da loja (leitura, sigilo da origem e linguagem de balcão)')
