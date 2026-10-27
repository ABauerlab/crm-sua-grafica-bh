# Parte 1: identidade, login, kanban, pedido e painel

## Decisões onde o brand kit foi omisso
- **Ação principal em ciano (#00A6D6) com texto preto**: branco sobre ciano dá 2,9:1 e reprova AA; preto dá 6:1. Links e foco usam o azul #1F2A86 (contraste 11:1).
- **Barra lateral preta (#171717)** com o logo em versão para fundo escuro.
- **Logo horizontal**: o arquivo do Drive não foi usado. O CRM usa o símbolo oficial (geometria do SVG) com "SUA GRÁFICA BH" em Inter Black. Para usar o arquivo exato, coloque os SVGs em `public/brand/` e troque em `src/components/brand/Logo.tsx`.
- **Inter Display**: carregada pelo eixo óptico da Inter (Google Fonts, `display=swap`), então títulos grandes ganham o desenho de display automaticamente.
- **Gráficos**: ciano, magenta, laranja e verde, nessa ordem, validados com o script do skill dataviz (a separação ciano/magenta passa; ciano e laranja têm contraste baixo no branco, por isso todo gráfico tem legenda, rótulos e botão "Ver como tabela").
- **Sem modo escuro** nesta parte (prioridade foi contraste e acabamento no claro).
- **"Criar tarefa" no cartão**: aparece desabilitado até a parte 2 (tabela de tarefas).
- **Virtualização**: colunas do kanban paginam de 50 em 50 ("Mostrar mais").

## Configurações manuais
- **Supabase > Authentication > Sign In / Providers**: desligar "Allow new users to sign up".
- **Supabase > Authentication > Sessions**: para a sessão durar bastante, deixe "Time-box user sessions" e "Inactivity timeout" desligados (são recursos de planos pagos). O refresh token em si não expira por tempo.
- **Supabase > Authentication > URL Configuration**: incluir `https://crm.suagraficabh.com.br/redefinir-senha` nas Redirect URLs (usado pelo "Esqueci minha senha").
- **Supabase > Authentication > Password**: ligar a proteção contra senhas vazadas.
- **Mercado Pago**: nada nesta parte. Os campos do pedido (`payment_status`, `payment_external_id`, `payment_link`, `payment_confirmed_at`) já estão prontos para o webhook.

## Migrations
- `20261027000006_pedidos_kanban_referral.sql` (aditiva e idempotente). Rollback em `docs/rollback-parte1.sql`.
- Foi aplicada pelo SQL Editor; se rodar `supabase db push`, ela roda de novo sem efeito colateral.

## Como testar
`npm test` (webhook e regras), `npm run typecheck`, `npm run lint`, `npm run build`. Capturas com `scripts/screenshots.cjs`.
Manual: login com e sem "Continuar conectado" (feche e reabra o navegador), arrastar cartão, mover para Pago sem pagamento (deve bloquear e oferecer confirmar), mover para Produção sem arte aprovada, preço abaixo do piso (pede justificativa), enviar arte.
