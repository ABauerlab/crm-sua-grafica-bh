#!/usr/bin/env python3
"""Painel web local (http://localhost:8585): controla a esteira, mostra o status e exibe o conhecimento aprendido."""
import json, os, shutil, signal, subprocess, sys, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import runtime

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "output" / "conhecimento_grafica"
STATE = ROOT / "state"
LOG = STATE / "painel.log"
PORT = 8585

ABAS = [  # (id, título, arquivos)
    ("vendas", "Vendas e Prospecção", ["01_PLAYBOOK_VENDAS_E_ARGUMENTOS.md", "05_PROSPECCAO_E_NICHOS.md"]),
    ("atendimento", "Atendimento e Fechamento", ["09_ATENDIMENTO_E_FECHAMENTO.md"]),
    ("kits", "Kits por Nicho", ["06_KITS_E_COMBOS.md"]),
    ("objecoes", "Quebra de Objeções", ["07_VALOR_E_OBJECOES.md"]),
    ("upsell", "Upsell e Cross-sell", ["08_UPSELL_E_CROSS_SELL.md"]),
    ("captacao", "Captação e Marketing", ["10_CAPTACAO_E_MARKETING.md"]),
    ("papeis", "Papéis e Acabamentos", ["02_GUIA_PAPEL_E_ACABAMENTOS.md"]),
    ("arquivo", "Fechamento de Arquivo", ["03_MANUAL_FECHAMENTO_DE_ARQUIVO.md"]),
    ("catalogo", "Catálogo de Produtos", ["04_CATALOGO_APLICACOES_PRODUTOS.md"]),
    ("mestre", "Resumo Mestre", ["00_CONSCIENCIA_MESTRE_AGENTE.md"]),
    ("diario", "Diário do Estudo", ["PROGRESSO_ESTUDO.md"]),
]


def ler_md(nome):
    p = OUT / nome
    return p.read_text(encoding="utf-8") if p.exists() else ""


class Runner:
    def __init__(self):
        self.proc = None; self.thread = None; self.quer = False; self.rodando = False; self.pausado = False
        self.erro = ""; self.lock = threading.Lock()

    def iniciar(self):
        with self.lock:
            if self.rodando:
                return
            if not shutil.which("claude"):
                self.erro = "O Claude Code não foi encontrado neste computador. Instale e faça login uma vez (digite 'claude' no terminal)."
                return
            self.erro = ""; self.quer = True; self.pausado = False; self.rodando = True
            self.thread = threading.Thread(target=self._rodar, daemon=True); self.thread.start()

    def _rodar(self):
        STATE.mkdir(exist_ok=True)
        try:
            with open(LOG, "a", encoding="utf-8") as log:
                for script in ("harvester.py", "study_loop.py"):
                    if not self.quer:
                        break
                    kw = {"start_new_session": True} if os.name != "nt" else {"creationflags": 0x00000200}
                    env = dict(os.environ, PYTHONUTF8="1", PYTHONUNBUFFERED="1")
                    self.proc = subprocess.Popen([sys.executable, "-u", script], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env, **kw)
                    self.proc.wait()
        finally:
            self.rodando = False; self.proc = None
            if self.pausado:
                runtime.escrever(estado="pausado", retoma_as=None)

    def pausar(self):
        self.quer = False; self.pausado = True
        p = self.proc
        if p and p.poll() is None:
            try:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
                else:
                    os.killpg(p.pid, signal.SIGTERM)
            except Exception:
                pass


RUN = Runner()


