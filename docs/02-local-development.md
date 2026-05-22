# Chapter 02 — Local development

Time to run the app. We deliberately start with **everything on one machine** before reaching for the cloud — because cloud problems are 10× harder to debug if you don't already know what the app looks like when it's healthy.

---

## 1. Goal of this chapter

By the end you'll have:

- Postgres, FastAPI, and React + Express all running on your machine.
- A working login flow at `http://localhost:3000`.
- An intuition for **Docker networking** that you'll reuse in every later chapter.

---

## 2. Set up your `.env`

Copy the template:

```bash
cp .env.example .env        # macOS / Linux / Git Bash
# or
copy .env.example .env      # Windows cmd / PowerShell
```

Open `.env` and change `POSTGRES_PASSWORD` to anything you like for local use. The rest of the defaults will work.

> ⚠️ **If you change `POSTGRES_PASSWORD`, also update the password inside `DATABASE_URL`** a few lines below. Postgres uses `POSTGRES_PASSWORD` when the container first initializes; the backend uses the password embedded in `DATABASE_URL` to connect. If they don't match, the backend will crash on startup with `password authentication failed for user "taskboard"`.
>
> ```env
> POSTGRES_PASSWORD=my-new-password
> DATABASE_URL=postgresql+psycopg://taskboard:my-new-password@db:5432/taskboard
> #                                          ^^^^^^^^^^^^^^^ must match
> ```
>
> If you already started the stack with a mismatched password, the database volume was initialized with the old value. Run `docker compose down -v` to wipe it before bringing things back up.

> ⚠️ **Pitfall**
> `.env` is git-ignored. `.env.example` is not. Never put real passwords in `.env.example`. Pretend you're sharing it with the internet — because eventually you will be.

---

## 3. Two ways to run the app

| Mode                              | What it's for                  |
| --------------------------------- | ------------------------------ |
| `docker compose up`               | The "deploy-like" path. Use this most of the time. |
| Native (`uvicorn`, `npm run dev`) | Iterating on the React UI with hot reload. |

We'll cover both. **Default to Docker Compose** — it matches the deploy target much more closely.

---

## 4. Path A — Run everything in Docker

From the repo root:

```bash
docker compose up --build
```

The first build takes a few minutes. After that:

```
[+] Running 3/3
 ✔ Container learning_deployment-db-1        Healthy
 ✔ Container learning_deployment-backend-1   Started
 ✔ Container learning_deployment-frontend-1  Started
```

Open `http://localhost:3000` — you should see the TaskBoard login screen.

### What just happened?

Compose did **a lot**:

1. Read `docker-compose.yml` and resolved `${POSTGRES_USER}` etc. from `.env`.
2. Built the backend image using `backend/Dockerfile`.
3. Built the frontend image using `frontend/Dockerfile`.
4. Pulled `postgres:16-alpine` from Docker Hub.
5. Created a **dedicated network** named something like `learning_deployment_default`.
6. Started the three containers on that network.
7. Mapped the container port `3000` to your host port `3000`.

You can see the network with:

```bash
docker network ls
docker network inspect learning_deployment_default
```

In there you'll find each container's **internal IP** — a tiny private IP that only Docker uses. We'll see the cloud equivalent of this in chapter 05.

---

## 5. Why service names work as hostnames

Inside the Compose network, `backend` resolves to the backend container's IP. Same for `db` and `frontend`. This is called **service discovery via embedded DNS**.

That's why the backend's `DATABASE_URL` is:

```
postgresql+psycopg://taskboard:...@db:5432/taskboard
                                  ^^
                          this is a hostname,
                          not your laptop's "db"
```

And it's why the Express server's `BACKEND_URL` is `http://backend:8000`. From your **host shell**, neither `db` nor `backend` resolves. From inside the containers, both do.

> 🧠 **Think first**
> If you ran `curl http://backend:8000/healthz` in your **host** terminal, would it work? Why not?

It wouldn't. The hostname `backend` is only defined inside the Docker network. From the host, you'd reach the backend at `http://localhost:8000` (because we published that port).

---

## 6. Look at the logs

In a separate terminal:

```bash
docker compose logs -f backend
```

You should see Uvicorn starting and the `/healthz` checks succeeding. Press `Ctrl+C` to stop the log tail (this does NOT stop the container).

