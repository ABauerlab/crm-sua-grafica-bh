const KEY = 'sgbh.sound'

export function soundEnabled(): boolean {
  try {
    return localStorage.getItem(KEY) !== '0'
  } catch {
    return true
  }
}

export function setSoundEnabled(on: boolean) {
  try {
    localStorage.setItem(KEY, on ? '1' : '0')
  } catch {
    /* sem armazenamento */
  }
}

let ctx: AudioContext | null = null

/** Bipe curto para mensagem nova (Web Audio, sem arquivo). Silencioso se o navegador ainda não liberou áudio. */
export function notifyInbound() {
  if (!soundEnabled()) return
  try {
    ctx ??= new AudioContext()
    if (ctx.state === 'suspended') void ctx.resume()
    const t = ctx.currentTime
    for (const [i, f] of [880, 1175].entries()) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.type = 'sine'
      osc.frequency.value = f
      gain.gain.setValueAtTime(0.0001, t + i * 0.12)
      gain.gain.exponentialRampToValueAtTime(0.15, t + i * 0.12 + 0.02)
      gain.gain.exponentialRampToValueAtTime(0.0001, t + i * 0.12 + 0.18)
      osc.connect(gain).connect(ctx.destination)
      osc.start(t + i * 0.12)
      osc.stop(t + i * 0.12 + 0.2)
    }
  } catch {
    /* áudio indisponível */
  }
}
