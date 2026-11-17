import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CheckCircle2, AlertTriangle, RefreshCw } from 'lucide-react'
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { supabase } from '@/lib/supabase'

type Status = { ok: boolean; configurado: boolean; conectado: boolean; loja_id: string | null; loja_nome: string | null; ativo: boolean }
type Linha = { id: string; numero: number; cliente: string; pago_em: string; bling_pedido_id: string | null; enviado_em: string | null; erro: string | null; aviso: string | null; tentativas: number; teste: boolean }
type Painel = { ativo: boolean; loja_id: string | null; loja_nome: string | null; pedidos: Linha[] }

/** Bling e NF > Integração: conectar a conta, ligar o envio automático e acompanhar cada pedido pago. */
export default function BlingTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const [colado, setColado] = useState('')
  const status = useQuery({ queryKey: ['bling', 'status'], queryFn: () => invokeFunction<Status>('bling-integracao', { acao: 'status' }) })
  const painel = useQuery({
    queryKey: ['bling', 'painel'],
    refetchInterval: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('bling_painel')
      if (error) throw new Error(error.message)
      return data as Painel
    },
  })
  const refresh = () => { qc.invalidateQueries({ queryKey: ['bling'] }) }
  const autorizar = useMutation({
    mutationFn: () => invokeFunction<{ url: string }>('bling-integracao', { acao: 'url_autorizacao' }),
    onSuccess: (r) => { window.open(r.url, '_blank', 'noopener'); toast('ok', 'Autorize no Bling e depois cole aqui o endereço para onde ele levar você.') },
    onError: (e: Error) => toast('error', e.message),
  })
  const conectar = useMutation({
    mutationFn: () => invokeFunction<{ loja: string | null; lojas_disponiveis?: string[] }>('bling-integracao', { acao: 'trocar_codigo', code: colado }),
    onSuccess: (r) => { setColado(''); refresh(); toast('ok', r.loja ? 'Bling conectado e loja encontrada.' : `Bling conectado, mas a loja não foi achada. Lojas: ${(r.lojas_disponiveis ?? []).join(', ')}`) },
    onError: (e: Error) => toast('error', e.message),
  })
  const ativar = useMutation({
    mutationFn: (ativo: boolean) => invokeFunction('bling-integracao', { acao: 'ativar', ativo }),
    onSuccess: refresh,
    onError: (e: Error) => toast('error', e.message),
  })
  const enviar = useMutation({
    mutationFn: (id: string) => invokeFunction<{ ok: boolean; erro?: string }>('bling-integracao', { acao: 'enviar', order_id: id }),
    onSuccess: (r) => { refresh(); toast(r.ok ? 'ok' : 'error', r.ok ? 'Pedido enviado ao Bling.' : r.erro ?? 'Não foi possível enviar.') },
    onError: (e: Error) => toast('error', e.message),
  })

  if (status.isLoading || painel.isLoading) return <Skeleton className="h-64 w-full max-w-3xl" />
  const s = status.data
  return (
    <div className="max-w-3xl space-y-5">
      <p className="text-sm text-muted-foreground">
        Todo pedido pago vai sozinho para o Bling na loja {s?.loja_nome ?? 'SUAGRÁFICABH'}, com contato, itens e NCM, para você só emitir a nota. Pedido sem CPF ou endereço também vai, com um aviso para completar no Bling antes de emitir.
      </p>
      <ul className="space-y-1 text-sm">
        <li className="flex items-center gap-2">{s?.configurado ? <CheckCircle2 className="h-4 w-4 text-green-700" /> : <AlertTriangle className="h-4 w-4 text-amber-600" />} Credenciais do aplicativo no servidor: {s?.configurado ? 'configuradas' : 'faltam BLING_CLIENT_ID e BLING_CLIENT_SECRET'}</li>
        <li className="flex items-center gap-2">{s?.conectado ? <CheckCircle2 className="h-4 w-4 text-green-700" /> : <AlertTriangle className="h-4 w-4 text-amber-600" />} Conta do Bling: {s?.conectado ? 'conectada' : 'ainda não autorizada'}</li>
        <li className="flex items-center gap-2">{s?.loja_id ? <CheckCircle2 className="h-4 w-4 text-green-700" /> : <AlertTriangle className="h-4 w-4 text-amber-600" />} Loja {s?.loja_nome ?? ''}: {s?.loja_id ? `encontrada (${s.loja_id})` : 'ainda não localizada'}</li>
      </ul>
      {!s?.conectado && (
        <div className="space-y-2 rounded-md border p-3">
          <p className="text-sm font-semibold">Conectar o Bling (uma vez só)</p>
          <ol className="list-decimal space-y-1 pl-5 text-sm text-muted-foreground">
            <li>Clique em &quot;Abrir autorização&quot; e autorize o aplicativo no Bling.</li>
            <li>O Bling leva você para o site com um endereço terminando em <code>?code=...</code>. Copie o endereço inteiro da barra do navegador.</li>
            <li>Cole aqui embaixo e clique em Conectar (o código vale poucos minutos).</li>
          </ol>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => autorizar.mutate()} disabled={autorizar.isPending || !s?.configurado}>Abrir autorização</Button>
          </div>
          <div className="flex gap-2">
            <Input aria-label="Endereço devolvido pelo Bling" placeholder="https://suagraficabh.com.br/?code=..." value={colado} onChange={(e) => setColado(e.target.value)} />
            <Button onClick={() => conectar.mutate()} disabled={!colado.trim() || conectar.isPending}>Conectar</Button>
          </div>
        </div>
      )}
      {s?.conectado && (
        <div className="flex items-center justify-between rounded-md border p-3">
          <div>
            <p className="text-sm font-semibold">Envio automático de pedidos pagos</p>
            <p className="text-sm text-muted-foreground">{s.ativo ? 'Ligado: a fila roda a cada 2 minutos.' : 'Desligado: nada é enviado ao Bling.'}</p>
          </div>
          <Button variant={s.ativo ? 'outline' : 'default'} onClick={() => ativar.mutate(!s.ativo)} disabled={ativar.isPending || !s.loja_id}>{s.ativo ? 'Desligar' : 'Ligar'}</Button>
        </div>
      )}
      <div>
        <h2 className="mb-2 text-base font-semibold">Pedidos pagos</h2>
        <ul className="divide-y rounded-md border">
          {(painel.data?.pedidos ?? []).map((p) => (
            <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm">
              <div className="min-w-0">
                <p className="font-semibold">SG-{p.numero} · {p.cliente}{p.teste ? ' (teste)' : ''}</p>
                <p className="text-xs text-muted-foreground">
                  {p.bling_pedido_id ? `No Bling (pedido ${p.bling_pedido_id})` : p.erro ? `Erro: ${p.erro}` : 'Aguardando envio'}
                  {p.aviso ? ` · ${p.aviso}` : ''}
                </p>
              </div>
              {!p.bling_pedido_id && (
                <Button size="sm" variant="outline" disabled={enviar.isPending || !s?.conectado} onClick={() => enviar.mutate(p.id)}><RefreshCw className="mr-1 h-3.5 w-3.5" /> Enviar agora</Button>
              )}
            </li>
          ))}
          {(painel.data?.pedidos ?? []).length === 0 && <li className="px-3 py-3 text-sm text-muted-foreground">Nenhum pedido pago ainda.</li>}
        </ul>
      </div>
    </div>
  )
}
