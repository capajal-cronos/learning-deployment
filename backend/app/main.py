"""
FastAPI app entry point.

Run locally:
    uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

Run in production (inside Docker):
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .database import Base, engine
from .routers import auth_routes, task_routes

settings = get_settings()

app = FastAPI(title="TaskBoard API", version="1.0.0")

# CORS: tell the browser which origins may call this API directly.
# Note: when the frontend is served via the Express proxy on the same host,
# CORS is not strictly required, but we configure it correctly anyway.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",")],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def on_startup() -> None:
    """
    Auto-create tables on startup.

    NOTE: this is fine for a learning project. In a real production system
    you would use a proper migration tool like Alembic. We mention this
    again in chapter 13.
    """
    Base.metadata.create_all(bind=engine)


@app.get("/healthz", tags=["meta"])
def healthz() -> dict[str, str]:
    """Liveness probe. Load balancers and CI use this to check the app is alive."""
    return {"status": "ok"}


app.include_router(auth_routes.router)
app.include_router(task_routes.router)
