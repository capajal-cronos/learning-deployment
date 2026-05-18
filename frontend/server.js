// =============================================================================
// Express server for the React frontend.
//
// In development:
//   - Vite serves the React app on :5173 with hot-reload.
// In production / Docker:
//   - `vite build` produces /app/dist (static HTML/JS/CSS).
//   - This Express server serves those static files AND proxies /api/* to the
//     backend so the browser only ever sees one origin.
//
// WHY use Express if the React app is just static files?
//   1. The API proxy. The browser never learns the backend's URL.
//   2. Centralized logging, security headers, and health checks.
//   3. It's a clean place to add SSR or feature flags later.
// =============================================================================

import express from "express";
import morgan from "morgan";
import { createProxyMiddleware } from "http-proxy-middleware";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.PORT || 3000);
const BACKEND_URL = process.env.BACKEND_URL || "http://backend:8000";

const app = express();

// HTTP access log. In production you'd ship this to a log aggregator.
app.use(morgan("tiny"));

// Cheap liveness probe for load balancers and CI.
app.get("/healthz", (_req, res) => res.json({ status: "ok" }));

// Forward /api/* to the FastAPI backend.
// The browser sees /api/tasks → Express rewrites to BACKEND_URL/tasks.
app.use(
  "/api",
  createProxyMiddleware({
    target: BACKEND_URL,
    changeOrigin: true,
    pathRewrite: { "^/api": "" },
  })
);

// Serve the React build. `dist/` is produced by `npm run build`.
const distPath = path.join(__dirname, "dist");
app.use(express.static(distPath));

// SPA fallback — any non-API route returns index.html so React Router (if added
// later) can take over on the client.
app.get("*", (_req, res) => res.sendFile(path.join(distPath, "index.html")));

app.listen(PORT, "0.0.0.0", () => {
  console.log(`[frontend] listening on :${PORT}, proxying /api → ${BACKEND_URL}`);
});
