"""
Smoke tests — the bare minimum to prove the app is wired up.

WHY we keep these tiny:
  - They run in CI on every push (free, fast).
  - If they fail, the more thorough tests probably won't even start.
"""
import os

# Use SQLite in-memory for tests — no Postgres needed in CI.
os.environ.setdefault("DATABASE_URL", "sqlite:///:memory:")

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


client = TestClient(app)


def test_healthz_returns_ok() -> None:
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_register_then_login_flow() -> None:
    email = "alice@example.com"
    password = "supersecret123"

    r = client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code in (201, 409)  # 409 if a previous run left this user

    r = client.post("/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200
    token = r.json()["access_token"]
    assert token

    r = client.get("/tasks", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert isinstance(r.json(), list)
