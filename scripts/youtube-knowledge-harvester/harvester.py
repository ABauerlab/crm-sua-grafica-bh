#!/usr/bin/env python3
"""Fase 1: coletor turbo. Indexa o canal, baixa transcrições e monta lotes de 15 vídeos.

Uso:
  python3 harvester.py                       # canal inteiro (videos + shorts)
  python3 harvester.py --limit-videos 15 --limit-shorts 15
O canal vem de config.local.json (ignorado pelo git, por causa do sigilo do fornecedor)
ou da variável HARVEST_CHANNEL.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATE = ROOT / "state"
DATA = ROOT / "data"
TRANSCRIPTS = DATA / "transcripts"
BATCHES = DATA / "batches"
FRAMES = DATA / "frames"
INDEX_FILE = STATE / "videos_index.json"
BATCHES_FILE = STATE / "batches_state.json"


def load_config():
    cfg = {"canal": os.environ.get("HARVEST_CHANNEL", ""), "idiomas": ["pt", "pt-BR", "en"],
           "whisper_modelo": "small", "tamanho_lote": 15}
    p = ROOT / "config.local.json"
    if p.exists():
        cfg.update(json.loads(p.read_text(encoding="utf-8")))
    if os.environ.get("HARVEST_CHANNEL"):
        cfg["canal"] = os.environ["HARVEST_CHANNEL"]
    if not cfg["canal"]:
        sys.exit("Defina o canal em config.local.json ou na variável HARVEST_CHANNEL.")
    cfg["canal"] = cfg["canal"].rstrip("/")
    return cfg


def load_json(path, default):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return default


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)  # gravação atômica


COOKIES = []  # preenchido por main() a partir de "cookies_do_navegador" (ex.: "chrome")


def run(cmd, timeout=600):
    if cmd and cmd[0] == "yt-dlp":
        cmd = cmd[:1] + COOKIES + cmd[1:]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ---------------------------------------------------------------- índice
def indexar(cfg, limites):
    index = load_json(INDEX_FILE, {})
    for tipo, aba in (("video", "videos"), ("short", "shorts")):
        cmd = ["yt-dlp", "--flat-playlist", "--ignore-errors", "--print",
               "%(id)s\t%(title)s\t%(duration)s\t%(url)s"]
        if limites.get(tipo):
            cmd += ["--playlist-end", str(limites[tipo])]
        cmd.append(f"{cfg['canal']}/{aba}")
        r = run(cmd, timeout=900)
        novos = 0
        for linha in r.stdout.splitlines():
            partes = linha.split("\t")
            if len(partes) < 2 or not re.fullmatch(r"[\w-]{11}", partes[0]):
                continue
            vid = partes[0]
            if vid in index:
                continue
            dur = partes[2] if len(partes) > 2 and partes[2] not in ("NA", "") else None
            index[vid] = {"video_id": vid, "url": f"https://www.youtube.com/watch?v={vid}",
                          "titulo": partes[1], "tipo": tipo,
                          "duracao": int(float(dur)) if dur else None, "status": "indexed"}
            novos += 1
        print(f"[indice] {aba}: {novos} novos (total {len(index)})")
        if r.returncode != 0 and not r.stdout:
            print(f"[indice] aviso em {aba}: {r.stderr.strip()[-300:]}")
    save_json(INDEX_FILE, index)
    return index


# ---------------------------------------------------------------- transcrição
def limpar_texto(trechos):
    """Texto corrido: junta tudo, tira marcadores e repetições de linha, parágrafos a cada ~5 frases."""
    texto = " ".join(t.strip() for t in trechos if t and t.strip())
    texto = re.sub(r"\[[^\]]{0,30}\]", " ", texto)  # [Música], [Applause]
    texto = re.sub(r"\s+", " ", texto).strip()
    frases = re.split(r"(?<=[.!?])\s+", texto)
    paragrafos, atual = [], []
    for f in frases:
        atual.append(f)
        if len(atual) >= 5:
            paragrafos.append(" ".join(atual)); atual = []
    if atual:
        paragrafos.append(" ".join(atual))
    return "\n\n".join(paragrafos)


def dedup_vtt(vtt):
    """VTT automático repete cada linha várias vezes; mantém só a sequência nova."""
    linhas, ultimo = [], ""
    for l in vtt.splitlines():
        l = re.sub(r"<[^>]+>", "", l).strip()
        if not l or "-->" in l or l.startswith(("WEBVTT", "Kind:", "Language:", "NOTE")):
            continue
        if l == ultimo:
            continue
        linhas.append(l); ultimo = l
    return linhas


def transcript_api(vid, idiomas):
    try:
        from youtube_transcript_api import YouTubeTranscriptApi
        api = YouTubeTranscriptApi()
        lista = api.list(vid)
        todos = list(lista)
        escolha = None
        for pref in idiomas:
            for t in todos:
                if t.language_code.lower().startswith(pref.lower().split("-")[0]):
                    escolha = t; break
            if escolha:
                break
        escolha = escolha or (todos[0] if todos else None)
        if not escolha:
            return None
        dados = escolha.fetch()
        return {"idioma": escolha.language_code, "origem": "youtube-transcript-api",
                "texto": limpar_texto([s.text for s in dados])}
    except Exception as e:  # sem legenda, bloqueio de IP etc.
        return {"erro": f"{type(e).__name__}"}


def transcript_ytdlp(vid, idiomas):
    with tempfile.TemporaryDirectory() as tmp:
        langs = ",".join([f"{i}.*" for i in idiomas] + ["en.*"])
        r = run(["yt-dlp", "--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", langs,
                 "--sub-format", "vtt", "-o", f"{tmp}/s", f"https://www.youtube.com/watch?v={vid}"], 180)
        arqs = sorted(Path(tmp).glob("s.*.vtt"))
        if not arqs:
            return None
        escolha = next((a for i in idiomas for a in arqs if f".{i.split('-')[0].lower()}" in a.name.lower()), arqs[0])
        idioma = escolha.name.split(".")[-2]
        return {"idioma": idioma, "origem": "yt-dlp-legenda",
                "texto": limpar_texto(dedup_vtt(escolha.read_text(encoding="utf-8", errors="ignore")))}


def transcript_whisper(vid, cfg):
    """Fallback: baixa só o áudio leve, transcreve localmente e apaga o áudio."""
    with tempfile.TemporaryDirectory() as tmp:
        r = run(["yt-dlp", "-f", "worstaudio/worst", "-x", "--audio-format", "mp3", "--audio-quality", "9",
                 "-o", f"{tmp}/a.%(ext)s", f"https://www.youtube.com/watch?v={vid}"], 900)
        audio = next(Path(tmp).glob("a.*"), None)
        if not audio:
            return None
        from faster_whisper import WhisperModel
        modelo = WhisperModel(cfg["whisper_modelo"], device="cpu", compute_type="int8")
        segs, info = modelo.transcribe(str(audio), vad_filter=True)
        texto = limpar_texto([s.text for s in segs])
        return {"idioma": info.language, "origem": "faster-whisper", "texto": texto} if texto else None
    # o diretório temporário (e o áudio) some ao sair do bloco


def metadados(vid):
    r = run(["yt-dlp", "--skip-download", "--no-warnings", "-J", f"https://www.youtube.com/watch?v={vid}"], 180)
    if r.returncode != 0 or not r.stdout.strip():
        return {}
    j = json.loads(r.stdout)
    return {"descricao": j.get("description") or "", "capitulos": [
        {"inicio": int(c.get("start_time", 0)), "titulo": c.get("title", "")} for c in (j.get("chapters") or [])],
        "duracao": j.get("duration"), "data": j.get("upload_date")}


def extrair_frames(vid, duracao):
    """3 a 4 frames-chave de tutorial curto sem legenda clara, para inspeção visual."""
    if not shutil.which("ffmpeg"):
        return []
    destino = FRAMES / vid
    destino.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        run(["yt-dlp", "-f", "worst[ext=mp4]/worst", "-o", f"{tmp}/v.%(ext)s",
             f"https://www.youtube.com/watch?v={vid}"], 600)
        video = next(Path(tmp).glob("v.*"), None)
        if not video:
            return []
        dur = max(int(duracao or 60), 8)
        for n, frac in enumerate((0.1, 0.35, 0.6, 0.85), 1):
            run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(int(dur * frac)), "-i", str(video),
                 "-frames:v", "1", "-vf", "scale=720:-2", str(destino / f"frame_{n}.jpg")], 120)
    return sorted(str(p.relative_to(ROOT)) for p in destino.glob("frame_*.jpg"))


def processar(item, cfg):
    vid = item["video_id"]
    saida = TRANSCRIPTS / f"{vid}.md"
    if saida.exists() and item["status"] in ("transcribed", "no_transcript"):
        return item
    meta = metadados(vid)
    if meta.get("duracao"):
        item["duracao"] = int(meta["duracao"])
    t = transcript_api(vid, cfg["idiomas"])
    if not t or "texto" not in t or len(t["texto"]) < 40:
        t = transcript_ytdlp(vid, cfg["idiomas"])
    if not t or len(t.get("texto", "")) < 40:
        try:
            t = transcript_whisper(vid, cfg)
        except Exception as e:
            print(f"[whisper] {vid}: {type(e).__name__}: {e}")
            t = None
    frames = []
    clara = bool(t and len(t["texto"]) >= 200)
    if not clara and (item.get("duracao") or 0) <= 240:
        frames = extrair_frames(vid, item.get("duracao"))
    cab = [f"# {item['titulo']}", "",
           f"- video_id: {vid}", f"- tipo: {item['tipo']}", f"- duracao_s: {item.get('duracao')}",
           f"- publicado: {meta.get('data') or 'n/d'}",
           f"- fonte_transcricao: {t['origem'] + ' (' + t['idioma'] + ')' if t else 'nenhuma'}", ""]
    if meta.get("descricao"):
        cab += ["## Descrição", "", meta["descricao"].strip(), ""]
    if meta.get("capitulos"):
        cab += ["## Capítulos", ""] + [f"- {c['inicio']//60}:{c['inicio']%60:02d} {c['titulo']}" for c in meta["capitulos"]] + [""]
    cab += ["## Transcrição", "", t["texto"] if t else "(sem transcrição disponível)", ""]
    if frames:
        cab += ["## Frames-chave (para inspeção visual)", ""] + [f"- {f}" for f in frames] + [""]
    TRANSCRIPTS.mkdir(parents=True, exist_ok=True)
    saida.write_text("\n".join(cab), encoding="utf-8")
    item["status"] = "transcribed" if t else ("no_transcript" if meta.get("descricao") or frames else "failed")
    item["fonte"] = t["origem"] if t else None
    item["frames"] = bool(frames)
    return item


# ---------------------------------------------------------------- lotes
def montar_lotes(index, tamanho):
    estado = load_json(BATCHES_FILE, {})
    ja = {v for b in estado.values() for v in b["videos"]}
    prontos = [v for v in index.values()
               if v["status"] in ("transcribed", "no_transcript") and v["video_id"] not in ja]
    prontos.sort(key=lambda v: (v["tipo"] != "video",))  # vídeos antes de Shorts, ordem do canal preservada
    BATCHES.mkdir(parents=True, exist_ok=True)
    n = len(estado)
    for i in range(0, len(prontos), tamanho):
        grupo = prontos[i:i + tamanho]
        n += 1
        nome = f"batch_{n:03d}"
        partes = [f"# {nome}: {len(grupo)} itens para estudo\n"]
        for v in grupo:
            partes.append(f"\n\n<!-- ITEM {v['video_id']} -->\n" + (TRANSCRIPTS / f"{v['video_id']}.md").read_text(encoding="utf-8"))
        (BATCHES / f"{nome}.md").write_text("".join(partes), encoding="utf-8")
        estado[nome] = {"status": "pending", "videos": [v["video_id"] for v in grupo],
                        "titulos": [v["titulo"] for v in grupo], "tentativas": 0}
        print(f"[lotes] {nome} criado com {len(grupo)} itens")
    save_json(BATCHES_FILE, estado)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit-videos", type=int, default=0)
    ap.add_argument("--limit-shorts", type=int, default=0)
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    cfg = load_config()
    if cfg.get("cookies_do_navegador"):  # só se o YouTube pedir "confirm you're not a bot"
        COOKIES[:] = ["--cookies-from-browser", cfg["cookies_do_navegador"]]
    index = indexar(cfg, {"video": a.limit_videos, "short": a.limit_shorts})
    alvo = [v for v in index.values() if v["status"] in ("indexed", "failed")]
    if a.limit_videos or a.limit_shorts:  # modo teste: só os dois recortes pedidos
        cont = {"video": 0, "short": 0}; sel = []
        lim = {"video": a.limit_videos, "short": a.limit_shorts}
        for v in alvo:
            if lim[v["tipo"]] and cont[v["tipo"]] < lim[v["tipo"]]:
                sel.append(v); cont[v["tipo"]] += 1
        alvo = sel
    print(f"[coleta] {len(alvo)} itens para baixar")
    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        for i, r in enumerate(ex.map(lambda it: processar(it, cfg), alvo), 1):
            index[r["video_id"]] = r
            print(f"  [{i}/{len(alvo)}] {r['video_id']} {r['status']} ({r.get('fonte')})")
            if i % 10 == 0:
                save_json(INDEX_FILE, index)
    save_json(INDEX_FILE, index)
    montar_lotes(index, cfg["tamanho_lote"])


if __name__ == "__main__":
    main()
