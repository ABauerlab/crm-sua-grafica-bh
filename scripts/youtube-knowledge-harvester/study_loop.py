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
TEMAS = {
    "LEIA_PRIMEIRO_INDICE.md": ("Leia primeiro: índice do conhecimento", "Mapa de todos os arquivos, com o que cada um contém."),
    "01_PLAYBOOK_VENDAS_E_ARGUMENTOS.md": ("Playbook de vendas: visão geral", "Mentalidade e princípios do vendedor mestre de gráfica."),
    "02_GUIA_PAPEL_E_ACABAMENTOS.md": ("Guia de papéis e acabamentos", "Gramaturas, papéis e enobrecimentos em linguagem comercial."),
    "03_MANUAL_FECHAMENTO_DE_ARQUIVO.md": ("Manual de fechamento de arquivo", "Regras de pré-impressão e exportação."),
    "04_CATALOGO_APLICACOES_PRODUTOS.md": ("Catálogo de aplicações de produtos", "Ficha consultiva de cada produto gráfico."),
    "05_PROSPECCAO_E_NICHOS.md": ("Prospecção e nichos de cliente", "Como abordar cada nicho e o que oferecer a ele."),
    "06_KITS_E_COMBOS.md": ("Kits e combos de produtos", "Kits por ocasião e por nicho, como montar e apresentar."),
    "07_VALOR_E_OBJECOES.md": ("Argumentação de valor e quebra de objeções", "Vender valor em vez de preço e contornar objeções."),
    "08_UPSELL_E_CROSS_SELL.md": ("Upsell e cross-sell", "Como aumentar o pedido com acabamento e produtos complementares."),
    "09_ATENDIMENTO_E_FECHAMENTO.md": ("Atendimento, follow-up e fechamento", "Abordagem, qualificação, orçamento consultivo, follow-up, fechamento e pós-venda."),
    "10_CAPTACAO_E_MARKETING.md": ("Captação de clientes e marketing", "Funil, anúncios, conteúdo e relacionamento para atrair clientes."),
    "00_CONSCIENCIA_MESTRE_AGENTE.md": ("Consciência mestre do agente", "Versão consolidada e densa de tudo."),
    "PROGRESSO_ESTUDO.md": ("Progresso do estudo", "Diário incremental. Cada lote vira uma seção `## batch_XXX`."),
}
ARQUIVOS = list(TEMAS)
TIMEOUT_LOTE = 45 * 60
ESPERAS_SEM_HORARIO = [15, 30, 60]  # minutos; depois repete 60
MARGEM_MIN = 2
MAX_FALHAS_GENERICAS = 3

# Termos que nunca podem aparecer no conhecimento (white-label e regras do projeto).
PROIBIDOS = [r"zap\s*gr[aá]fica", r"\bzap\b", r"zap\s*go", r"parque\s+gr[aá]fico", r"checagem\s+garantida",
             r"zapgrafica", r"\bhubz\b", "—", "–"]

RATE_RE = re.compile(r"rate.?limit|usage.?limit|limit reached|limit will reset|resets?\s+(at|in)|too many requests|"
                     r"\b429\b|overloaded|quota|try again (in|later)|5-hour limit|weekly limit", re.I)

SEED = {n: f"# {t}\n\n{d}\n" for n, (t, d) in TEMAS.items()}


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
    lista = "\n".join(f"- {n}: {d}" for n, (t, d) in TEMAS.items() if n != "PROGRESSO_ESTUDO.md")
    return f"""Você é um vendedor mestre de gráfica rápida e consultor especialista da Sua Gráfica BH (Belo Horizonte). Está estudando um material para treinar o agente de WhatsApp da empresa a vender como um profissional de alto nível.

TAREFA: leia o arquivo data/batches/{batch}.md (ferramenta Read; se for grande, leia em partes). Cada item é um vídeo ou Short com título, descrição, capítulos e transcrição. Itens com "## Frames-chave" listam imagens em data/frames/: abra-as com Read.
Depois atualize de forma INCREMENTAL (Read/Edit/Write) os arquivos de output/conhecimento_grafica/, um tema por arquivo:
{lista}

FOCO: ABSORVER 100% DO CONTEÚDO DE VENDAS. O material ensina o revendedor a vender material gráfico ao cliente dele: prospectar nichos (restaurantes, clínicas, eventos, lojas, imobiliárias etc.), montar kits, argumentar valor em vez de preço, fazer upsell e cross-sell, contornar objeções, conduzir o atendimento e fechar pedidos. Quando o vídeo ensina o revendedor a vender, a técnica vale INTEGRALMENTE para a Sua Gráfica BH vendendo ao seu cliente: absorva tudo, sem descartar nada comercial por "ser para revendedor". Só ignore a divulgação da plataforma ou da marca do canal e instruções de como usar as ferramentas dele.
Capture o máximo de detalhe útil: o passo a passo de cada técnica, as perguntas de qualificação, exemplos de frases e mensagens de WhatsApp (adapte para o tom da Sua Gráfica BH), os argumentos por nicho, os kits (o que entra em cada um e para quem), as respostas para cada objeção, os gatilhos de upsell e cross-sell, o momento certo de cada passo.

FORMATO (o dono vai ler e revisar tudo antes de usar): cada arquivo organizado por temas com títulos `##` claros, bullets curtos, e quando fizer sentido os rótulos "Quando usar:", "Como fazer:" e "Exemplo de fala:". Português do Brasil, simples e direto. No topo de cada arquivo mantenha um resumo de poucas linhas. Mantenha o LEIA_PRIMEIRO_INDICE.md com a lista dos arquivos e o que há em cada seção.
- 00_CONSCIENCIA_MESTRE_AGENTE.md: reescreva ao final do lote, consolidando o melhor de todos os arquivos, enxuto e denso, sem perder nada que já havia.
- PROGRESSO_ESTUDO.md: acrescente no FIM uma seção que comece exatamente com a linha `## {batch}`, com data, títulos lidos e novos aprendizados.

REGRAS DE ATUALIZAÇÃO
- Não apague o que já foi aprendido e não duplique tópicos: se o assunto existe, complemente a seção existente. Se o lote não trouxer nada para um tema, deixe o arquivo como está, mas registre o lote no PROGRESSO_ESTUDO.md.
- Tom de consultor da Sua Gráfica BH atendendo o cliente final. Troque qualquer menção ao canal, marca ou plataforma de origem por linguagem neutra ou "a Sua Gráfica BH".

HIGIENE OBRIGATÓRIA (o lote é rejeitado se violar)
- Nunca escreva "Zap", "Zap Gráfica", "Zap GO", "Parque Gráfico", "Checagem Garantida" nem o nome do canal ou da plataforma de origem.
- Nunca use travessão (— ou –). Use vírgula, ponto ou dois-pontos.
- Registre a TÉCNICA, mas não copie valores em reais, prazos, fretes, percentuais de desconto ou margens citados nos vídeos: preço, prazo, frete e desconto são decididos só pelo sistema da empresa. Não cite SKU, fornecedor, endereço de fábrica nem concorrentes pelo nome.
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
    exe = shutil.which("claude")
    if not exe:
        return 127, "", "comando claude não encontrado no PATH"
    cmd = [exe, "-p", "--allowedTools", "Read,Write,Edit", "--permission-mode", "acceptEdits"]
    try:
        r = subprocess.run(cmd, cwd=ROOT, input=prompt, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=TIMEOUT_LOTE)
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
