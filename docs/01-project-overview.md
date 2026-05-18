# Chapter 01 — Project overview

In this chapter we look at the code you'll be working with. You won't run anything yet — we just want a shared mental model. Once you can answer "where does this request go?" without looking, the rest of the tutorial is much easier.

---

## 1. The story

Your app, **TaskBoard**, has three components:

1. A **React** single-page app — what the user sees in the browser.
2. An **Express** server — serves the built React files and forwards `/api/*` to the backend.
3. A **FastAPI** Python service — does the real work and talks to Postgres.

Plus the data store:

4. **PostgreSQL** — stores users and their tasks.

---

## 2. One request, end to end

Let's trace what happens when a logged-in user clicks "Add task":

```
Browser                Express                FastAPI               Postgres
  │  POST /api/tasks      │                       │                      │
  │ ─────────────────────►│                       │                      │
  │  Authorization: Bearer abc123                 │                      │
  │                       │  POST /tasks          │                      │
  │                       │ ─────────────────────►│                      │
  │                       │  Authorization: ...   │                      │
  │                       │                       │  INSERT INTO tasks…  │
  │                       │                       │ ────────────────────►│
  │                       │                       │ ◄────────────────────│
  │                       │ ◄─────────────────────│  201 Created {…}     │
  │ ◄─────────────────────│  201 Created {…}      │                      │
```

Three HTTP hops, one SQL query. That's the whole story.

> 🧠 **Think first**
> If we removed Express entirely and let the browser call FastAPI directly, would the app still work? Why might we keep Express anyway?

The app would work, but:

- The browser would need to know the backend's URL — a leak of internal structure.
- We'd need to configure **CORS** to allow cross-origin calls.
- We'd lose a clean place to add SSR, logging, security headers, or feature flags later.

Putting Express in front gives us a **single origin** the browser talks to, which simplifies everything else.

---

## 3. The folder layout

```
.
├── README.md                       ← repo entry point
├── architecture.drawio             ← system diagram
├── docker-compose.yml              ← runs everything locally
├── .env.example                    ← template, copy to .env
├── backend/                        ← FastAPI service
│   ├── app/
│   │   ├── main.py                 ← FastAPI app, routes registration
│   │   ├── config.py               ← env-driven settings
│   │   ├── database.py             ← SQLAlchemy engine + session
│   │   ├── models.py               ← User, Task (ORM)
│   │   ├── schemas.py              ← Pydantic request/response shapes
│   │   ├── auth.py                 ← bcrypt + JWT helpers
│   │   └── routers/
│   │       ├── auth_routes.py
│   │       └── task_routes.py
│   ├── tests/
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/                       ← React app + Express server
│   ├── src/
│   │   ├── main.jsx
│   │   ├── App.jsx
│   │   ├── api.js
│   │   └── styles.css
│   ├── index.html
│   ├── server.js                   ← Express server (prod)
│   ├── vite.config.js              ← Vite dev server config
│   ├── package.json
│   └── Dockerfile
└── .github/
    └── workflows/
        └── ci-cd.yml               ← GitHub Actions pipeline
```

---

## 4. Two kinds of "ports"

This trips up almost every beginner.

- A **container port** is the port the app listens on **inside its Docker container**.
- A **host port** is the port on **your laptop or the VM** that traffic actually reaches.

`docker-compose.yml` maps one to the other:

```yaml
ports:
  - "3000:3000"      # host:container
```

means: traffic to `localhost:3000` on your machine goes to port `3000` inside the frontend container.

Inside the Docker network, containers do **not** need port mappings to talk to each other. They use service names (`backend`, `db`) and the container's own port. We'll see this in the next chapter.

> ⚠️ **Pitfall**
> If you bind a database to `0.0.0.0:5432` on the host, anyone who can reach your machine can probe Postgres. We use `127.0.0.1:5432:5432` to keep it on localhost only.

---

## 5. The data model

```
┌──────────────┐         ┌─────────────────────────┐
│   users      │         │         tasks           │
├──────────────┤         ├─────────────────────────┤
│ id (PK)      │◄──┐     │ id (PK)                 │
│ email UNIQUE │   └─────│ owner_id (FK → users.id)│
│ password_hash│         │ title                   │
│ created_at   │         │ description             │
└──────────────┘         │ done                    │
                         │ created_at              │
                         └─────────────────────────┘
```

Two tables. Tasks belong to exactly one user. We never store a plain password — only a bcrypt hash.

---

## 6. The auth flow

```
1. POST /auth/register  { email, password }   → bcrypt-hash, save user
2. POST /auth/login     { email, password }   → verify → return JWT
3. GET  /tasks          (Header: Bearer <jwt>) → decode JWT → look up user → return tasks
```

The JWT lives in the browser's `localStorage`. The Express server is unaware of it — it just forwards the `Authorization` header along with the proxied request.

> 💡 **Production note**
> For a real product, JWTs in localStorage are vulnerable to XSS. A safer pattern is an **HttpOnly cookie**. We mention this again in chapter 08.

---

## 7. Environment variables, in one place

| Variable             | Used by             | What for                              |
| -------------------- | ------------------- | ------------------------------------- |
| `POSTGRES_USER`      | db, backend         | Postgres role and connection string   |
| `POSTGRES_PASSWORD`  | db, backend         | Postgres password                     |
| `POSTGRES_DB`        | db, backend         | Postgres database name                |
| `DATABASE_URL`       | backend             | Full SQLAlchemy connection string     |
| `JWT_SECRET`         | backend             | Signs login tokens                    |
| `JWT_EXPIRES_MINUTES`| backend             | Token lifetime                        |
| `BACKEND_URL`        | frontend            | Where the Express proxy forwards `/api` |
| `PORT`               | frontend            | Where Express listens                 |

In dev they come from `.env`. In CI they come from GitHub Secrets. On the VM they come from a `.env` file we deploy with the app. We'll switch between those gradually.

---

## 8. Checkpoint ✅

1. Why do we keep Express in front of React even though React is "just static files"?
2. What is the difference between a **container port** and a **host port**?
3. Why don't we store plain passwords?

> Answers
> 1. Single origin for the browser, clean proxy point for `/api`, easier security/SSR/logging later.
> 2. Container port = inside the container. Host port = on the host machine. `host:container` maps them.
> 3. If the DB is ever leaked, plaintext passwords are catastrophic. Bcrypt makes the leaked file useless without huge compute.

---

## 9. Optional exercise 🧪

Open `backend/app/main.py` and find where the routers are included. Trace one line: open `backend/app/routers/task_routes.py` and follow the `Depends(get_current_user)` chain in `auth.py`. Write down in one sentence what protects a route from being accessed without a login.

---

➡️ Next: [Chapter 02 — Local development](./02-local-development.md)
