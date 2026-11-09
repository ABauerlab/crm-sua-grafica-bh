import path from 'node:path'
import { fileURLToPath } from 'node:url'

/** @type {import('next').NextConfig} */
const nextConfig = {
  // A pasta ecommerce/ vive dentro do repositório do CRM (que tem outro package-lock): fixa a raiz do rastreio aqui.
  outputFileTracingRoot: path.dirname(fileURLToPath(import.meta.url)),
  // Hostinger (Node.js): `npm run build` e `npm start` com Base Directory = ecommerce/
  poweredByHeader: false,
  images: {
    remotePatterns: [{ protocol: 'https', hostname: 'bhlosshvwmlyzhbghsrc.supabase.co', pathname: '/storage/v1/object/**' }],
  },
  async headers() {
    return [{
      source: '/:path*',
      headers: [
        { key: 'X-Content-Type-Options', value: 'nosniff' },
        { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
        { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
        { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
      ],
    }]
  },
}
export default nextConfig
