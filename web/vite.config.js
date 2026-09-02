import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Project Pages is served at /NotchFlow/, while local Vite development
  // remains available at the root URL used by `npm run dev`.
  base: process.env.GITHUB_ACTIONS ? '/NotchFlow/' : '/',
})
