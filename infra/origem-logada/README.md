# Origem logada 24 h (Chrome persistente + API de consulta)

Mantém um Chrome real, logado na área do fornecedor, na VPS (Coolify). O CRM consulta preço, tamanho e prazo atuais antes de orçar.
O endereço da origem fica só em variável de ambiente (`ORIGEM_BASE`). Nunca no repositório.

- `navegador`: Chrome (imagem linuxserver/chromium) com perfil em volume persistente, acesso por navegador (noVNC/KasmVNC) com usuário e senha, depuração por CDP só dentro do contêiner.
- `consulta`: Node + playwright-core, mesma rede do navegador; API com token (`/saude`, `/consultar`) e guarda de sessão a cada 4 min.
- Primeiro uso: abrir o endereço do navegador no Coolify, entrar na conta da origem uma vez (e-mail, senha, CAPTCHA) e deixar a janela aberta. O perfil guarda a sessão.
- Quando a sessão cair: o banco (`origem_sessao_registrar`) cria alerta para o dono pelo WhatsApp.
- A Edge Function `origem-consultar` é quem chama esta API (segredos `ORIGEM_API_URL` e `ORIGEM_API_TOKEN`).
