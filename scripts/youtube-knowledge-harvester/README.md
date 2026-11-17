# YouTube Knowledge Harvester

Esteira local em duas fases que transforma um canal do YouTube em base de conhecimento `.md` para o agente de WhatsApp. Custo de API zero: a IA roda só pelo Claude Code CLI logado.

## Preparar (uma vez)
```bash
cd scripts/youtube-knowledge-harvester
pip install -r requirements.txt
cp config.local.example.json config.local.json   # coloque a URL do canal (arquivo ignorado pelo git)
```
Se o YouTube pedir "confirm you're not a bot", adicione `"cookies_do_navegador": "chrome"` no `config.local.json`.

## Rodar o canal inteiro (comando único)
```bash
cd scripts/youtube-knowledge-harvester && python3 harvester.py && python3 study_loop.py
```
Pode interromper e rodar de novo: retoma do lote pendente. Rate limit da assinatura: o loop espera sozinho (horário informado + 2 min, ou 15, 30, 60 min) e restaura o backup do lote interrompido.

## Estado e saídas
- `state/videos_index.json` e `state/batches_state.json` (ignorados pelo git)
- `data/transcripts`, `data/batches`, `data/frames` (ignorados pelo git, conteúdo de terceiros)
- `output/conhecimento_grafica/` (conhecimento higienizado, vai ao repositório)
- `python3 study_loop.py --selftest` testa o detector de rate limit