def status():
    idx = {}
    try:
        idx = json.loads((STATE / "videos_index.json").read_text(encoding="utf-8"))
    except Exception:
        pass
    lotes = {}
    try:
        lotes = json.loads((STATE / "batches_state.json").read_text(encoding="utf-8"))
    except Exception:
        pass
    rt = runtime.ler()
    tipo = lambda v: idx.get(v, {}).get("tipo")
    est = [v for b in lotes.values() if b["status"] == "completed" for v in b["videos"]]
    cont = lambda st: sum(1 for b in lotes.values() if b["status"] == st)
    estado = rt.get("estado", "parado")
    if not RUN.rodando and estado not in ("pausado", "concluido"):
        estado = "parado"
    if RUN.pausado and not RUN.rodando:
        estado = "pausado"
    tail = []
    try:
        tail = LOG.read_text(encoding="utf-8", errors="replace").splitlines()[-8:]
    except Exception:
        pass
    return {
        "estado": estado, "rodando": RUN.rodando, "erro": RUN.erro,
        "detalhe": rt.get("detalhe", ""), "lote": rt.get("lote"), "itens": rt.get("itens", []) if estado in ("estudando", "aguardando_limite", "retentativa") else [],
        "retoma_as": rt.get("retoma_as"), "agora": time.time(),
        "videos": sum(1 for v in idx.values() if v["tipo"] == "video"), "shorts": sum(1 for v in idx.values() if v["tipo"] == "short"),
        "coletados": sum(1 for v in idx.values() if v["status"] in ("transcribed", "no_transcript")),
        "estudados_videos": sum(1 for v in est if tipo(v) == "video"), "estudados_shorts": sum(1 for v in est if tipo(v) == "short"),
        "lotes": {"total": len(lotes), "concluidos": cont("completed"), "pendentes": cont("pending"), "falhos": cont("failed")},
        "ffmpeg": bool(shutil.which("ffmpeg")), "log": tail,
        "versao_conteudo": sum(int((OUT / n).stat().st_mtime) for _, _, fs in ABAS for n in fs if (OUT / n).exists()),
    }


def conteudo():
    return {"abas": [{"id": i, "titulo": t, "md": "\n\n---\n\n".join(x for x in (ler_md(n) for n in fs) if x.strip())} for i, t, fs in ABAS]}


def download_completo():
    partes = ["# Conhecimento completo: Sua Gráfica BH\n"]
    for _, t, fs in ABAS:
        for n in fs:
            md = ler_md(n)
            if md.strip():
                partes.append(f"\n\n\n{md.strip()}\n")
    return "\n".join(partes).encode("utf-8")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _ok_host(self):
        return self.headers.get("Host", "").split(":")[0] in ("localhost", "127.0.0.1")

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        if not self._ok_host():
            return self._send(403, "{}")
        path = self.path.split("?")[0]
        if path == "/":
            return self._send(200, (ROOT / "painel.html").read_text(encoding="utf-8"), "text/html; charset=utf-8")
        if path == "/api/status":
            return self._send(200, json.dumps(status(), ensure_ascii=False))
        if path == "/api/conteudo":
            return self._send(200, json.dumps(conteudo(), ensure_ascii=False))
        if path == "/api/download":
            return self._send(200, download_completo(), "text/markdown; charset=utf-8",
                              {"Content-Disposition": 'attachment; filename="conhecimento_completo_sua_grafica_bh.md"'})
        self._send(404, "{}")

    def do_POST(self):
        if not self._ok_host() or self.headers.get("X-Painel") != "1":
            return self._send(403, "{}")
        if self.path == "/api/iniciar":
            RUN.iniciar()
        elif self.path == "/api/pausar":
            RUN.pausar()
        else:
            return self._send(404, "{}")
        self._send(200, json.dumps({"ok": True}))


def manter_acordado():
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)
        except Exception:
            pass


def main(abrir=True):
    os.chdir(ROOT); manter_acordado()
    url = f"http://localhost:{PORT}"
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    except OSError:
        print(f"O painel já está aberto em {url}")
        if abrir: webbrowser.open(url)
        return
    # quedas anteriores: lotes "processing" voltam a pending ao iniciar a esteira (study_loop faz isso)
    print(f"Painel rodando em {url}  (feche esta janela para encerrar)")
    if abrir:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        RUN.pausar()


if __name__ == "__main__":
    main(abrir="--sem-navegador" not in sys.argv)
