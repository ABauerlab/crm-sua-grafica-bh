// Testes locais (Node >= 22): npm run test:alertas. Montagem dos avisos ao dono e a confirmação ao cliente, mais a PWA.
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { janelaAberta, montarConfirmacaoCliente, montarPush, montarTemplate, montarTexto, templateConfirmacaoCliente, varTemplate, type AlertaFila } from '../supabase/functions/_shared/alertas.ts'
import { AGENT_TEMPLATES as TEMPLATES } from '../src/lib/agent-templates.ts'

const pago: AlertaFila = {
  id: 'a1', tipo: 'pedido_pago', gravidade: 'alta', motivo: 'Pedido SG-0034 pago', enviar_push: true, enviar_whatsapp: true, badge: 3,
  conversation_id: 'c1', order_id: 'o1',
  dados: { cliente: 'Maria Souza', itens: '500x Cartão de visita (CV-001)\n1x Adesivo (AD-9)', valor: 'R$ 120,00', lucro_liquido: 'R$ 61,10', previsao: '05/11', pedido: 'SG-0034', metodo: 'pix', url: 'https://crm.suagraficabh.com.br/kanban?pedido=o1' },
}

// ---- push
const p = montarPush(pago)
assert.equal(p.title, 'Pedido pago: SG-0034')
assert.match(p.body, /Maria Souza pagou R\$ 120,00\. Lucro líquido R\$ 61,10\. Previsão 05\/11\./)
assert.equal(p.url, 'https://crm.suagraficabh.com.br/kanban?pedido=o1', 'o toque abre direto o pedido')
assert.equal(p.tag, 'pedido_pago:c1', 'mesmo tipo e conversa: a notificação substitui a anterior')
assert.equal(p.badge, 3)
assert.ok(montarPush({ ...pago, tipo: 'agente_chamado', motivo: 'Cliente reclamou', dados: { cliente: 'João', url: '/inbox/x' } }).title.startsWith('Atenção: João'))
assert.ok(montarPush({ ...pago, dados: { ...pago.dados, teste: true } }).title.startsWith('[TESTE]'))
assert.ok(montarPush({ ...pago, motivo: 'x'.repeat(500), tipo: 'agente_chamado' }).body.length <= 170, 'texto longo é cortado')

// ---- template do WhatsApp: variáveis sem quebra de linha, nunca vazias, na ordem do texto aprovado
const t = montarTemplate(pago)
assert.equal(t.name, 'pedido_pago_dono')
assert.equal(t.params.length, 6)
assert.ok(t.params.every((x) => !/[\n\r\t]/.test(x) && x.trim().length > 0), 'sem quebra de linha e sem vazio')
assert.equal(t.params[0], 'Maria Souza'); assert.equal(t.params[2], 'R$ 120,00'); assert.equal(t.params[3], 'R$ 61,10'); assert.equal(t.params[4], '05/11')
assert.ok(t.params[1].includes('CV-001'), 'o dono vê os SKUs')
const t2 = montarTemplate({ ...pago, tipo: 'agente_chamado', motivo: 'Cliente pediu uma pessoa', dados: { cliente: 'João', url: 'https://x/inbox/1' } })
assert.equal(t2.name, 'alerta_atencao_dono'); assert.deepEqual(t2.params, ['João', 'Cliente pediu uma pessoa', 'https://x/inbox/1'])
assert.equal(varTemplate(''), '-'); assert.equal(varTemplate(null), '-'); assert.equal(varTemplate('a\n\nb    c'), 'a b c')
// a quantidade de variáveis confere com o texto cadastrado em agent-templates.ts
const nVars = (nome: string) => new Set((TEMPLATES.find((x) => x.name === nome)!.body.match(/\{\{(\d+)\}\}/g) ?? [])).size
assert.equal(t.params.length, nVars('pedido_pago_dono')); assert.equal(t2.params.length, nVars('alerta_atencao_dono'))
assert.equal(templateConfirmacaoCliente({ nome: 'Maria', pedido: 'SG-0034', previsao: '05/11' }).length, nVars('pedido_pago_confirmacao'))

// ---- texto livre ao dono (janela aberta)
const txt = montarTexto(pago)
assert.match(txt, /Pedido pago por Maria Souza/); assert.match(txt, /Lucro líquido: R\$ 61,10/); assert.match(txt, /kanban\?pedido=o1/)
assert.match(montarTexto({ ...pago, tipo: 'agente_chamado', motivo: 'Fora do catálogo', dados: { cliente: 'João', url: 'u' } }), /Motivo: Fora do catálogo/)

