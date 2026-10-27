/** Atraso progressivo no login: a partir da 3ª falha seguida, 10s, 20s, 40s... até 5 min. */
export function lockSeconds(fails: number): number {
  return fails < 3 ? 0 : Math.min(300, 10 * 2 ** (fails - 3))
}
