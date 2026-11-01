# Fotos de produto para o agente (Etapa 4B)

Quando o cliente pede foto, o agente envia no WhatsApp até 3 imagens reais do produto, leves e sem indício de origem. A fonte é um site público de terceiros e é **INTERNA**: o endereço dela fica em `app_settings.fotos.origem_base` (preenchido pelo dono em Catálogo > Fotos), nunca no repositório, em documento, em log do agente, em legenda ou em nome de arquivo. Por esta regra este documento diz apenas "a origem".

## 1. Passo 0: o que já existia e o que a origem oferece

* **No CRM:** não havia imagem de produto em lugar nenhum (nem campo, nem Storage, nem tela). `catalogo.grupo_produto` (cerca de 60 grupos para 20.381 linhas) é a chave natural. Foi criado do zero, ao lado das telas de Catálogo.
* **Estrutura da origem (conferida em 01/11/2026):**
  * página de categoria `/produto/categoria/<slug>`: 36 cartões de produto, cada um com link `/servico/detalhe/<categoria>/<produto>/<...>/<CÓDIGO>` e a imagem do produto (`data-src`, arquivo `.../servicos/<GUID>.jpg`);
  * o **último trecho do link é o código do item, igual ao nosso SKU** (ex.: itens de brinde, chaveiros, placas). Hoje o fluxo usa isso só para escolher cartões que combinam com o termo; o SKU nunca sai do servidor;
  * o slug da categoria é o nome do grupo sem acento, minúsculo e com hífens (`slugCategoria` em `_shared/fotos.ts`);
  * as imagens da página de categoria já vêm em até 1000 px (JPEG, cerca de 50 a 130 KB); a página de detalhe traz a mesma imagem.
* **Robots e termos:** `robots.txt` com `User-agent: *` e `Allow: /` (nada proibido). **Não há página de termos de uso** (só política de privacidade, que trata de dados pessoais e não de uso de conteúdo). O dono informou que as fotos são sem marca. Pendência registrada em `docs/agente/depende-de-voce.md`: o dono confirma que pode usar as imagens.
* **Taxa e cortesia:** no máximo 1 requisição por segundo (1,1 s entre acessos), tempo limite de 15 s, `User-Agent` identificável com e-mail de contato, sem paralelismo, uma única consulta por grupo a cada 30 dias.

### Navegação completa do menu (feita em 01/11/2026)
O menu lateral do site tem **152 categorias e cerca de 4.900 subcategorias**. Os produtos de cada categoria vêm de um endereço público que o próprio site usa na paginação (36 itens por página, cada item com o **código, que é igual ao nosso SKU**, e o endereço da imagem). A varredura de todas as categorias (`scripts/fotos-mapear-origem.ts`, 1 requisição por segundo, cerca de 25 minutos) encontrou **26.639 itens, 18.808 códigos e 18.808 imagens distintas**. Não guarda preço nem custo.

* **Mapa gravado em produção em 01/11/2026 (workflow `Mapear fotos da origem`, 30 minutos, sucesso):** 18.433 códigos em 125 categorias do menu.
* **Cobertura exata contra o catálogo:** **18.424 de 20.381 SKUs (90,4%) têm a imagem do próprio item**; **os 140 grupos do catálogo têm pelo menos uma imagem (0 grupos sem imagem)**, então todo produto tem ao menos uma foto do grupo, enviada como ilustrativa quando o item não tem a sua. 28 grupos têm SKUs sem imagem própria; os maiores: canetas promocionais (187 de 427), canecas e copos (173 de 402), postais (916 de 1.143), cardápios (1.116 de 1.313), pastas (766 de 955), convites (416 de 583), tags (1.182 de 1.335) e credenciais (147 de 258).
* **Baixa qualidade:** vários grupos (revista, sacolas, convites, agendas, credenciais) só têm miniaturas de 180 px. Por decisão do dono, **são aceitas**: a imagem é ampliada com suavização para 640 px, entra marcada como "baixa qualidade" na tela e sai por último na ordem de envio, atrás de qualquer foto melhor.
* **O agente nunca diz ao cliente que não há foto.** Se mesmo assim não houver imagem, a orientação é "vou separar as fotos e já envio", o atendimento segue e a equipe recebe alerta para mandar à mão.
* **Reserva pelo catálogo em PDF do dono** (`scripts/fotos-catalogo-pdf.ts`): extrai as imagens de cada página (124 páginas; no teste, 1.051 imagens de 300 px ou mais em 120 páginas), sugere o grupo pelo título da página e envia como **pendentes para aprovação**. O PDF fica fora do repositório.

