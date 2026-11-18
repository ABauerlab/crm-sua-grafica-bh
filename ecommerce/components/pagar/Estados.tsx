import { Clock, SearchX, WifiOff } from 'lucide-react'
import { linkWhatsApp } from '@/lib/site'

type Tipo = 'expirado' | 'cancelado' | 'invalido' | 'erro'
const TEXTOS: Record<Tipo, { titulo: string; texto: string; msg: string }> = {
  expirado: { titulo: 'Este link de pagamento venceu', texto: 'Por segurança, o link tem prazo. Peça um novo no WhatsApp que a gente reabre o seu pedido na hora, com os mesmos valores.', msg: 'Olá! O link de pagamento do meu pedido venceu. Pode gerar um novo?' },
  cancelado: { titulo: 'Este pedido foi cancelado', texto: 'Se foi um engano, fale com a gente no WhatsApp que resolvemos.', msg: 'Olá! Meu pedido aparece como cancelado no link de pagamento. Pode me ajudar?' },
  invalido: { titulo: 'Não encontramos este link', texto: 'Confira se o endereço está completo ou peça um novo link no WhatsApp.', msg: 'Olá! O link de pagamento que recebi não abre. Pode me enviar um novo?' },
  erro: { titulo: 'Não conseguimos carregar agora', texto: 'Pode ser a conexão ou uma instabilidade rápida. Tente de novo em instantes ou fale com a gente.', msg: 'Olá! Estou com dificuldade para abrir o link de pagamento. Pode me ajudar?' },
}

/** Telas de link vencido, pedido cancelado, link inválido e erro de carregamento. */
export function Estado({ tipo, onTentar }: { tipo: Tipo; onTentar?: () => void }) {
  const t = TEXTOS[tipo]
  const Icone = tipo === 'expirado' ? Clock : tipo === 'erro' ? WifiOff : SearchX
  return (
    <div className="entra mx-auto flex min-h-[60vh] max-w-md flex-col items-center justify-center px-6 text-center">
      <span className="flex h-20 w-20 items-center justify-center rounded-full bg-amarelo/30"><Icone className="h-10 w-10 text-tinta" aria-hidden /></span>
      <h1 className="mt-5 text-2xl font-black">{t.titulo}</h1>
      <p className="mt-2 text-black/70">{t.texto}</p>
      {tipo === 'erro' && onTentar && <button type="button" onClick={onTentar} className="mt-5 h-12 rounded-lg bg-tinta px-6 font-bold text-white hover:bg-magenta">Tentar de novo</button>}
      <a href={linkWhatsApp(t.msg)} target="_blank" rel="noopener" className="mt-4 inline-flex h-12 items-center justify-center rounded-lg bg-[#25d366] px-6 font-bold text-white">Falar no WhatsApp</a>
    </div>
  )
}
