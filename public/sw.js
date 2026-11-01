/* Service worker do CRM Sua Gráfica BH.
 * 1) Cache básico: o "casco" do app abre rápido. Nada de dados (Supabase, funções, mídia) é guardado: sempre da rede.
 * 2) Web Push: mostra o aviso, agrupa o mesmo tipo e abre direto no pedido ou na conversa ao tocar.
 * Para publicar uma versão nova do cache, troque VERSAO. */
const VERSAO = 'sgbh-v1'
const CASCO = ['/offline.html', '/icons/icon-192.png', '/favicon.svg']

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSAO).then((c) => c.addAll(CASCO)).then(() => self.skipWaiting()))
})

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSAO).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (e) => {
  const req = e.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return // Supabase, fontes e tudo de fora vão direto para a rede
  // navegação: rede primeiro; sem internet, tela de "sem conexão"
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).catch(() => caches.match('/offline.html')))
    return
  }
  // arquivos versionados do build e ícones: cache primeiro (o nome muda a cada versão)
  if (url.pathname.startsWith('/assets/') || url.pathname.startsWith('/icons/')) {
    e.respondWith(
      caches.match(req).then(
        (hit) =>
          hit ||
          fetch(req).then((res) => {
            if (res.ok) { const copia = res.clone(); caches.open(VERSAO).then((c) => c.put(req, copia)) }
            return res
          }),
      ),
    )
  }
})

// ---------------------------------------------------------------- push
self.addEventListener('push', (e) => {
  let d = {}
  try { d = e.data ? e.data.json() : {} } catch { d = { title: 'Sua Gráfica BH', body: e.data ? e.data.text() : '' } }
  e.waitUntil(mostrar(d))
})

async function mostrar(d) {
  const tipo = d.tipo || 'aviso'
  const abertas = await self.registration.getNotifications()
  const mesmoTipo = abertas.filter((n) => n.data && n.data.tipo === tipo && n.tag !== d.tag)
  let title = d.title || 'Sua Gráfica BH'
  let body = d.body || ''
  let tag = d.tag || tipo
  // 2 ou mais do mesmo tipo na bandeja: vira uma só ("3 avisos") para não empilhar
  if (mesmoTipo.length >= 1) {
    const total = mesmoTipo.reduce((s, n) => s + ((n.data && n.data.qtd) || 1), 0) + 1
    mesmoTipo.forEach((n) => n.close())
    title = `${total} avisos: ${d.title || tipo}`
    body = body || 'Toque para ver.'
    tag = `grupo:${tipo}`
    d.qtd = total
  }
  const opcoes = {
    body,
    tag,
    renotify: true,
    icon: '/icons/icon-192.png',
    badge: '/icons/badge-96.png',
    data: { url: d.url || '/painel', tipo, qtd: d.qtd || 1 },
    requireInteraction: d.gravidade === 'alta',
  }
  if (typeof self.navigator.setAppBadge === 'function' && Number.isFinite(d.badge)) {
    try { d.badge > 0 ? await self.navigator.setAppBadge(d.badge) : await self.navigator.clearAppBadge() } catch { /* sem suporte */ }
  }
  await self.registration.showNotification(title, opcoes)
}

self.addEventListener('notificationclick', (e) => {
  e.notification.close()
  const alvo = new URL((e.notification.data && e.notification.data.url) || '/painel', self.location.origin)
  if (alvo.origin !== self.location.origin) return // nunca abre endereço de fora
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((lista) => {
      const aberta = lista.find((c) => new URL(c.url).origin === self.location.origin)
      if (aberta) {
        aberta.postMessage({ tipo: 'abrir', url: alvo.pathname + alvo.search })
        return aberta.focus()
      }
      return self.clients.openWindow(alvo.href)
    }),
  )
})

// a assinatura expirou ou o navegador a trocou: o app registra de novo ao abrir
self.addEventListener('pushsubscriptionchange', (e) => {
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then((l) => l.forEach((c) => c.postMessage({ tipo: 'reassinar' }))))
})
