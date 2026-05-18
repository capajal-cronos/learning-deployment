import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite is our build tool. It bundles React into a small static folder (`dist/`)
// that Express then serves in production.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // In `npm run dev`, the browser hits Vite directly. We proxy /api to the
    // backend so we don't have to hardcode the backend URL in the React code.
    proxy: {
      "/api": {
        target: "http://localhost:8000",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
  },
});