// ---- janela de 24 h
assert.equal(janelaAberta(new Date(Date.now() + 3600_000).toISOString()), true)
assert.equal(janelaAberta(new Date(Date.now() - 3600_000).toISOString()), false)
assert.equal(janelaAberta(null), false)

// ---- confirmação ao cliente: próximos passos, sem custo, SKU, lucro nem margem
const c = montarConfirmacaoCliente({ nome: 'Maria', pedido: 'SG-0034', previsao: '05/11', arte_status: 'aguardando', entrega: 'retirada' })
assert.match(c, /Pagamento confirmado, Maria!/); assert.match(c, /SG-0034/); assert.match(c, /05\/11/); assert.match(c, /enviar o arquivo/); assert.match(c, /horário de retirada/)
assert.match(montarConfirmacaoCliente({ nome: 'Ana', pedido: 'SG-2', previsao: '06/11', persona: 'João Victor', artigo: 'o' }), /^Oi, Ana! Aqui é o João Victor, assistente virtual da Sua Gráfica BH\. Seu pagamento foi confirmado! Seu pedido SG-2/)
assert.doesNotMatch(montarConfirmacaoCliente({ nome: 'Ana', pedido: 'SG-2', previsao: '06/11', persona: 'João Victor', artigo: 'o' }), /[—–]|custo|margem|piso|fornecedor/i)
assert.match(montarConfirmacaoCliente({ nome: 'Ana', pedido: 'SG-1', previsao: 'a confirmar', arte_status: 'aprovada', entrega: 'uber' }), /arte já está aprovada[\s\S]*entrega a gente combina/)
for (const proibido of [/lucro/i, /custo/i, /margem/i, /piso/i, /fornecedor/i, /\bSKU\b/i, /bicicleta|bike/i]) assert.doesNotMatch(c, proibido, `a confirmação ao cliente não pode conter ${proibido}`)
assert.doesNotMatch(c, /R\. Rio de Janeiro/, 'o endereço só vai no aviso de pronto, com horário')

// ---- PWA: manifest, ícones e service worker
const manifest = JSON.parse(readFileSync(new URL('../public/manifest.webmanifest', import.meta.url), 'utf8'))
assert.equal(manifest.name, 'Sua Gráfica BH'); assert.equal(manifest.display, 'standalone'); assert.ok(manifest.start_url && manifest.scope === '/')
for (const ic of manifest.icons) assert.ok(existsSync(new URL('../public' + ic.src, import.meta.url)), `ícone ${ic.src} existe`)
assert.ok(manifest.icons.some((i: { purpose?: string; sizes: string }) => i.purpose === 'maskable' && i.sizes === '512x512'), 'ícone maskable 512')
assert.ok(manifest.icons.some((i: { purpose?: string; sizes: string }) => i.purpose === 'any' && i.sizes === '512x512'))
assert.ok(existsSync(new URL('../public/icons/apple-touch-icon.png', import.meta.url)), 'ícone 180x180 do iOS')
const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8')
assert.match(html, /rel="manifest"/); assert.match(html, /rel="apple-touch-icon"[^>]*180x180/); assert.match(html, /apple-mobile-web-app-capable/)
const sw = readFileSync(new URL('../public/sw.js', import.meta.url), 'utf8')
for (const ev of ["'push'", "'notificationclick'", "'fetch'", "'install'"]) assert.ok(sw.includes(ev), `service worker ouve ${ev}`)
assert.ok(!/supabase\.co/.test(sw), 'o service worker não guarda dados do Supabase')
assert.match(sw, /origin !== self\.location\.origin/, 'o toque nunca abre endereço de fora')

// ---- segredos: nada de chave VAPID privada no repositório, no front nem no service worker
const push = readFileSync(new URL('../supabase/functions/_shared/push.ts', import.meta.url), 'utf8')
assert.ok(!/VAPID_PRIVATE_KEY\s*=\s*['"]/.test(push)); assert.ok(!/BEGIN (EC )?PRIVATE KEY/.test(push))
const lib = readFileSync(new URL('../src/lib/push.ts', import.meta.url), 'utf8')
assert.ok(!/VAPID_PRIVATE|vapid_privada/.test(lib), 'a chave privada nunca chega ao front')

console.log('Alertas, push e PWA: OK')
