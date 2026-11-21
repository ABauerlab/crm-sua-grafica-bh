'use client'
import { useCallback, useEffect, useRef, useState } from 'react'
import { Logo } from '@/components/Logo'
import { chamarPrevia, enviarImagem, fotoPublica, type PreviaStatus } from '@/lib/previa'

type Fase = { tipo: 'carregando' } | { tipo: 'invalido' } | { tipo: 'expirado' } | { tipo: 'ok'; s: PreviaStatus }

const IDEIA_MAX = 500

const ETAPAS = ['Recebendo sua ideia...', 'Montando o layout...', 'Finalizando prévia...']

export function PreviaCliente({ token }: { token: string }) {
  const [fase, setFase] = useState<Fase>({ tipo: 'carregando' })
  const [ideia, setIdeia] = useState('')
  const [uploads, setUploads] = useState<string[]>([])
  const [enviando, setEnviando] = useState(false)
  const [erroEnvio, setErroEnvio] = useState<string | null>(null)
  const [feedback, setFeedback] = useState('')
  const [zoom, setZoom] = useState<string | null>(null)
  const timer = useRef<ReturnType<typeof setInterval> | null>(null)

  const carregar = useCallback(async (silencioso = false) => {
    const r = await chamarPrevia({ acao: 'carregar', token })
    if (r.status === 404) return setFase({ tipo: 'invalido' })
    if (r.status === 410 || r.dados.erro === 'expirado') return setFase({ tipo: 'expirado' })
    if (!r.dados.ok) return silencioso ? undefined : setFase({ tipo: 'invalido' })
    setFase({ tipo: 'ok', s: r.dados })
  }, [token])

  useEffect(() => { void carregar() }, [carregar])

  // Enquanto estiver processando (ou esperando cota), confere a cada 4 s
  useEffect(() => {
    const emAndamento = fase.tipo === 'ok' && (fase.s.status === 'processando' || fase.s.status === 'pendente' || fase.s.status === 'aguardando_limite')
    if (timer.current) { clearInterval(timer.current); timer.current = null }
    if (emAndamento) timer.current = setInterval(() => void carregar(true), 4000)
    return () => { if (timer.current) clearInterval(timer.current) }
  }, [fase, carregar])

  async function handleUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const arquivo = e.target.files?.[0]
    e.target.value = ''
    if (!arquivo || uploads.length >= 2) return
    setErroEnvio(null)
    const r = await enviarImagem(token, arquivo)
    if (!r.ok || !r.path) return setErroEnvio(r.mensagem ?? 'Não foi possível enviar a imagem.')
    setUploads((u) => [...u, r.path!])
  }

  async function enviarBriefing() {
    setEnviando(true)
    setErroEnvio(null)
    const r = await chamarPrevia({ acao: 'enviar_briefing', token, briefing: { servicos: ideia.trim().slice(0, IDEIA_MAX) }, uploads })
    setEnviando(false)
    if (!r.dados.ok) return setErroEnvio('Não foi possível enviar agora. Tente de novo em instantes.')
    void carregar()
  }

  async function regenerar() {
    setEnviando(true)
    const r = await chamarPrevia({ acao: 'regenerar', token })
    setEnviando(false)
    if (r.dados.ok) void carregar()
  }

  async function ajustar() {
    if (!feedback.trim()) return
    setEnviando(true)
    const r = await chamarPrevia({ acao: 'ajustar', token, feedback })
    setEnviando(false)
    if (r.dados.ok) { setFeedback(''); void carregar() }
  }

  async function fecharAgora() {
    setEnviando(true)
    const r = await chamarPrevia<{ ok: boolean; checkout_token?: string; motivo?: string }>({ acao: 'fechar', token })
    setEnviando(false)
    if (r.dados.ok && r.dados.checkout_token) window.location.href = `/pagar/${r.dados.checkout_token}`
  }

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col items-center px-4 py-8">
      <div className="mb-6"><Logo claro={false} /></div>
      <div className="w-full max-w-lg bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
        {fase.tipo === 'carregando' && <Centro>Carregando sua prévia...</Centro>}
        {fase.tipo === 'invalido' && <Centro>Esse link não é válido. Peça um novo link no WhatsApp.</Centro>}
        {fase.tipo === 'expirado' && <Centro>Esse link venceu (as prévias ficam disponíveis por 48 horas). Peça um novo link no WhatsApp.</Centro>}
        {fase.tipo === 'ok' && (
          <Conteudo
            s={fase.s} ideia={ideia} setIdeia={setIdeia} uploads={uploads} onUpload={handleUpload}
            enviando={enviando} erroEnvio={erroEnvio} feedback={feedback} setFeedback={setFeedback}
            onEnviarBriefing={enviarBriefing} onRegenerar={regenerar} onAjustar={ajustar} onFechar={fecharAgora}
            onZoom={setZoom}
          />
        )}
      </div>
      {zoom && (
        <button type="button" onClick={() => setZoom(null)} aria-label="Fechar ampliação"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4 cursor-zoom-out">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={zoom} alt="Ampliada" className="max-h-full max-w-full rounded-lg object-contain" />
        </button>
      )}
    </div>
  )
}

