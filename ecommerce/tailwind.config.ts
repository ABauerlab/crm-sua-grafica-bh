import type { Config } from 'tailwindcss'

// Cores da marca (CMY + preto): referências do brandkit da Sua Gráfica BH
export default {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        tinta: '#0b0b0f',
        magenta: { DEFAULT: '#e6007e', escuro: '#b80064' },
        amarelo: { DEFAULT: '#ffd400', escuro: '#e6be00' },
        ciano: { DEFAULT: '#00a3e0' },
        papel: '#f6f6f4',
      },
      fontFamily: { sans: ['var(--fonte)', 'system-ui', 'sans-serif'] },
      borderRadius: { xl2: '1.25rem' },
    },
  },
  plugins: [],
} satisfies Config
