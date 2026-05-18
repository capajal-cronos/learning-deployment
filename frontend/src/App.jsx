import { useEffect, useState } from "react";
import { api } from "./api.js";

export default function App() {
  const [token, setToken] = useState(() => localStorage.getItem("token"));

  if (!token) {
    return <AuthScreen onAuthed={(t) => { localStorage.setItem("token", t); setToken(t); }} />;
  }

  return <TaskScreen onLogout={() => { localStorage.removeItem("token"); setToken(null); }} />;
}

function AuthScreen({ onAuthed }) {
  const [mode, setMode] = useState("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (mode === "register") {
        await api.register(email, password);
      }
      const { access_token } = await api.login(email, password);
      onAuthed(access_token);
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="card">
      <h1>TaskBoard</h1>
      <p className="muted">{mode === "login" ? "Sign in" : "Create an account"}</p>
      <form onSubmit={submit}>
        <input type="email" placeholder="you@example.com" value={email}
               onChange={(e) => setEmail(e.target.value)} required />
        <input type="password" placeholder="password (8+ chars)" value={password}
               onChange={(e) => setPassword(e.target.value)} minLength={8} required />
        <button disabled={busy}>{busy ? "..." : mode === "login" ? "Log in" : "Register"}</button>
      </form>
      {error && <p className="error">{error}</p>}
      <button className="link" onClick={() => setMode(mode === "login" ? "register" : "login")}>
        {mode === "login" ? "Need an account? Register" : "Have an account? Log in"}
      </button>
    </main>
  );
}

function TaskScreen({ onLogout }) {
  const [tasks, setTasks] = useState([]);
  const [title, setTitle] = useState("");
  const [error, setError] = useState(null);

  async function refresh() {
    try { setTasks(await api.listTasks()); }
    catch (err) { setError(err.message); }
  }

  useEffect(() => { refresh(); }, []);

  async function add(e) {
    e.preventDefault();
    if (!title.trim()) return;
    await api.createTask(title, null);
    setTitle("");
    refresh();
  }

  async function toggle(t) {
    await api.updateTask(t.id, { done: !t.done });
    refresh();
  }

  async function remove(t) {
    await api.deleteTask(t.id);
    refresh();
  }

  return (
    <main className="card">
      <header className="row">
        <h1>Your tasks</h1>
        <button className="link" onClick={onLogout}>Log out</button>
      </header>

      <form onSubmit={add} className="row">
        <input value={title} onChange={(e) => setTitle(e.target.value)}
               placeholder="New task" />
        <button>Add</button>
      </form>

      {error && <p className="error">{error}</p>}

      <ul className="tasks">
        {tasks.map((t) => (
          <li key={t.id} className={t.done ? "done" : ""}>
            <label>
              <input type="checkbox" checked={t.done} onChange={() => toggle(t)} />
              <span>{t.title}</span>
            </label>
            <button className="link" onClick={() => remove(t)}>delete</button>
          </li>
        ))}
        {tasks.length === 0 && <li className="muted">No tasks yet — add one above.</li>}
      </ul>
    </main>
  );
}
