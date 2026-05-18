// All HTTP calls live here. Every request goes to a path starting with /api,
// which the Express server (or Vite in dev) proxies to the FastAPI backend.
//
// WHY we never call the backend URL directly from the browser:
//   - It would force us to handle CORS, hard-code production URLs, and expose
//     internal addresses to anyone with DevTools.
//   - With a proxy, the browser only ever talks to one origin: our frontend.

function authHeaders() {
  const token = localStorage.getItem("token");
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function request(path, options = {}) {
  const res = await fetch(`/api${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...authHeaders(),
      ...(options.headers || {}),
    },
  });

  if (res.status === 204) return null;

  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

export const api = {
  register: (email, password) =>
    request("/auth/register", { method: "POST", body: JSON.stringify({ email, password }) }),

  login: (email, password) =>
    request("/auth/login", { method: "POST", body: JSON.stringify({ email, password }) }),

  listTasks: () => request("/tasks"),
  createTask: (title, description) =>
    request("/tasks", { method: "POST", body: JSON.stringify({ title, description }) }),
  updateTask: (id, patch) =>
    request(`/tasks/${id}`, { method: "PATCH", body: JSON.stringify(patch) }),
  deleteTask: (id) => request(`/tasks/${id}`, { method: "DELETE" }),
};
