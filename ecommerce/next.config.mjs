/** @type {import('next').NextConfig} */
const nextConfig = {
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
