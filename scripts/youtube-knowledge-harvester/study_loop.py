#!/usr/bin/env python3
"""Fase 2: orquestrador. Processa cada batch_XXX.md pendente com o Claude Code CLI logado
(assinatura, sem API key), com backup por lote, validação atômica e auto-retry de rate limit.

Uso:
  python3 study_loop.py                 # processa a fila inteira e espera os limites sozinho
  python3 study_loop.py --only batch_001
  python3 study_loop.py --max-batches 3
  python3 study_loop.py --selftest      # testa o detector de rate limit
"""
import argparse, json, re, shutil, subprocess, sys, time
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATE = ROOT / "state"
BATCHES_FILE = STATE / "batches_state.json"
BACKUP = STATE / "backup_last_good"
OUT = ROOT / "output" / "conhecimento_grafica"
PROGRESSO = OUT / "PROGRESSO_ESTUDO.md"
ARQUIVOS = ["01_PLAYBOOK_VENDAS_E_ARGUMENTOS.md", "02_GUIA_PAPEL_E_ACABAMENTOS.md",
            "03_MANUAL_FECHAMENTO_DE_ARQUIVO.md", "04_CATALOGO_APLICACOES_PRODUTOS.md",
            "00_CONSCIENCIA_MESTRE_AGENTE.md", "PROGRESSO_ESTUDO.md"]
TIMEOUT_LOTE = 45 * 60
ESPERAS_SEM_HORARIO = [15, 30, 60]  # minutos; depois repete 60
MARGEM_MIN = 2
MAX_FALHAS_GENERICAS = 3

# Termos que nunca podem aparecer no conhecimento (white-label e regras do projeto).
PROIBIDOS = [r"zap\s*gr[aá]fica", r"\bzap\b", r"zap\s*go", r"parque\s+gr[aá]fico", r"checagem\s+garantida",
             r"zapgrafica", "—", "–"]

RATE_RE = re.compile(r"rate.?limit|usage.?limit|limit reached|limit will reset|resets?\s+(at|in)|too many requests|"
                     r"\b429\b|overloaded|quota|try again (in|later)|5-hour limit|weekly limit", re.I)

SEED = {
    "01_PLAYBOOK_VENDAS_E_ARGUMENTOS.md": "# Playbook de vendas e argumentos\n\n(gatilhos, indicação por nicho, upsell de acabamentos, quebra de objeções)\n",
    "02_GUIA_PAPEL_E_ACABAMENTOS.md": "# Guia de papéis e acabamentos\n\n(gramaturas, papéis, enobrecimentos)\n",
    "03_MANUAL_FECHAMENTO_DE_ARQUIVO.md": "# Manual de fechamento de arquivo\n\n(regras de pré-impressão)\n",
    "04_CATALOGO_APLICACOES_PRODUTOS.md": "# Catálogo de aplicações de produtos\n\n(fichas consultivas)\n",
    "00_CONSCIENCIA_MESTRE_AGENTE.md": "# Consciência mestre do agente\n\n(versão consolidada)\n",
    "PROGRESSO_ESTUDO.md": "# Progresso do estudo\n\nDiário incremental. Cada lote vira uma seção `## batch_XXX`.\n",
}


# ------------------------------------------------------------ rate limit
def detectar_rate_limit(texto):
    return bool(RATE_RE.search(texto or ""))


