# YouTube Knowledge Harvester

Esteira local em duas fases que transforma um canal do YouTube em base de conhecimento `.md` para o agente de WhatsApp. Custo de API zero: a IA roda só pelo Claude Code CLI logado.

## Rodar (1 clique)
- Windows: dê dois cliques em `RODAR_TUDO.bat`
- Mac/Linux: `./rodar_tudo.sh`

Abre o painel em http://localhost:8585 (botão Iniciar / Pausar, status em tempo real, abas para ler o conhecimento, download .md e PDF). Cria o `config.local.json` sozinho, usa os cookies do navegador quando possível e instala as dependências na primeira vez. Se o limite da assinatura acabar, espera sozinho. Pode fechar e abrir de novo: retoma de onde parou.

## Estado e saídas
- `state/videos_index.json` e `state/batches_state.json` (ignorados pelo git)
- `data/transcripts`, `data/batches`, `data/frames` (ignorados pelo git, conteúdo de terceiros)
- `output/conhecimento_grafica/` (resultado para revisão; começa por `LEIA_PRIMEIRO_INDICE.md`; fica só no seu PC)
- `python3 study_loop.py --selftest` testa o detector de rate limit
