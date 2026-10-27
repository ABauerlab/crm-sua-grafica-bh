/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        display: ['Inter', 'system-ui', 'sans-serif'],
      },
      colors: {
        border: 'hsl(var(--border))',
        input: 'hsl(var(--input))',
        ring: 'hsl(var(--ring))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: { DEFAULT: 'hsl(var(--primary))', foreground: 'hsl(var(--primary-foreground))' },
        secondary: { DEFAULT: 'hsl(var(--secondary))', foreground: 'hsl(var(--secondary-foreground))' },
        muted: { DEFAULT: 'hsl(var(--muted))', foreground: 'hsl(var(--muted-foreground))' },
        accent: { DEFAULT: 'hsl(var(--accent))', foreground: 'hsl(var(--accent-foreground))' },
        destructive: { DEFAULT: 'hsl(var(--destructive))', foreground: 'hsl(var(--destructive-foreground))' },
        card: { DEFAULT: 'hsl(var(--card))', foreground: 'hsl(var(--card-foreground))' },
        success: 'hsl(var(--success))',
        warning: 'hsl(var(--warning))',
        link: 'hsl(var(--link))',
        sidebar: { DEFAULT: 'hsl(var(--sidebar))', foreground: 'hsl(var(--sidebar-foreground))' },
        ink: 'rgb(var(--brand-ink-rgb) / <alpha-value>)',
        brand: {
          cyan: 'rgb(var(--brand-cyan-rgb) / <alpha-value>)',
          magenta: 'rgb(var(--brand-magenta-rgb) / <alpha-value>)',
          yellow: 'rgb(var(--brand-yellow-rgb) / <alpha-value>)',
          blue: 'rgb(var(--brand-blue-rgb) / <alpha-value>)',
          green: 'rgb(var(--brand-green-rgb) / <alpha-value>)',
          red: 'rgb(var(--brand-red-rgb) / <alpha-value>)',
          gray: 'rgb(var(--brand-gray-rgb) / <alpha-value>)',
        },
      },
      borderRadius: { lg: 'var(--radius)', md: 'calc(var(--radius) - 1px)', sm: 'calc(var(--radius) - 2px)' },
    },
  },
  plugins: [],
}