def extrair_reset(texto, agora=None):
    """Devolve datetime do reset informado pelo Claude, ou None."""
    agora = agora or datetime.now()
    t = texto or ""
    m = re.search(r"limit reached\|(\d{10})", t, re.I)  # formato antigo: epoch
    if m:
        return datetime.fromtimestamp(int(m.group(1)))
    for m in re.finditer(r"\b(?:in|after)\s+(?:(\d+)\s*(?:hours?|hrs?|h)\b)?\s*(?:and\s*)?(?:(\d+)\s*(?:minutes?|mins?|m)\b)?", t, re.I):
        if m.group(1) or m.group(2):
            return agora + timedelta(hours=int(m.group(1) or 0), minutes=int(m.group(2) or 0))
    m = re.search(r"in\s+(\d+)\s*seconds?", t, re.I)
    if m:
        return agora + timedelta(seconds=int(m.group(1)))
    m = re.search(r"resets?(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([\w/+-]+)\))?", t, re.I)
    if m:
        h, mi, ap, tz = int(m.group(1)), int(m.group(2) or 0), (m.group(3) or "").lower(), m.group(4)
        if ap == "pm" and h < 12: h += 12
        if ap == "am" and h == 12: h = 0
        if h > 23 or mi > 59:
            return None
        base = agora
        if tz:
            try:
                from zoneinfo import ZoneInfo
                base = datetime.now(ZoneInfo(tz)).replace(tzinfo=None)
                alvo = base.replace(hour=h, minute=mi, second=0, microsecond=0)
                if alvo <= base: alvo += timedelta(days=1)
                return agora + (alvo - base)  # diferença real, independente do fuso do PC
            except Exception:
                pass
        alvo = agora.replace(hour=h, minute=mi, second=0, microsecond=0)
        if alvo <= agora: alvo += timedelta(days=1)
        return alvo
    return None


def pausa(destino, batch, motivo="RATE LIMIT"):
    print(f"\n[PAUSA {motivo}] Limite da assinatura atingido no {batch}. Retomando automaticamente às {destino:%H:%M}...", flush=True)
    while True:
        falta = (destino - datetime.now()).total_seconds()
        if falta <= 0:
            break
        h, r = divmod(int(falta), 3600); m, s = divmod(r, 60)
        print(f"\r[PAUSA {motivo}] {batch}: retoma às {destino:%H:%M} (faltam {h:02d}:{m:02d}:{s:02d})   ", end="", flush=True)
        time.sleep(min(1, max(falta, 0)))
    print(f"\n[RETOMANDO] {batch}", flush=True)


# ------------------------------------------------------------ estado e backup
def load_state():
    return json.loads(BATCHES_FILE.read_text(encoding="utf-8")) if BATCHES_FILE.exists() else {}


def save_state(st):
    tmp = BATCHES_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(BATCHES_FILE)


def garantir_saida():
    OUT.mkdir(parents=True, exist_ok=True)
    for nome, conteudo in SEED.items():
        if not (OUT / nome).exists():
            (OUT / nome).write_text(conteudo, encoding="utf-8")


def backup():
    if BACKUP.exists():
        shutil.rmtree(BACKUP)
    shutil.copytree(OUT, BACKUP)


def restaurar():
    if not BACKUP.exists():
        return
    shutil.rmtree(OUT, ignore_errors=True)
    shutil.copytree(BACKUP, OUT)
    print("[BACKUP] arquivos .md restaurados do último estado bom", flush=True)


