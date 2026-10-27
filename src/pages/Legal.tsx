import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'

const COMPANY = {
  brand: 'Sua Gráfica BH',
  legalName: '58.481.181 JOAO VICTOR BAUER ROCHA GOMES',
  cnpj: '58.481.181/0001-03',
  address: 'Rua Rio de Janeiro, 462, Salas 2216/2217, Centro, Belo Horizonte/MG, CEP 30160-040',
  owner: 'João Victor Bauer Rocha Gomes',
  email: 'contato@suagraficabh.com.br',
  phone: '(31) 97561-8243',
  phoneHref: 'tel:+5531975618243',
  updatedAt: '27/10/2026',
}

function Shell({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="mb-1 text-2xl font-semibold">{title}</h1>
      <p className="mb-6 text-sm text-muted-foreground">
        {COMPANY.brand} · Última atualização: {COMPANY.updatedAt}
      </p>
      <div className="space-y-4 text-sm leading-relaxed [&_h2]:mt-6 [&_h2]:text-base [&_h2]:font-semibold [&_ul]:list-disc [&_ul]:pl-5">{children}</div>
      <p className="mt-10 text-sm">
        <Link to="/privacidade" className="underline">Privacidade</Link> · <Link to="/termos" className="underline">Termos de uso</Link> ·{' '}
        <Link to="/exclusao-de-dados" className="underline">Exclusão de dados</Link>
      </p>
    </div>
  )
}

function ContactLine() {
  return (
    <>
      <strong>{COMPANY.owner}</strong> · <a className="underline" href={`mailto:${COMPANY.email}`}>{COMPANY.email}</a> ·{' '}
      <a className="underline" href={COMPANY.phoneHref}>{COMPANY.phone}</a>
    </>
  )
}

