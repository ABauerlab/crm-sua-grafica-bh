import Link from 'next/link'
import { blocos, type Trecho } from '@/lib/blog'

function Linha({ trechos }: { trechos: Trecho[] }) {
  return <>{trechos.map((x, i) => x.t === 'negrito' ? <strong key={i}>{x.v}</strong>
    : x.t === 'link' ? <Link key={i} href={x.href} className="font-semibold text-magenta underline underline-offset-2">{x.v}</Link>
    : <span key={i}>{x.v}</span>)}</>
}

export function PostCorpo({ md }: { md: string }) {
  return (
    <div className="space-y-4 text-[17px] leading-relaxed text-black/80">
      {blocos(md).map((b, i) => b.t === 'h2' ? <h2 key={i} className="pt-2 text-2xl font-black text-tinta"><Linha trechos={b.trechos} /></h2>
        : b.t === 'lista' ? <ul key={i} className="list-disc space-y-1 pl-6">{b.itens.map((it, j) => <li key={j}><Linha trechos={it} /></li>)}</ul>
        : <p key={i}><Linha trechos={b.trechos} /></p>)}
    </div>
  )
}
