import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'

function Shell({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <div role="note" className="mb-6 rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        <strong>TEXTO PROVISÓRIO — PENDENTE DE REVISÃO.</strong> Este conteúdo é um rascunho e não substitui a análise de um advogado. Os campos entre
        colchetes precisam ser preenchidos antes de publicar.
      </div>
      <h1 className="mb-1 text-2xl font-semibold">{title}</h1>
      <p className="mb-6 text-sm text-muted-foreground">Sua Gráfica BH — Última atualização: [DATA A DEFINIR]</p>
      <div className="space-y-4 text-sm leading-relaxed [&_h2]:mt-6 [&_h2]:text-base [&_h2]:font-semibold [&_ul]:list-disc [&_ul]:pl-5">{children}</div>
      <p className="mt-10 text-sm">
        <Link to="/privacidade" className="underline">Privacidade</Link> · <Link to="/termos" className="underline">Termos de uso</Link>
      </p>
    </div>
  )
}

export function Privacy() {
  return (
    <Shell title="Política de Privacidade">
      <p>
        A Sua Gráfica BH ([RAZÃO SOCIAL] — CNPJ [CNPJ], [ENDEREÇO], Belo Horizonte/MG) atende clientes pelo WhatsApp. Esta política explica como
        tratamos seus dados pessoais, em conformidade com a Lei Geral de Proteção de Dados (Lei nº 13.709/2018 — LGPD).
      </p>
      <h2>1. Dados que coletamos</h2>
      <ul>
        <li>Número de telefone (WhatsApp) e nome de perfil que você nos informa ou que aparece no WhatsApp;</li>
        <li>Conteúdo das mensagens trocadas conosco, incluindo pedidos, orçamentos e arquivos de arte enviados;</li>
        <li>Dados necessários para emitir orçamento, nota fiscal e entrega, quando você os fornece (ex.: endereço, CPF/CNPJ);</li>
        <li>Anotações internas do atendimento, como etapa do pedido e observações.</li>
      </ul>
      <h2>2. Para que usamos</h2>
      <ul>
        <li>Responder dúvidas, elaborar orçamentos e executar pedidos de impressos (cartões de visita, panfletos, banners etc.);</li>
        <li>Enviar atualizações do pedido e, quando permitido, comunicações sobre produtos e promoções (você pode pedir para parar a qualquer momento);</li>
        <li>Cumprir obrigações legais e fiscais e exercer direitos em caso de disputa.</li>
      </ul>
      <h2>3. Bases legais</h2>
      <p>Execução de contrato ou de procedimentos preliminares, cumprimento de obrigação legal, legítimo interesse e, quando necessário, consentimento.</p>
      <h2>4. Compartilhamento</h2>
      <p>
        Seus dados são processados por prestadores que viabilizam o atendimento: Meta Platforms (WhatsApp Business Platform) e Supabase (hospedagem do
        banco de dados). Podemos compartilhar dados com transportadoras e parceiros de produção estritamente para entregar seu pedido. Não vendemos
        dados pessoais. [REVISAR: confirmar lista de operadores e eventual transferência internacional.]
      </p>
      <h2>5. Armazenamento e segurança</h2>
      <p>
        Mantemos os dados pelo tempo necessário às finalidades acima e a obrigações legais ([PRAZO DE RETENÇÃO A DEFINIR]). O acesso ao sistema é
        restrito a atendentes autorizados.
      </p>
      <h2>6. Seus direitos</h2>
      <p>
        Você pode solicitar confirmação de tratamento, acesso, correção, anonimização, portabilidade, eliminação dos dados e revogação de
        consentimento. Escreva para [E-MAIL DO ENCARREGADO/CONTATO].
      </p>
      <h2>7. Contato</h2>
      <p>[NOME DO RESPONSÁVEL] — [E-MAIL] — [TELEFONE]</p>
    </Shell>
  )
}

export function Terms() {
  return (
    <Shell title="Termos de Uso">
      <p>
        Estes termos regem o atendimento prestado pela Sua Gráfica BH ([RAZÃO SOCIAL] — CNPJ [CNPJ]) por meio do WhatsApp. Ao conversar conosco,
        você concorda com as condições abaixo.
      </p>
      <h2>1. Atendimento</h2>
      <p>
        O atendimento ocorre em horário comercial ([HORÁRIO A DEFINIR]). Mensagens enviadas fora desse horário serão respondidas no próximo
        expediente. Parte do atendimento pode ser apoiada por ferramentas automatizadas/IA; você pode pedir para falar com uma pessoa.
      </p>
      <h2>2. Orçamentos e pedidos</h2>
      <ul>
        <li>Orçamentos têm validade de [PRAZO A DEFINIR] e dependem de confirmação das especificações (tamanho, papel, quantidade, acabamento);</li>
        <li>A produção começa após aprovação da arte e confirmação do pagamento [CONDIÇÕES A DEFINIR];</li>
        <li>Prazos de produção e entrega são estimativas contadas a partir da aprovação e podem variar.</li>
      </ul>
      <h2>3. Arquivos e direitos autorais</h2>
      <p>
        Você declara ter direito de uso sobre textos, logotipos e imagens enviados para impressão e se responsabiliza por eles. Revise a prova
        antes da aprovação: após aprovada, erros de conteúdo não são motivo de reimpressão sem custo. [REVISAR política de erros e reimpressão.]
      </p>
      <h2>4. Pagamentos, trocas e cancelamentos</h2>
      <p>[POLÍTICA DE PAGAMENTO, TROCA, CANCELAMENTO E ARREPENDIMENTO A DEFINIR — produtos personalizados costumam ter regras específicas.]</p>
      <h2>5. Uso adequado</h2>
      <p>Não envie conteúdo ilegal, ofensivo ou que viole direitos de terceiros. Podemos encerrar o atendimento em caso de abuso.</p>
      <h2>6. Privacidade</h2>
      <p>O tratamento de dados pessoais é descrito na nossa Política de Privacidade.</p>
      <h2>7. Foro</h2>
      <p>Fica eleito o foro da comarca de Belo Horizonte/MG, ressalvado o direito do consumidor de ajuizar ação em seu domicílio.</p>
    </Shell>
  )
}