export function Privacy() {
  return (
    <Shell title="Política de Privacidade">
      <p>
        A {COMPANY.brand} ({COMPANY.legalName}, CNPJ {COMPANY.cnpj}, {COMPANY.address}) atende clientes pelo WhatsApp. Esta política explica como
        tratamos seus dados pessoais, em conformidade com a Lei Geral de Proteção de Dados (Lei nº 13.709/2018, LGPD). Para esta política, somos a
        controladora dos dados.
      </p>
      <h2>1. Dados que coletamos</h2>
      <ul>
        <li>Número de telefone (WhatsApp) e nome de perfil, que você nos informa ou que aparece no WhatsApp;</li>
        <li>Conteúdo das mensagens trocadas conosco, incluindo pedidos, orçamentos e arquivos de arte enviados;</li>
        <li>Dados necessários para emitir orçamento, nota fiscal e entrega, quando você os fornece (ex.: nome, endereço, CPF/CNPJ, e-mail);</li>
        <li>Anotações internas do atendimento, como etapa do pedido e observações;</li>
        <li>Registros técnicos de envio e recebimento de mensagens (data, hora e status de entrega).</li>
      </ul>
      <p>Não coletamos dados pessoais sensíveis e pedimos que você não os envie nas conversas.</p>
      <h2>2. Para que usamos</h2>
      <ul>
        <li>Responder dúvidas, elaborar orçamentos e executar pedidos de impressos (cartões de visita, panfletos, banners etc.);</li>
        <li>Enviar atualizações do pedido, como aprovação de arte, produção e entrega;</li>
        <li>Enviar comunicações sobre produtos e promoções, apenas quando você tiver aceitado recebê-las;</li>
        <li>Cumprir obrigações legais e fiscais e exercer direitos em caso de disputa.</li>
      </ul>
      <h2>3. Bases legais</h2>
      <p>
        Execução de contrato ou de procedimentos preliminares a pedido do titular (art. 7º, V), cumprimento de obrigação legal ou regulatória (art.
        7º, II), exercício regular de direitos (art. 7º, VI), legítimo interesse (art. 7º, IX) e consentimento (art. 7º, I), este último para
        comunicações promocionais.
      </p>
      <h2>4. Mensagens promocionais e como parar de recebê-las</h2>
      <p>
        Só enviamos mensagens promocionais a quem aceitou recebê-las. Você pode parar a qualquer momento respondendo &quot;PARAR&quot; na conversa ou
        escrevendo para {COMPANY.email}. Guardamos a data e a origem do seu consentimento (ou do seu pedido para parar) como comprovação. Mensagens ligadas a um pedido em andamento continuam sendo enviadas.
      </p>
      <h2>5. Compartilhamento e operadores</h2>
      <p>
        Seus dados são processados por prestadores que viabilizam o atendimento: Meta Platforms, Inc. (WhatsApp Business Platform, que transmite as
        mensagens e tem política própria de privacidade) e Supabase, Inc. (hospedagem do banco de dados e da autenticação do sistema). Podemos
        compartilhar dados com transportadoras e parceiros de produção, estritamente para entregar seu pedido, e com autoridades quando exigido por
        lei. Não vendemos dados pessoais.
      </p>
      <h2>6. Transferência internacional</h2>
      <p>
        Alguns prestadores acima podem armazenar ou processar dados fora do Brasil. Nesses casos, a transferência ocorre nos termos do art. 33 da
        LGPD, com prestadores que adotam garantias adequadas de proteção.
      </p>
      <h2>7. Armazenamento e segurança</h2>
      <p>
        Mantemos os dados pelo tempo necessário às finalidades acima: conversas e dados de atendimento por até 5 anos após o último contato, e dados
        fiscais pelo prazo exigido em lei. Depois disso, eliminamos ou anonimizamos os dados, salvo obrigação legal de guarda. O acesso ao sistema é
        restrito a atendentes autorizados, com login individual, comunicação criptografada e controle de acesso ao banco de dados.
      </p>
      <h2>8. Seus direitos</h2>
      <p>
        Nos termos do art. 18 da LGPD, você pode solicitar a qualquer momento: confirmação da existência de tratamento, acesso, correção de dados
        incompletos ou desatualizados, anonimização, bloqueio ou eliminação de dados desnecessários, portabilidade, informação sobre
        compartilhamento, informação sobre a possibilidade de não consentir e revogação do consentimento. Respondemos em até 15 dias. Para pedir a exclusão
        dos seus dados, veja a página <Link to="/exclusao-de-dados" className="underline">Exclusão de dados</Link>. Você também
        pode apresentar reclamação à Autoridade Nacional de Proteção de Dados (ANPD).
      </p>
      <h2>9. Contato e encarregado de dados</h2>
      <p>
        Para exercer seus direitos ou tirar dúvidas sobre esta política, fale com o responsável pelo tratamento de dados: <ContactLine />.
      </p>
      <h2>10. Alterações</h2>
      <p>Podemos atualizar esta política. A data da última atualização fica no topo desta página.</p>
    </Shell>
  )
}

