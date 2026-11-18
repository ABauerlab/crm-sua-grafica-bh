import { Component, type ErrorInfo, type ReactNode } from 'react'
import { Button } from '@/components/ui/button'

const CHAVE = 'sgbh.recarregou'

/** Erro de arquivo de tela que sumiu depois de uma publicação nova (aba antiga). */
export const erroDeVersaoAntiga = (e: unknown) =>
  /dynamically imported module|Importing a module script failed|Loading chunk|Failed to fetch dynamically|error loading dynamically/i.test(String((e as Error)?.message ?? e))

/** Recarrega uma única vez (por minuto) para pegar a versão nova; devolve se recarregou. */
export function recarregarUmaVez(): boolean {
  try {
    const ultima = Number(sessionStorage.getItem(CHAVE) ?? 0)
    if (Date.now() - ultima < 60_000) return false
    sessionStorage.setItem(CHAVE, String(Date.now()))
  } catch {
    return false
  }
  window.location.reload()
  return true
}

/** Evita a tela branca: qualquer erro de tela vira um aviso com botão, e versão antiga recarrega sozinha. */
export class ErrorBoundary extends Component<{ children: ReactNode }, { erro: unknown }> {
  state = { erro: null as unknown }
  static getDerivedStateFromError(erro: unknown) {
    return { erro }
  }
  componentDidCatch(erro: unknown, info: ErrorInfo) {
    console.error('Erro de tela', erro, info.componentStack)
    if (erroDeVersaoAntiga(erro)) recarregarUmaVez()
  }
  render() {
    if (!this.state.erro) return this.props.children
    return (
      <div role="alert" className="flex min-h-screen flex-col items-center justify-center gap-3 bg-background p-6 text-center">
        <p className="text-lg font-semibold">Algo deu errado nesta tela.</p>
        <p className="max-w-sm text-sm text-muted-foreground">Seus dados estão salvos. Recarregue para continuar; se repetir, avise o suporte.</p>
        <div className="flex gap-2">
          <Button onClick={() => window.location.reload()}>Recarregar</Button>
          <Button variant="outline" onClick={() => this.setState({ erro: null })}>Tentar de novo</Button>
        </div>
      </div>
    )
  }
}
