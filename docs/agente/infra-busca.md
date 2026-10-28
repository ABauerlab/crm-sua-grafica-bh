# Infraestrutura de busca de preços (Etapa 3)

Serve só ao workflow `GBH | FERRAMENTA | pesquisar_preco_mercado`. Tudo na **rede interna** do mesmo servidor do n8n (Coolify), sem domínio e sem porta pública.

> Estado em 28/10/2026: os arquivos estão prontos em `infra/`, o leitor com navegador foi testado localmente contra a página pública do concorrente, mas **nada foi instalado no servidor** (a sessão que montou isto não tem acesso ao Coolify). Os passos abaixo são os que faltam.

## 1. O que sobe

| Serviço | Para quê | URL interna (já escrita no workflow) |
|---|---|---|
| `searxng` | Busca na web (API JSON) com poucos mecanismos | `http://searxng:8080` |
| `renderer` | Navegador Playwright que lê páginas que só mostram preço depois do JavaScript | `http://renderer:3000/render` |

As duas URLs ficam no nó **Início e configuração** do workflow (campos `searxng_url` e `renderer_url`). Mudou o nome do contêiner? Mude lá.

## 2. Instalar no Coolify (uma vez)

1. Coolify > projeto da Sua Gráfica BH (ou o mesmo projeto do n8n) > **+ Novo recurso** > **Docker Compose** > origem **Repositório Git** (este repositório, pasta base `infra/searxng`, arquivo `docker-compose.yml`). Se preferir colar o arquivo, copie `infra/searxng/docker-compose.yml`, `infra/searxng/settings.yml` e a pasta `infra/renderer`.
2. Em **Variáveis de ambiente** do recurso, crie:
   - `SEARXNG_SECRET`: texto aleatório de 32 caracteres ou mais (gere com `openssl rand -hex 32`). Nunca no repositório.
   - `RENDERER_TOKEN` (opcional, recomendado): outro texto aleatório. Se usar, adicione o cabeçalho `x-token` no nó **Ler com navegador (Playwright)** do workflow (Autenticação por cabeçalho no n8n, credencial `GBH Renderer`).
3. **Não** atribua domínio nem marque "Expor porta". Em **Redes**, ligue o recurso à mesma rede do n8n (marque "Connect to Predefined Network" e escolha a rede onde o n8n roda). Sem isso o n8n não enxerga `searxng` nem `renderer` pelo nome.
4. **Deploy**. Conferência pelo terminal do n8n no Coolify: `wget -qO- "http://searxng:8080/search?q=cartao+de+visita&format=json" | head -c 300` deve devolver JSON, e `wget -qO- http://renderer:3000/saude` deve devolver `{"ok":true}`.

## 3. Se um mecanismo bloquear

SearXNG devolve poucos resultados ou erro 429/captcha quando um mecanismo bloqueia o servidor. Ajuste `infra/searxng/settings.yml`:

- Desligue o que falha (`disabled: true`) e ligue outro (`startpage`, `qwant`).
- Mantenha o limite do workflow: no máximo 3 buscas por pesquisa, com 1,5 s entre elas, e só quando não há cache de 14 dias.
- Se continuar ruim, troque a fonte por configuração (seção 4). Não é preciso mexer no resto do workflow.

## 4. Trocar a fonte de busca (opcional, com chave gratuita e sem cartão)

No nó **Início e configuração**, o campo `fonte_busca` aceita `searxng` (padrão), `tavily` ou `serper`:

| Fonte | Plano gratuito sem cartão | Onde criar a chave | Onde colar |
|---|---|---|---|
| Tavily | 1.000 créditos por mês | app.tavily.com > API Keys | n8n > Credenciais > **GBH Tavily** (modelo de autenticação personalizada): cabeçalho `Authorization` = `Bearer SUA_CHAVE` |
| Serper | 2.500 consultas | serper.dev > API Key | n8n > Credenciais > **GBH Serper**: cabeçalho `X-API-KEY` = `SUA_CHAVE` |
| Firecrawl (leitura, não busca) | 1.000 créditos por mês | firecrawl.dev > API Keys | n8n > Credenciais > **GBH Firecrawl**: cabeçalho `Authorization` = `Bearer SUA_CHAVE`; no nó de configuração use `leitura_js` = `firecrawl` |

Nunca cole chave no repositório, no workflow exportado nem no CRM. As credenciais ficam só no n8n.

## 5. Credencial do banco (obrigatória)

n8n > Credenciais > Nova > **Supabase API** chamada exatamente `GBH Supabase (service role)`: Host `https://bhlosshvwmlyzhbghsrc.supabase.co`, Service Role Secret = a chave `service_role` do projeto (Supabase > Project Settings > API). É a mesma que as etapas 5 a 7 vão usar. Depois abra cada workflow `GBH |` e selecione a credencial nos nós HTTP (o import deixa o campo vazio por segurança).

## 6. Regras de uso respeitadas pelo workflow

- `robots.txt` e termos conferidos por domínio na tabela `fontes_pesquisa` (`robots_ok`, `termos_ok`). Domínio novo **não é acessado** até o dono conferir e marcar.
- Intervalo mínimo por domínio (`intervalo_s`, 15 s para o concorrente prioritário), um domínio por pesquisa, no máximo 5 páginas e cerca de 45 s no total.
- Identifica-se como `GBH-PrecoBot/1.0`. Sem login, sem carrinho, sem APIs privadas.
- O leitor com navegador recusa endereços internos (localhost, 10.x, 192.168.x, 172.16-31.x).

## 7. O que se sabe do concorrente prioritário (alfacards.com.br)

Verificado em 28/10/2026 (ver também `docs/agente-ia.md`):

- `robots.txt`: `User-agent: *` com `Allow: /` e sitemap. Pode ler.
- Nenhuma página de **termos de uso** foi encontrada em produção. Por isso `termos_ok` ficou **vazio** (não é "sim"). Confirmar com o dono antes de ativar o workflow.
- O HTML inicial **não traz preço**: a loja (plataforma Gráfica Plus) monta a página com JavaScript. O preço visível é o do produto com as opções padrão ("Total R$ ..."); trocar quantidade e papel exige clicar nas opções. O leitor atual lê o que a página mostra sem clicar, então só acha preço quando a quantidade e as especificações do catálogo coincidirem com o que aparece na página. **Espere cobertura baixa** nessa fonte; as outras gráficas achadas pela busca e o cache vão completando. Melhoria possível (não feita): receita de cliques por produto no leitor, uma por layout de página.