### Decisões do dono em 01/11/2026
* **Sob demanda, sem estoque de fotos:** nada é baixado antes. O que fica guardado é só o **mapa de texto** código (SKU) -> endereço da imagem (para achar a foto do item certo) e, depois que um cliente pede, a foto pedida (cache de 30 dias). O aquecimento de madrugada segue desligado.
* **Item específico:** quando o agente informa um SKU, a ferramenta busca só a imagem daquele item e envia só ela. Sem SKU, busca só a quantidade pedida entre os itens que combinam com o termo; se o item não estiver no mapa, usa foto do mesmo grupo com legenda ilustrativa.
* **Sem verificação de marca:** o dono garantiu que as imagens da origem são whitelabel (exemplos como "SUALOGO"). `app_settings.fotos.verificar_marca = false`: toda imagem processada é aprovada na hora. A chave `GEMINI_API_KEY` não é necessária. Se um dia aparecer uma foto com marca, o dono bloqueia na aba Fotos; para religar a checagem, basta `verificar_marca = true` e criar a chave.

## 2. Mapeamento e cache

* Tabelas: `produto_fotos` (uma linha por imagem: grupo, `url_origem` só legível pelo dono, `arquivo_storage` com nome de hash, largura, altura, bytes, hash, `status` pendente/aprovada/bloqueada/sem_foto, `revisar`, `aproximada`), `produto_fotos_grupos` (controle de cache: `expira_em`, situação, contagem de pedidos) e `produto_fotos_envios` (limites e auditoria).
* **Por grupo, não por SKU.** Todos os SKUs do grupo compartilham as fotos. `foto_resolver_grupo` resolve SKU exato, depois sinônimos (`sinonimos`), depois palavras da descrição.
* **Cache de 30 dias por grupo** (`app_settings.fotos.cache_dias`). Dentro do prazo a origem não é tocada. Erro de rede reabre a busca em 1 hora (não trava o grupo por 30 dias); "sem foto" fica 30 dias.
* **Sob demanda:** o primeiro pedido de um grupo busca, processa e guarda. Opcional e **desligado por padrão**: `GBH | WF4 | Aquecer fotos de madrugada` (03:20, até 5 grupos por noite, com pausa entre eles) só age se `fotos.aquecer_ligado = true` (caixa na tela).
* **Storage:** bucket privado `produto-fotos`, arquivo `xx/<hash32>.jpg`, sem nome da origem, do produto ou do SKU. O WhatsApp recebe um link assinado de 5 minutos.

## 3. Processamento (limite de peso)

Feito na **Edge Function `produto-fotos`** com `imagescript` (decodificação, redução e codificação JPEG em TypeScript puro). Escolhi a função, e não o nó de imagem do n8n, porque o mesmo código atende o agente, o botão "Buscar de novo" do CRM e o aquecimento noturno, e porque a lógica fica versionada e testada no repositório (`scripts/test-fotos.ts`).

* Reduz para no máximo 1000 px no maior lado, grava JPEG qualidade 80 (desce 72, 64, 56 e 48 até caber), **meta de 150 KB, teto rígido de 300 KB** (acima disso a imagem é descartada). Menor que 100 px (ícone): descartada. Entre 100 e 400 px: aceita como baixa qualidade e ampliada até 640 px.
* O JPEG é recriado do zero: EXIF, perfil e comentários não passam (testado).
* **Verificação whitelabel** na primeira vez de cada imagem: modelo de visão pequeno (Gemini Flash-Lite, segredo `GEMINI_API_KEY`) responde se há logotipo, marca, nome de empresa, site ou telefone. Com marca: `bloqueada` + `revisar`. Sem o segredo ou com falha da verificação: a imagem fica `pendente` + `revisar` e **nunca é enviada** até o dono aprovar (falha fechada).
* **Tela Catálogo > Fotos (dono):** lista dos grupos com situação, pedidos e contagens; filtros "Para revisar" e "Sem foto"; por grupo: ver as imagens, Aprovar, Bloquear, Buscar de novo, Trocar por uma imagem (endereço https) e o campo da origem.

## 4. Ferramenta `enviar_foto_produto(termo_ou_sku, quantidade_fotos)`

Workflow `GBH | FERRAMENTA | enviar_foto_produto` (n8n, desativado) chama a Edge Function `produto-fotos` (ação `enviar`; autenticação do dono ou service role).

