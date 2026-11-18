# Estudos do dono (18/11/2026): o que foi adaptado para a Laura

Material de origem: anotações de estudo sobre vendas em gráficas (`atualizacao_conhecimento_laura_sua_grafica_bh`). Regra do dono: só aprimorar, sem estragar o que já funciona, e sem rodar testes que gastem a API do Gemini. Nenhum cenário foi rodado.

## O que entrou e onde

| Parte do estudo | Onde virou | Quantos |
|---|---|---|
| 1. Postura no prompt (curioso x decidido, papel em uma frase, par natural, arquivo seguro) | Regras X, Y, Z e AA no nó "Regras adicionais (rodada 18/11)" do WF2 (publicado) | 4 regras curtas |
| Urgência e escassez (pergunta do dono) | Regra AB no WF2 e trechos `urgencia_honesta_usar`, `urgencia_evento_data`, `escassez_nao_usar` | 1 regra e 3 trechos |
| 2. Postura comercial e objeções | `mql_uso_negocio`, `sql_comprador_pronto`, `espelhar_tom`, `obj_caro_valor_incluso`, `obj_pensar_pdf_socio`, `brinde_valor_percebido` | 6 trechos |
| 3. Papéis, gramaturas, acabamentos, digital x tiragem | `guia_papeis`, `guia_gramaturas`, `guia_acabamentos`, `guia_digital_tiragem` | 4 trechos |
| 4. Fechamento de arquivo | `arq_regras_ouro`, `arq_canva`, `arq_frente_verso`, `arq_enobrecimento`, `arq_laser`, `arq_conferencia_valor` | 6 trechos |
| 5. Upsell, cross-sell e kits por nicho | `par_natural_impressos`, `par_natural_embalagem`, `kit_gastronomia`, `kit_saude`, `kit_varejo`, `kit_escritorio`, `kit_eventos`, `kit_sazonal` | 8 trechos |
| 6. Fichas de produto | `ficha_sacolas`, `ficha_adesivos_rotulos`, `ficha_comunicacao_visual`, `ficha_textil`, `ficha_brindes`, `ficha_calendarios_agendas` | 6 trechos |

Total: 33 trechos novos em `public.conhecimento` (fonte "Estudos do dono (18/11/2026)", todos com `revisar = true` para você aprovar na tela Configurações > Conhecimento). Fonte editável: `docs/agente/conhecimento_rodada18.json`; a migration `20261218000004` é gerada por `scripts/gerar-conhecimento-rodada18.ts` (que roda o lint de tamanho, tom e vazamento antes). Vetores `gte-small` gerados pela função `conhecimento` (modelo do Supabase, não usa o Gemini).

Nada existente foi sobrescrito: os trechos novos complementam os antigos (por exemplo `obj_caro_valor_incluso` complementa `obj_caro`).

## O que foi mudado do material original, e por quê

| Original | Adaptado | Motivo |
|---|---|---|
| "3 opções (econômica, intermediária, premium)" | no máximo 2 opções (a mais em conta e a mais indicada) | regra K do prompt: lista longa trava a decisão |
| "corte das 12h" | corte de 10h30 em dias úteis | decisão do dono de 17/11. Cinco trechos antigos ainda diziam 12h (`prazo_corte`, `obj_pensar`, `obj_prazo`, `prazo_contamos`, `fu_f2`) e foram corrigidos |
| "sempre oferecer cordão junto ao crachá" | cordão oferecido uma vez e nunca depois de recusado | regra T (cordão é opcional) |
| "margem de segurança" | "área segura" | o lint do banco proíbe a palavra margem em qualquer trecho |
| "custo-benefício" | removido | o lint proíbe "custo" |
| nome da persona escrito | variável `{{persona_vendas}}` quando necessário | nome fica em Configurações |
| valores e prazos escritos | só variáveis (`{{validade}}`, `{{arte_basica}}`) ou da ferramenta | regra: o modelo nunca calcula preço nem prazo |
| "produção digital rápida em tiragem menor" como alternativa de urgência | só alternativa que a busca trouxer | regra R: nunca oferecer produção que a ferramenta não trouxe (caso Artur, 17/11) |
| conferência técnica de sangria e corte como fato | "a equipe confere o arquivo antes de imprimir e avisa" com `[CONFIRMAR]` no alcance | só afirmo o que o fluxo de aprovação já faz |

## Urgência e escassez: faz sentido na gráfica?

**Urgência: sim, mas só a real.** Funciona porque a gráfica tem fatos verdadeiros para usar: o horário de corte da produção (10h30 em dias úteis), a validade do orçamento, a condição especial que a ferramenta libera com validade, e a data do evento do cliente (a mais forte: "pra chegar no dia X precisa aprovar até tal hora"). Já existiam o follow-up com desconto relâmpago e o selo de urgência no CRM. Entrou a regra AB e o trecho `urgencia_honesta_usar`.

**Escassez: não.** A gráfica produz sob encomenda, não existe "últimas unidades" nem "estoque acabando". Inventar escassez quebra a confiança (o mesmo problema que você apontou com preço divergente) e o público de tráfego pago é de ticket baixo e decisão rápida, então o risco é maior que o ganho. Entrou o trecho `escassez_nao_usar` e a regra AB proíbe. Única exceção possível: fila cheia em datas de pico (fim de ano), só se você confirmar que é verdade (`[CONFIRMAR]` no trecho).

## Para você confirmar (marcado com [CONFIRMAR] nos trechos, só em "fatos", nunca vai ao cliente)
1. A conferência do arquivo cobre sangria e corte em todos os pedidos? (`arq_regras_ouro`, `arq_conferencia_valor`)
2. Em fim de ano existe fila cheia que justifique dizer "aprove cedo pra garantir a data"? (`escassez_nao_usar`)
3. Os itens citados nas fichas e kits existem no catálogo? A Laura só os sugere se `buscar_produto` achar, então um item que não existe simplesmente não aparece.

## Como conferir nas inspeções
- Trechos usados: `select slug, usos, ultimo_uso_em from conhecimento where fonte = 'Estudos do dono (18/11/2026)' order by usos desc`.
- Lacunas que a Laura não soube responder: tabela `conhecimento_lacunas`.
- Nas conversas: curioso recebe pergunta de uso; decidido recebe orçamento direto; opções com papéis diferentes trazem uma frase de diferença; um único complemento sugerido por pedido; nenhuma frase de escassez.
- Revisão: aprovar os trechos na tela de Conhecimento tirando o `revisar`.

## Não feito, de propósito
- Nenhuma lógica de preço, prazo, frete, margem, condição especial ou Mercado Pago foi alterada.
- O prompt não foi inflado: 5 regras curtas (X a AB), todo o resto fica no banco de conhecimento e só entra na conversa quando a busca acha o trecho.
- Nenhum cenário `e5-*`, `mvp-*`, `e12-*` ou `e17-*` foi rodado (gastam o Gemini).
