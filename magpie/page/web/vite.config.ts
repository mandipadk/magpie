import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// Built into ../dist, which server.mjs serves next to its API.
export default defineConfig({
  plugins: [react()],
  build: { outDir: "../dist", emptyOutDir: true, assetsInlineLimit: 0 },
  server: { proxy: { "/api": "http://127.0.0.1:8790" } },
})