function Centro({ children }: { children: React.ReactNode }) {
  return <p className="text-center text-gray-600 py-8">{children}</p>
}

/** Animação de carregamento com etapas (a geração real demora alguns segundos: modelo + render). */
function Carregando() {
  const [etapa, setEtapa] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setEtapa((e) => Math.min(e + 1, ETAPAS.length - 1)), 2500)
    return () => clearInterval(id)
  }, [])
  return (
    <div className="flex flex-col items-center gap-3 py-10">
      <span className="h-8 w-8 animate-spin rounded-full border-2 border-gray-200 border-t-magenta" aria-hidden />
      <p className="text-sm text-gray-600">{ETAPAS[etapa]}</p>
    </div>
  )
}

function Conteudo(props: {
  s: PreviaStatus; ideia: string; setIdeia: (v: string) => void; uploads: string[]
  onUpload: (e: React.ChangeEvent<HTMLInputElement>) => void; enviando: boolean; erroEnvio: string | null
  feedback: string; setFeedback: (v: string) => void
  onEnviarBriefing: () => void; onRegenerar: () => void; onAjustar: () => void; onFechar: () => void
  onZoom: (url: string) => void
}) {
  const { s } = props
  const foto = fotoPublica(s.produto_foto_path)
  const semIdeiaAinda = s.status === 'pendente' && !s.briefing?.servicos

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">Prévia da sua arte</h1>
        <p className="text-sm text-gray-500">{s.produto_descricao ?? s.sku}</p>
      </div>

      {foto && (
        <button type="button" onClick={() => props.onZoom(foto)} className="block w-full">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={foto} alt={s.produto_descricao ?? 'produto'} className="w-full rounded-xl border border-gray-100 object-contain max-h-56 bg-gray-50" />
          <span className="mt-1 block text-xs text-gray-400">Foto do produto no nosso catálogo (toque para ampliar)</span>
        </button>
      )}

      {semIdeiaAinda && (
        <div className="space-y-3">
          <label className="block">
            <span className="text-sm text-gray-600">Me conta sua ideia: nome, empresa, contato, cores, estilo... o que quiser na arte.</span>
            <textarea value={props.ideia} maxLength={IDEIA_MAX} rows={5}
              placeholder="Ex: Salão Bella Flor, (31) 99999-9999, @salaobelaflor, tons de rosa e dourado, estilo elegante"
              onChange={(e) => props.setIdeia(e.target.value)}
              className="mt-1 w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ciano" />
            <span className="mt-1 block text-right text-xs text-gray-400">{props.ideia.length}/{IDEIA_MAX}</span>
          </label>
          <div>
            <label className="text-sm text-gray-600 block mb-1">Logo ou imagem de referência (opcional, até 2)</label>
            <input type="file" accept="image/jpeg,image/png" onChange={props.onUpload} disabled={props.uploads.length >= 2} className="text-sm" />
            {props.uploads.length > 0 && <p className="text-xs text-gray-500 mt-1">{props.uploads.length} imagem(ns) enviada(s)</p>}
          </div>
          {props.erroEnvio && <p className="text-sm text-red-600">{props.erroEnvio}</p>}
          <button onClick={props.onEnviarBriefing} disabled={props.enviando || !props.ideia.trim()}
            className="w-full rounded-lg bg-magenta text-white font-medium py-2.5 disabled:opacity-60">
            {props.enviando ? 'Enviando...' : 'Gerar minha prévia'}
          </button>
        </div>
      )}

      {(s.status === 'pendente' || s.status === 'processando') && s.briefing?.servicos && <Carregando />}

      {s.status === 'aguardando_limite' && (
        <Centro>A fila de criação está um pouco cheia agora. Pode fechar essa página sem problema: assim que a sua prévia ficar pronta, a gente manda o link atualizado no seu WhatsApp.</Centro>
      )}

      {s.status === 'erro' && (
        <div className="space-y-3">
          <p className="text-sm text-red-600">Tivemos um problema para montar a prévia agora. Pode tentar de novo.</p>
          <button onClick={props.onRegenerar} disabled={props.enviando} className="w-full rounded-lg bg-ciano text-white font-medium py-2.5 disabled:opacity-60">Tentar de novo</button>
        </div>
      )}

      {s.status === 'pronta' && (
        <div className="space-y-4">
          {s.resultado_url && (
            <button type="button" onClick={() => props.onZoom(s.resultado_url!)} className="block w-full">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={s.resultado_url} alt="Prévia da arte" className="w-full rounded-xl border border-gray-100" />
              <span className="mt-1 block text-xs text-gray-400">Toque para ampliar</span>
            </button>
          )}
          <p className="text-xs text-gray-400 text-center">Prévia com marca d'água, só para conferir o layout. A arte final (sem marca d'água) é aprovada por você no WhatsApp antes da impressão.</p>

          <button onClick={props.onFechar} disabled={props.enviando} className="w-full rounded-lg bg-magenta text-white font-semibold py-3 disabled:opacity-60">
            Gostei, quero fechar agora
          </button>

          {s.pode_gerar_de_novo && (
            <button onClick={props.onRegenerar} disabled={props.enviando} className="w-full rounded-lg border border-gray-200 text-gray-700 font-medium py-2.5 disabled:opacity-60">
              Gerar outra versão
            </button>
          )}

          {s.pode_ajustar && (
            <div className="space-y-2 pt-2 border-t border-gray-100">
              <label className="text-sm text-gray-600 block">Quer pedir um ajuste? (uma rodada)</label>
              <textarea value={props.feedback} onChange={(e) => props.setFeedback(e.target.value)} rows={2}
                placeholder="Ex: coloca o nome maior, cor mais escura..."
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ciano" />
              <button onClick={props.onAjustar} disabled={props.enviando || !props.feedback.trim()}
                className="w-full rounded-lg border border-gray-200 text-gray-700 font-medium py-2.5 disabled:opacity-60">
                Pedir esse ajuste
              </button>
            </div>
          )}

          {!s.pode_ajustar && s.ajustes && s.ajustes > 0 ? (
            <div className="space-y-2 pt-2 border-t border-gray-100">
              <label className="text-sm text-gray-600 block">Quer deixar mais algum recado para a equipe de criação?</label>
              <textarea value={props.feedback} onChange={(e) => props.setFeedback(e.target.value)} rows={2}
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ciano" />
              <button onClick={props.onAjustar} disabled={props.enviando || !props.feedback.trim()}
                className="w-full rounded-lg border border-gray-200 text-gray-700 font-medium py-2.5 disabled:opacity-60">
                Salvar recado
              </button>
              <p className="text-xs text-gray-400">A equipe aplica esse ajuste na arte final, depois do pagamento.</p>
            </div>
          ) : null}
        </div>
      )}
    </div>
  )
}
