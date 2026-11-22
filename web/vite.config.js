import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
// GitHub Pages serves public/privacy/index.html at /privacy/, but Vite's dev
// and preview servers answer that URL with the single-page app instead, so the
// site's Privacy links opened the home page locally. Serve the page the same
// way Pages does. `/privacy` redirects to `/privacy/` so the page's relative
// links (styles.css, ../icon.png) resolve.
function privacyPage() {
  const route = (req, res, next) => {
    const [path, query = ''] = (req.url ?? '').split('?')
    // `/privacy` and any stacked `/privacy/privacy/…` (left behind by the old
    // relative links) go to the one real page; its own files pass through.
    const stacked = path.startsWith('/privacy/') && path !== '/privacy/' && !/\.[a-z0-9]+$/i.test(path)
    if (path === '/privacy' || stacked) {
      res.statusCode = 302
      res.setHeader('Location', '/privacy/' + (query ? `?${query}` : ''))
      res.end()
      return
    }
    if (path === '/privacy/') req.url = '/privacy/index.html' + (query ? `?${query}` : '')
    next()
  }
  return {
    name: 'privacy-page',
    configureServer(server) { server.middlewares.use(route) },
    configurePreviewServer(server) { server.middlewares.use(route) },
  }
}

export default defineConfig({
  plugins: [react(), privacyPage()],
  // Project Pages is served at /NotchFlow/, while local Vite development
  // remains available at the root URL used by `npm run dev`.
  base: process.env.GITHUB_ACTIONS ? '/NotchFlow/' : '/',
})
