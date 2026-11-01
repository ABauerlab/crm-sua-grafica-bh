# SearXNG e leitor de páginas no Coolify (passo a passo)

**Verificado pelo MCP da Hostinger (01/11/2026):** o servidor é a VPS KVM 2 (`srv2052181`, Ubuntu 24.04, 2 vCPU, 8 GB). O gerenciador de Docker da Hostinger **não funciona** nela ("sistema operacional não suporta Docker Manager"), porque o Docker é controlado pelo Coolify. Por isso eu não consigo instalar pelo MCP: o caminho é o Coolify. Nenhum acesso SSH ou root é necessário.

## 1. Criar o SearXNG no Coolify
1. Coolify > **Projects** > o mesmo projeto e **o mesmo servidor/ambiente do n8n** > **+ New** > **Service** > procure **SearXNG** (catálogo). Se não houver, use **Docker Image** com `searxng/searxng:latest`.
2. **Sem domínio público** (deixe o campo de domínio vazio) ou, se precisar de domínio, proteja com autenticação básica. A porta interna é `8080`.
3. **Rede:** marque **Connect to Predefined Network** (rede do Coolify) para o n8n enxergar o serviço pelo nome interno. O nome é mostrado na tela do serviço (algo como `searxng-<id>:8080`).
4. **Variáveis de ambiente:** `SEARXNG_SECRET` com um valor aleatório longo (gere com `openssl rand -hex 32` no seu computador; **não coloque no repositório**).
5. **Arquivo de configuração** (Storage > settings.yml), pelo menos:
   ```yaml
   use_default_settings: true
   server:
     limiter: false          # uso interno; ligue se expuser
     public_instance: false
   search:
     formats: [html, json]   # a saída JSON é o que o n8n usa
   ```
6. Deploy. Teste de dentro do n8n (nó HTTP): `GET http://<nome-interno>:8080/search?q=cartao+de+visita+500+un&format=json`. Deve vir JSON com `results`.

## 2. Como o n8n chama
No workflow `GBH | FERRAMENTA | pesquisar_preco_mercado`, caixa **Início e configuração**: `fonte_busca = searxng` e `url_busca = http://<nome-interno>:8080`. Sem token se o serviço não é público. Se você colocar um domínio com autenticação, crie a credencial `GBH SearXNG` (Header Auth) e escolha-a no nó (veja `docs/credenciais-n8n.md`).

## 3. Leitor de páginas
Comece **só com requisição HTTP e extração de texto no próprio n8n** (já é o comportamento padrão do workflow). Só ligue o navegador (Playwright, `infra/renderer`) se uma fonte exigir JavaScript: suba o contêiner `infra/renderer` no Coolify, sem exposição pública, e informe `url_leitor_js` na mesma caixa. Permissões mínimas: sem montar volumes do servidor, sem `--privileged`.

## 4. Teste de ponta a ponta (5 especificações)
Depois do deploy, rode o workflow pelo editor (modo manual) com estas especificações e registre o resultado em `docs/agente/etapa3-validacao.md`:
1. 500 cartões de visita 4x4 couchê 300 g; 2. 1.000 panfletos A5 couchê 115 g; 3. 100 adesivos 5x5 vinil; 4. 1 banner 80x120 lona 440 g; 5. 500 ímãs 5x5.
Critério: pelo menos 2 fontes por especificação, mediana coerente com o piso e tempo total menor que 45 s. **Isso não foi executado nesta etapa** (o SearXNG ainda não existe), então o teste fica como pendência.
