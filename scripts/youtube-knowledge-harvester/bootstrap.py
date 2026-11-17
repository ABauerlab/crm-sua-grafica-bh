#!/usr/bin/env python3
"""Um clique: prepara tudo e abre o painel em http://localhost:8585. Chamado por RODAR_TUDO.bat / rodar_tudo.sh."""
import json, shutil, subprocess, sys, os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
os.chdir(ROOT)
CANAL_PADRAO = "https://www.youtube.com/@zapgrafica"


def passo(msg):
    print(f"\n=== {msg} ===", flush=True)


def manter_pc_acordado():
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        except Exception:
            pass


def rodar(args):
    return subprocess.run([sys.executable, *args]).returncode


def main():
    manter_pc_acordado()
    passo("1/3 Configuração")
    cfg = ROOT / "config.local.json"
    if not cfg.exists():
        cfg.write_text(json.dumps({"canal": CANAL_PADRAO, "idiomas": ["pt", "pt-BR", "en"],
                                   "cookies_do_navegador": "auto", "whisper_modelo": "small",
                                   "tamanho_lote": 15}, indent=2), encoding="utf-8")
        print("config.local.json criado automaticamente.")
    else:
        print("config.local.json já existe.")

    passo("2/3 Dependências")
    marca = ROOT / "state" / ".deps_ok"
    if not marca.exists():
        if rodar(["-m", "pip", "install", "-r", "requirements.txt"]) != 0:
            sys.exit("Falha ao instalar as dependências. Veja a mensagem acima.")
        marca.parent.mkdir(exist_ok=True); marca.write_text("ok")
    else:
        print("já instaladas.")
    if not shutil.which("claude"):
        print("Aviso: o Claude Code não foi encontrado. O painel abre, mas o estudo só inicia depois de instalar e fazer login (digite: claude).")
    if not shutil.which("ffmpeg"):
        print("Aviso: ffmpeg não encontrado. Vídeos sem legenda ficarão sem transcrição por áudio. Instale o ffmpeg para cobrir tudo.")

    passo("3/3 Abrindo o painel")
    import app
    app.main(abrir=True)


if __name__ == "__main__":
    main()
