#!/usr/bin/env python3
"""Um clique: prepara tudo e roda coleta + estudo do canal inteiro. Chamado por RODAR_TUDO.bat / rodar_tudo.sh."""
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
    passo("1/4 Configuração")
    cfg = ROOT / "config.local.json"
    if not cfg.exists():
        cfg.write_text(json.dumps({"canal": CANAL_PADRAO, "idiomas": ["pt", "pt-BR", "en"],
                                   "cookies_do_navegador": "auto", "whisper_modelo": "small",
                                   "tamanho_lote": 15}, indent=2), encoding="utf-8")
        print("config.local.json criado automaticamente.")
    else:
        print("config.local.json já existe.")

    passo("2/4 Dependências")
    marca = ROOT / "state" / ".deps_ok"
    if not marca.exists():
        if rodar(["-m", "pip", "install", "-r", "requirements.txt"]) != 0:
            sys.exit("Falha ao instalar as dependências. Veja a mensagem acima.")
        marca.parent.mkdir(exist_ok=True); marca.write_text("ok")
    else:
        print("já instaladas.")
    if not shutil.which("claude"):
        sys.exit("O comando 'claude' (Claude Code) não foi encontrado. Instale e faça login uma vez (abra o terminal e digite: claude).")
    if not shutil.which("ffmpeg"):
        print("Aviso: ffmpeg não encontrado. Vídeos sem legenda ficarão sem transcrição por áudio. Instale o ffmpeg para cobrir tudo.")

    passo("3/4 Coleta do canal inteiro (vídeos e Shorts)")
    if rodar(["harvester.py"]) != 0:
        print("A coleta terminou com avisos; seguindo para o estudo com o que foi coletado.")

    passo("4/4 Estudo com o Claude (espera sozinho se o limite da assinatura acabar)")
    code = rodar(["study_loop.py"])
    passo("FIM" if code == 0 else "ENCERRADO")
    print("Resultado em: output/conhecimento_grafica/  (comece por LEIA_PRIMEIRO_INDICE.md)")
    sys.exit(code)


if __name__ == "__main__":
    main()
