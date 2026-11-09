import type { Config } from 'tailwindcss'

// Cores da marca (CMY + preto): referências do brandkit da Sua Gráfica BH
export default {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        tinta: '#0b0b0f',
        magenta: { DEFAULT: '#E6007E', escuro: '#B80064' },
        amarelo: { DEFAULT: '#FFD500', escuro: '#E6BF00' },
        ciano: { DEFAULT: '#00A6D6' },
        papel: '#f6f6f4',
      },
      fontFamily: { sans: ['var(--fonte)', 'system-ui', 'sans-serif'] },
      borderRadius: { xl2: '1.25rem' },
    },
  },
  plugins: [],
} satisfies Config