# ------------------------------------------------------------ prompt e validação
def montar_prompt(batch, extra=""):
    return f"""Você é o consultor especialista em gráfica rápida da Sua Gráfica BH (Belo Horizonte) e está estudando material para treinar o agente de WhatsApp da empresa.

TAREFA: leia o arquivo data/batches/{batch}.md (use a ferramenta Read; se for grande, leia em partes). Cada item é um vídeo ou Short com título, descrição, capítulos e transcrição. Itens com "## Frames-chave" listam imagens em data/frames/: abra-as com Read para entender o que o vídeo mostra.
Depois atualize de forma INCREMENTAL, com Read/Edit/Write, os arquivos em output/conhecimento_grafica/:
- 01_PLAYBOOK_VENDAS_E_ARGUMENTOS.md: gatilhos comerciais, produtos por nicho de cliente, upsell de acabamentos, quebra de objeções.
- 02_GUIA_PAPEL_E_ACABAMENTOS.md: gramaturas (90g, 115g, 150g, 250g, 300g), papéis (couché, supremo, offset, reciclato, kraft, adesivos, lonas) e enobrecimentos (laminação fosca/brilho/soft touch, verniz localizado, hot stamping, corte especial, furo, dobra), em linguagem prática e comercial.
- 03_MANUAL_FECHAMENTO_DE_ARQUIVO.md: pré-impressão (sangria, margem de segurança, CMYK vs RGB, fontes em curvas, preto calçado vs 100% K, 300 dpi, exportação no Canva, CorelDRAW, Illustrator e PDF/X-1a).
- 04_CATALOGO_APLICACOES_PRODUTOS.md: ficha consultiva de cada produto gráfico abordado.
- 00_CONSCIENCIA_MESTRE_AGENTE.md: versão consolidada, enxuta e densa dos quatro arquivos, pronta para injetar no agente. Reescreva-a ao final do lote, mantendo tudo que já havia e somando o novo.
- PROGRESSO_ESTUDO.md: acrescente no FIM uma seção que comece exatamente com a linha `## {batch}`, com data, lista dos títulos lidos e os novos aprendizados absorvidos.

REGRAS DE ATUALIZAÇÃO
- Não apague o que já foi aprendido e não duplique tópicos: se o assunto já existe, complemente a seção existente.
- Se o lote não trouxer nada útil para uma área, deixe o arquivo como está, mas registre o lote no PROGRESSO_ESTUDO.md assim mesmo.
- Escreva em português do Brasil, tom de consultor da Sua Gráfica BH atendendo o cliente final. Converta qualquer fala voltada a revendedor, parceiro de gráfica ou plataforma em orientação ao cliente final.

HIGIENE OBRIGATÓRIA (o lote é rejeitado se violar)
- Nunca escreva o nome do canal, da marca, da plataforma ou do software de onde o vídeo veio, nem "Zap", "Zap Gráfica", "Zap GO", "Parque Gráfico" ou "Checagem Garantida". Descreva só o conhecimento.
- Nunca use travessão (— ou –). Use vírgula, ponto ou dois-pontos.
- Não registre preços, prazos, fretes, descontos nem margens citados nos vídeos: isso é decidido pelo sistema da empresa. Não cite SKU, fornecedor, endereço de fábrica nem concorrentes.
- Nunca diga que o atendente é robô, IA ou assistente virtual.
{extra}
Ao terminar, responda apenas "OK {batch}" e uma linha de resumo."""


def validar(batch, antes_progresso):
    erros = []
    for nome in ARQUIVOS:
        p = OUT / nome
        if not p.exists() or p.stat().st_size < 50:
            erros.append(f"{nome} ausente ou vazio")
    if erros:
        return erros
    prog = PROGRESSO.read_text(encoding="utf-8")
    if not re.search(rf"^##\s+{re.escape(batch)}\b", prog, re.M):
        erros.append(f"PROGRESSO_ESTUDO.md sem o registro do {batch}")
    if len(prog) <= antes_progresso:
        erros.append("PROGRESSO_ESTUDO.md não cresceu")
    for nome in ARQUIVOS:
        txt = (OUT / nome).read_text(encoding="utf-8")
        for pad in PROIBIDOS:
            m = re.search(pad, txt, re.I)
            if m:
                erros.append(f"{nome}: termo proibido '{m.group(0)}'")
                break
    return erros


# ------------------------------------------------------------ execução
def rodar_claude(prompt):
    cmd = ["claude", "-p", prompt, "--allowedTools", "Read,Write,Edit", "--permission-mode", "acceptEdits"]
    try:
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=TIMEOUT_LOTE)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or ""), (e.stderr or "") + "\ntimeout"