export function Terms() {
  return (
    <Shell title="Termos de Uso">
      <p>
        Estes termos regem o atendimento prestado pela {COMPANY.brand} ({COMPANY.legalName}, CNPJ {COMPANY.cnpj}, {COMPANY.address}) por meio do
        WhatsApp. Ao conversar conosco, você concorda com as condições abaixo.
      </p>
      <h2>1. Atendimento</h2>
      <p>
        O atendimento ocorre em horário comercial, informado na conversa. Mensagens enviadas fora desse horário serão respondidas no próximo
        expediente. Parte do atendimento pode ser apoiada por ferramentas automatizadas; você pode pedir para falar com uma pessoa a qualquer
        momento.
      </p>
      <h2>2. Orçamentos e pedidos</h2>
      <ul>
        <li>Orçamentos têm validade de 7 dias e dependem da confirmação das especificações (tamanho, papel, quantidade, acabamento);</li>
        <li>A produção começa após a aprovação da arte e a confirmação do pagamento;</li>
        <li>Prazos de produção e entrega são estimativas contadas a partir da aprovação e podem variar.</li>
      </ul>
      <h2>3. Arquivos e direitos autorais</h2>
      <p>
        Você declara ter direito de uso sobre textos, logotipos e imagens enviados para impressão e se responsabiliza por eles. Revise a prova antes
        da aprovação: após aprovada, erros de conteúdo informados por você não geram reimpressão sem custo. Defeitos de produção, como cor ou corte
        fora do especificado ou falha de impressão, são corrigidos por nós sem custo.
      </p>
      <h2>4. Pagamentos, trocas e cancelamentos</h2>
      <ul>
        <li>As formas de pagamento e o valor total são informados no orçamento aprovado;</li>
        <li>
          Produtos personalizados, feitos sob medida a partir da sua arte e especificações, não têm troca por desistência nem direito de
          arrependimento após o início da produção, conforme a natureza do produto. Antes do início da produção, o pedido pode ser cancelado;
        </li>
        <li>Produtos com defeito ou diferentes do aprovado devem ser comunicados em até 7 dias após o recebimento, para reparo, reimpressão ou reembolso, nos termos do Código de Defesa do Consumidor (Lei nº 8.078/1990);</li>
        <li>Quando houver compra à distância de produto não personalizado, vale o direito de arrependimento de 7 dias do art. 49 do Código de Defesa do Consumidor.</li>
      </ul>
      <h2>5. Uso adequado</h2>
      <p>Não envie conteúdo ilegal, ofensivo ou que viole direitos de terceiros. Podemos encerrar o atendimento em caso de abuso.</p>
      <h2>6. Privacidade</h2>
      <p>
        O tratamento de dados pessoais é descrito na nossa <Link to="/privacidade" className="underline">Política de Privacidade</Link>.
      </p>
      <h2>7. Contato</h2>
      <p><ContactLine /></p>
      <h2>8. Foro</h2>
      <p>Fica eleito o foro da comarca de Belo Horizonte/MG, ressalvado o direito do consumidor de ajuizar ação em seu domicílio.</p>
    </Shell>
  )
}

export function DataDeletion() {
  const mailto = `mailto:${COMPANY.email}?subject=${encodeURIComponent('Exclusão de dados pessoais')}&body=${encodeURIComponent(
    'Olá, solicito a exclusão dos meus dados pessoais.\n\nNome:\nTelefone (WhatsApp) com DDD:\n',
  )}`
  return (
    <Shell title="Exclusão de Dados">
      <p>
        Você pode pedir a exclusão dos seus dados pessoais tratados pela {COMPANY.brand} a qualquer momento, conforme o art. 18 da LGPD. É
        gratuito.
      </p>
      <h2>Como pedir</h2>
      <ul>
        <li>
          Envie um e-mail para <a className="underline" href={mailto}>{COMPANY.email}</a> com seu nome e o telefone (WhatsApp) usado nas conversas;
        </li>
        <li>
          Ou mande uma mensagem pelo WhatsApp para nós com o texto &quot;EXCLUIR MEUS DADOS&quot;, a partir do número que você quer excluir.
        </li>
      </ul>
      <p>Para sua segurança, podemos pedir uma confirmação de que o número é seu antes de excluir.</p>
      <h2>O que acontece depois</h2>
      <ul>
        <li>Respondemos em até 15 dias e excluímos ou anonimizamos seus dados (contato, conversas, arquivos e anotações);</li>
        <li>
          Dados que a lei nos obriga a guardar, como notas fiscais e registros de pedidos, ficam armazenados só pelo prazo legal e depois são
          eliminados;
        </li>
        <li>Se você tinha pedido para não receber promoções, guardamos apenas o seu telefone numa lista de bloqueio, só para respeitar esse pedido;</li>
        <li>Os provedores que nos atendem (como Meta e Supabase) mantêm cópias conforme as próprias políticas, e orientamos a exclusão deles quando aplicável.</li>
      </ul>
      <h2>Dúvidas</h2>
      <p>
        Fale com o responsável pelos dados: <ContactLine />. Você também pode reclamar à Autoridade Nacional de Proteção de Dados (ANPD).
      </p>
      <p>
        Para só parar de receber promoções, responda &quot;PARAR&quot; em qualquer conversa nossa no WhatsApp.
      </p>
    </Shell>
  )
}