1. Valida a conversa e a janela de atendimento de 24 h (ou 72 h de anúncio).
2. Prioridade das imagens: foto do próprio SKU, depois itens do grupo que combinam com o termo, depois variedade do grupo; as de qualidade normal antes das de baixa qualidade.
2. Limites: **3 imagens por pedido, 1 pedido por minuto por conversa, 10 imagens por contato por dia** (fuso de São Paulo). Recusa devolve `muito_rapido` ou `limite_diario` com orientação ao agente.
3. Resolve o grupo, usa o cache ou busca/processa, e envia **só imagens aprovadas** como mensagem de imagem com legenda curta (`legendaSugerida`). Foto do grupo, e não do item exato, vai com legenda **ilustrativa** ("Foto ilustrativa de ... O seu pode variar no acabamento, a gente confirma na hora do orçamento.").
4. Sem foto ou erro da origem: `{enviadas: 0, sem_foto: true, orientacao}` (a orientação proíbe dizer ao cliente que não há foto); grava alerta `foto_indisponivel` (gravidade baixa) para a equipe. Nunca inventa nem usa foto de outro produto sem avisar.
5. Registro em `produto_fotos_envios` e em `agent_logs` (grupo, quantidade, bytes, via cache ou busca; sem origem e sem conteúdo de mensagem).
6. **Resposta ao agente mínima:** `{enviadas, legenda_sugerida}` (ou o formato de sem foto/limite acima). Nunca contém URL, origem, SKU nem nome de arquivo.

Conhecimento: trecho `foto-produto` (categoria `guia`) ensina a oferecer as fotos e já propor quantidade, arte e orçamento (próximo passo de venda).

## 5. Segurança e sigilo

* `url_origem` só é legível pelo dono (RLS `private.is_staff()`); a função `foto_aprovadas`, usada para enviar, não devolve origem.
* As funções do banco que a Edge Function chama ficam em `public` (a service role não alcança o schema `private`); todas conferem `dono_ou_servidor`. Testado com `set role`.
* O `npm test` falha se o nome da origem aparecer em qualquer arquivo do repositório (regra do fornecedor); o domínio é passado ao teste real por variável de ambiente.

## 6. Testes

| Teste | O que cobre |
|---|---|
| `scripts/test-fotos.ts` (`npm run test:fotos`, entra no `npm test`) | parser da listagem, escolha de candidatas, redução a 1000 px, meta de 150 KB, teto de 300 KB, descarte de imagem pequena e ilegível, ausência de metadados, nome de arquivo neutro, limites, legenda ilustrativa e lint de vazamento |
| `supabase/tests/fotos_etapa4b.sql` (25 passam) | resolução de grupo, cache de 30 dias, erro com nova tentativa em 1 hora, hash sem duplicar, só aprovadas saem, bloqueio, limites, logs sem origem, bucket privado, RLS, permissões |
| `scripts/fotos-live.ts` (rede, manual) | 15 grupos reais: ver resultado abaixo |
| `npm run test:conhecimento` | o trecho `foto-produto` passa no lint de tom e vazamento (91 trechos) |

### Resultado dos testes reais (01/11/2026)
* Teste de 15 grupos (antes da navegação completa): 10 grupos com 3 fotos cada, maior imagem 130 KB; 5 grupos só com miniaturas (agora aceitas como baixa qualidade); segunda rodada com 0 chamadas à origem.
* Varredura completa do menu: 152 categorias, 26.639 itens, 18.808 códigos (ver acima).
* Extração do catálogo em PDF: 1.051 imagens aproveitáveis.
* **Não testado:** envio real no WhatsApp, verificação de marca com o modelo de visão, a Edge Function publicada e a ampliação de miniaturas vista a olho (sem Deno, Meta e segredos na sessão).

## 7. Como ligar (passo a passo)

1. Aplicar `docs/agente/aplicar-etapa4b.sql` no SQL Editor (já inclui as 3 migrations, é idempotente) e rodar os advisors de segurança.
2. Publicar `produto-fotos` (CLI: `supabase functions deploy produto-fotos --no-verify-jwt`, ou painel com `docs/agente/funcoes/produto-fotos.bundle.ts`).
3. (Opcional, só se religar a checagem de marca) criar o segredo `GEMINI_API_KEY`.
4. Catálogo > Fotos: preencher "Origem das fotos (interna)" e salvar.
5. Clicar em "Mapear origem (varredura completa)" e manter a aba aberta (cerca de 25 a 40 minutos). Ao fim, ler a Cobertura.
6. Pré-aquecer os grupos mais vendidos: abrir cada um e clicar "Buscar de novo"; revisar e aprovar as imagens.
7. Para SKUs/grupos sem imagem: extrair do PDF (`scripts/fotos-catalogo-pdf.ts`) e aprovar na tela.
8. Atribuir a credencial do Supabase aos nós HTTP dos 2 workflows do n8n (seguem desativados até a Etapa 8).
9. Etapa 8: teste real de envio de imagem no WhatsApp.