def processar_lote(batch, st):
    garantir_saida()
    esp_idx = 0
    falhas = 0
    extra = ""
    while True:
        if not (ROOT / "data" / "batches" / f"{batch}.md").exists():
            print(f"[ERRO] data/batches/{batch}.md não existe"); st[batch]["status"] = "failed"; save_state(st); return False
        backup()
        st[batch]["status"] = "processing"; st[batch]["tentativas"] = st[batch].get("tentativas", 0) + 1
        save_state(st)
        antes = len(PROGRESSO.read_text(encoding="utf-8"))
        print(f"\n[{datetime.now():%H:%M:%S}] Estudando {batch} (tentativa {st[batch]['tentativas']})...", flush=True)
        rc, out, err = rodar_claude(montar_prompt(batch, extra))
        saida = f"{out}\n{err}"
        erros = validar(batch, antes) if rc == 0 else [f"claude retornou código {rc}"]
        if not erros:
            st[batch]["status"] = "completed"; st[batch]["concluido_em"] = datetime.now().isoformat(timespec="seconds")
            save_state(st); print(f"[OK] {batch} concluído e validado", flush=True); return True
        restaurar()
        st[batch]["status"] = "pending"; save_state(st)
        if detectar_rate_limit(saida):
            reset = extrair_reset(saida)
            if reset:
                destino = reset + timedelta(minutes=MARGEM_MIN)
            else:
                m = ESPERAS_SEM_HORARIO[min(esp_idx, len(ESPERAS_SEM_HORARIO) - 1)]; esp_idx += 1
                destino = datetime.now() + timedelta(minutes=m)
            pausa(destino, batch); continue
        falhas += 1
        print(f"[FALHA] {batch}: {'; '.join(erros)}", flush=True)
        if saida.strip():
            print("  saída do claude (final):", saida.strip()[-400:].replace("\n", " "), flush=True)
        if falhas >= MAX_FALHAS_GENERICAS:
            st[batch]["status"] = "failed"; st[batch]["erro"] = "; ".join(erros); save_state(st)
            print(f"[FALHOU] {batch} marcado como failed após {falhas} tentativas; seguindo.", flush=True); return False
        extra = f"\nCORREÇÃO DA TENTATIVA ANTERIOR (corrija sem repetir): {'; '.join(erros)}\n"
        pausa(datetime.now() + timedelta(minutes=[1, 5][min(falhas - 1, 1)]), batch, "RETENTATIVA")


def selftest():
    agora = datetime(2026, 11, 17, 10, 0)
    casos = [("Claude usage limit reached. Your limit will reset at 3pm (America/Sao_Paulo)", True),
             ("5-hour limit reached ∙ resets 3:30pm", True), ("Rate limited, try again in 25 minutes", True),
             ("API Error: 429 Too Many Requests", True), ("overloaded_error", True), ("OK batch_001", False)]
    for t, esperado in casos:
        assert detectar_rate_limit(t) == esperado, t
    assert extrair_reset("resets 3:30pm", agora) == datetime(2026, 11, 17, 15, 30)
    assert extrair_reset("resets at 9am", agora) == datetime(2026, 11, 18, 9, 0)
    assert extrair_reset("try again in 1 hour and 5 minutes", agora) == datetime(2026, 11, 17, 11, 5)
    assert extrair_reset("try again in 25 minutes", agora) == datetime(2026, 11, 17, 10, 25)
    assert extrair_reset("429 too many requests", agora) is None
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only"); ap.add_argument("--max-batches", type=int, default=0)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest(); return
    st = load_state()
    if not st:
        sys.exit("Nenhum lote encontrado. Rode harvester.py primeiro.")
    garantir_saida()
    if any(b["status"] == "processing" for b in st.values()):  # queda anterior no meio do lote
        restaurar()
        for b in st.values():
            if b["status"] == "processing": b["status"] = "pending"
        save_state(st)
    fila = [n for n in sorted(st) if st[n]["status"] == "pending" and (not a.only or n == a.only)]
    if a.max_batches: fila = fila[:a.max_batches]
    print(f"[FILA] {len(fila)} lotes pendentes de {len(st)}", flush=True)
    try:
        for n in fila:
            processar_lote(n, st)
    except KeyboardInterrupt:
        print("\n[INTERROMPIDO] restaurando o último estado bom...")
        restaurar()
        for b in st.values():
            if b["status"] == "processing": b["status"] = "pending"
        save_state(st); sys.exit(130)
    res = {s: sum(1 for b in st.values() if b["status"] == s) for s in ("completed", "pending", "failed")}
    print(f"\n[FIM] {res}")


if __name__ == "__main__":
    main()