Quick reference:

| Command                              | What it does                          |
| ------------------------------------ | ------------------------------------- |
| `docker compose ps`                  | List running services                 |
| `docker compose logs -f <service>`   | Tail a service's logs                 |
| `docker compose exec backend bash`   | Get a shell inside the container      |
| `docker compose down`                | Stop containers, keep volumes         |
| `docker compose down -v`             | Stop AND delete the database volume   |
| `docker compose up --build`          | Rebuild images and restart            |

---

## 7. Try the app

1. Open `http://localhost:3000`.
2. Click **Register**, use `you@example.com` / `password123`.
3. You're now logged in. Add a task.
4. Refresh the page — the task is still there (it's in Postgres).
5. Log out, log back in — task is still there (it belongs to your user).

### Behind the scenes during step 2

```
1. React calls   fetch("/api/auth/register", …)
2. Browser sends POST localhost:3000/api/auth/register
3. Express sees /api → strips it → forwards to http://backend:8000/auth/register
4. FastAPI hashes the password with bcrypt
5. SQLAlchemy issues:  INSERT INTO users (...) VALUES (...)
6. FastAPI returns 201 { id, email, created_at }
7. Express returns it to the browser unchanged
```

---

## 8. Path B — Native dev mode (hot reload)

If you're iterating on the React UI, the Docker build cycle gets slow. You can run things natively while keeping Postgres in Docker:

```bash
docker compose up -d db        # just Postgres, in the background

# in one terminal:
cd backend
python -m venv .venv
. .venv/Scripts/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload     # listens on 8000

# in another terminal:
cd frontend
npm install
npm run dev                       # Vite on 5173
```

Now open `http://localhost:5173`. Vite is configured to proxy `/api` to `http://localhost:8000`, so the React code doesn't change at all between modes.

> 💡 The big lesson: **the React code never knows where the backend is**. The proxy decides. That's a powerful property and we keep it true all the way to production.

---

## 9. Inspecting Postgres directly

To peek at the database:

```bash
docker compose exec db psql -U taskboard -d taskboard
```

Inside the `psql` prompt:

```sql
\dt                            -- list tables
SELECT id, email, created_at FROM users;
SELECT * FROM tasks;
\q                             -- quit
```

If you're not comfortable with SQL yet, that's fine — you don't need it for the rest of the tutorial. But knowing how to peek is gold when something goes wrong.

---

## 10. Common beginner mistakes

| Symptom                                     | Likely cause                                                                  |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| `port is already allocated`                 | Another process is on 3000/5432/8000. Stop it or change the host port.        |
| Login works but tasks list is empty after restart | You ran `docker compose down -v` (the `-v` wipes the volume).         |
| Backend can't reach DB on first start       | DB wasn't ready yet. We use `depends_on: condition: service_healthy` to fix this. |
| `curl localhost:8000` works on host but `curl backend:8000` does not | `backend` only resolves inside the Compose network.       |
| Changes to React don't appear               | If you're in `docker compose up`, you need `--build`. Or use `npm run dev` (Path B). |

---

## 11. Stop everything cleanly

```bash
docker compose down
```

Your data is still there (in the `db-data` volume). If you want a clean slate:

```bash
docker compose down -v
```

---

## 12. Checkpoint ✅

1. Why does `db` work as a hostname inside the backend container but not from your host shell?
2. What is the difference between `docker compose down` and `docker compose down -v`?
3. In Path B (native dev), what makes `/api/...` from the React code reach FastAPI without changing any frontend source?

> Answers
> 1. Docker Compose creates a private network with embedded DNS that maps service names to container IPs. Your host isn't on that network.
> 2. `down` stops the containers but keeps named volumes. `down -v` deletes the volumes too — bye-bye data.
> 3. The Vite dev server is configured to proxy `/api` to `http://localhost:8000` (see `vite.config.js`).

---

## 13. Optional exercise 🧪

Add a new column `priority INTEGER DEFAULT 1` to the `Task` model and re-create the schema (hint: `docker compose down -v` then `up --build`). Then send a `PATCH /tasks/{id}` with a JSON body containing `"priority": 3` and see what happens.

What error do you get if you forget to also update the Pydantic schema in `schemas.py`?

---

➡️ Next: [Chapter 03 — Docker basics](./03-docker-basics.md)
