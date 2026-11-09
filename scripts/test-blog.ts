// Fase 8 (blog): leitura de feed, filtro de assunto, slug e conferência do texto gerado. npm run test:blog
import assert from 'node:assert/strict'
import { filtroAssunto, itensNewsApi, lerFeed, pareceCopia, slugBlog, textoLimpo, validarPost } from '../supabase/functions/_shared/blog.ts'

const rss = `<?xml version="1.0"?><rss><channel><title>Feed</title>
<item><title><![CDATA[Embalagens personalizadas ganham espaço no varejo &amp; no e-commerce]]></title>
<link>https://exemplo.com.br/embalagens-varejo/</link><pubDate>Mon, 09 Nov 2026 12:00:00 +0000</pubDate>
<description><![CDATA[<p>Marcas pequenas apostam em caixas com identidade visual própria.</p><p>O post <a href="#">Embalagens</a> apareceu primeiro em <a href="#">Exemplo</a>.</p>]]></description></item>
<item><title>Sem link</title></item>
</channel></rss>`
const itens = lerFeed(rss)
assert.equal(itens.length, 1, 'item sem link é ignorado')
assert.equal(itens[0].titulo, 'Embalagens personalizadas ganham espaço no varejo & no e-commerce')
assert.equal(itens[0].resumo, 'Marcas pequenas apostam em caixas com identidade visual própria.', 'remove o rodapé do WordPress')
assert.equal(itens[0].data, '2026-11-09T12:00:00.000Z')

const atom = `<feed><entry><title>Nova tinta para impressão digital</title><link href="https://ex.com/a"/><updated>2026-11-08T10:00:00Z</updated><summary>Texto</summary></entry></feed>`
assert.equal(lerFeed(atom)[0].url, 'https://ex.com/a', 'Atom com link href')
assert.equal(textoLimpo('A&#233; &lt;b&gt; &nbsp;x'), 'Aé <b> x')
assert.equal(itensNewsApi({ articles: [{ title: '[Removed]', url: 'x' }, { title: 'Brindes', url: 'https://n.com/b', source: { name: 'N' } }] }).length, 1)

const setor = ['embalage', 'impressao', 'grafica', 'identidade visual']
const proibidos = ['eleicao', 'futebol', 'cadunico']
assert.equal(filtroAssunto('Embalagens personalizadas no varejo', setor, proibidos).ok, true)
assert.equal(filtroAssunto('CadÚnico: como funciona o cadastro', setor, proibidos).ok, false)
assert.equal(filtroAssunto('Gráfica patrocina time de futebol', setor, proibidos).ok, false, 'proibido vence o termo do setor')
assert.equal(filtroAssunto('Resultado do trimestre da varejista', setor, proibidos).ok, false)

assert.equal(slugBlog('Embalagens: o que muda em 2027?'), 'embalagens-o-que-muda-em-2027')
assert.ok(slugBlog('a '.repeat(80) + 'palavra final muito comprida').length <= 80)

const fonte = 'Marcas pequenas apostam em caixas com identidade visual própria para se destacar nas prateleiras e nas entregas do comércio eletrônico em todo o país.'
assert.equal(pareceCopia('Segundo a fonte, ' + fonte, fonte), true)
assert.equal(pareceCopia('Texto totalmente diferente escrito com outras palavras sobre caixas e marcas.', fonte), false)

const categorias = [{ slug: 'embalagens', nome: 'Embalagens' }, { slug: 'adesivos', nome: 'Adesivos' }]
const corpo = [
  'Segundo a EmbalagemMarca, cada vez mais negócios pequenos estão investindo em caixas que contam a história da marca no momento da entrega.',
  'A ideia é simples: a primeira impressão acontece quando o cliente abre o pacote, e uma caixa bem pensada vira propaganda espontânea nas redes.',
  '## Como aproveitar no seu negócio',
  'Comece pelo básico: [[embalagens|caixas personalizadas]] com o seu logotipo e um [[adesivos|adesivo de lacre]] já mudam a percepção de quem recebe o pedido.',
  'Vale também incluir um cartão de agradecimento com um convite para seguir a loja, o que aumenta a chance de o cliente comprar de novo e indicar.',
  'Por fim, mantenha as cores e a tipografia iguais em todos os materiais, assim a marca fica fácil de reconhecer em qualquer lugar. [[inexistente|link falso]]',
].join('\n\n')
const ok = validarPost({ relevancia: 8, titulo: 'Embalagem personalizada vira vitrine das pequenas marcas', resumo: 'Caixas com identidade própria ajudam pequenos negócios a se destacar na entrega e nas redes sociais.', corpo, categorias: ['embalagens', 'x'] },
  { categorias, fonteNome: 'EmbalagemMarca', fonteResumo: fonte, bloqueados: ['marcaproibida'], relevanciaMinima: 7 })
assert.equal(ok.ok, true, JSON.stringify(ok))
if (ok.ok) {
  assert.match(ok.post.corpo, /\[caixas personalizadas\]\(\/categoria\/embalagens\)/, 'link interno montado no servidor')
  assert.doesNotMatch(ok.post.corpo, /inexistente|\[\[/, 'slug inválido vira texto simples')
  assert.deepEqual(ok.post.categorias, [{ slug: 'embalagens', nome: 'Embalagens' }])
}
const base = { relevancia: 8, titulo: 'Embalagem personalizada vira vitrine das pequenas marcas', resumo: 'Caixas com identidade própria ajudam pequenos negócios a se destacar na entrega.', corpo, categorias: ['embalagens'] }
const opt = { categorias, fonteNome: 'EmbalagemMarca', fonteResumo: fonte, bloqueados: ['marcaproibida'], relevanciaMinima: 7 }
const motivo = (r: ReturnType<typeof validarPost>) => (r.ok ? 'ok' : r.motivo)
assert.match(motivo(validarPost({ ...base, relevancia: 3 }, opt)), /pouco relevante/)
assert.match(motivo(validarPost({ ...base, corpo: corpo.replace('Segundo a EmbalagemMarca', 'Segundo especialistas') }, opt)), /crédito/)
assert.match(motivo(validarPost({ ...base, corpo: corpo + '\n\nVeja em https://site.com' }, opt)), /endereço/)
assert.match(motivo(validarPost({ ...base, corpo: corpo + '\n\nCaixas a partir de R$ 99.' }, opt)), /preço/)
assert.match(motivo(validarPost({ ...base, corpo: corpo + '\n\nFeito pela MarcaProibida.' }, opt)), /bloqueado/)
assert.match(motivo(validarPost({ ...base, corpo: corpo + '\n\n' + fonte }, opt)), /copiado/)
assert.match(motivo(validarPost({ ...base, corpo: 'Curto.' }, opt)), /curto/)
assert.match(motivo(validarPost({ ...base, categorias: ['nada'] }, opt)), /categoria/)
assert.match(motivo(validarPost('lixo', opt)), /ilegível/)
const travessao = validarPost({ ...base, titulo: 'Embalagem — a vitrine das pequenas marcas' }, opt)
assert.ok(travessao.ok && !travessao.post.titulo.includes('—'), 'remove travessão')

console.log('test-blog: ok')
