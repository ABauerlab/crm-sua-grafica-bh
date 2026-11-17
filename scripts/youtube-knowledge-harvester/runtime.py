"""Estado em tempo real da esteira (lido pelo painel). Gravação atômica em state/runtime.json."""
import json, time
from pathlib import Path

ARQ = Path(__file__).resolve().parent / "state" / "runtime.json"


def ler():
    try:
        return json.loads(ARQ.read_text(encoding="utf-8"))
    except Exception:
        return {}


def escrever(**kw):
    d = ler(); d.update(kw); d["atualizado_em"] = time.time()
    ARQ.parent.mkdir(parents=True, exist_ok=True)
    tmp = ARQ.with_suffix(".tmp"); tmp.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8"); tmp.replace(ARQ)
