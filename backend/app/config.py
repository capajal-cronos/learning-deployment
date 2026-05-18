"""
Application settings.

We use `pydantic-settings` so that every config value:
  1. Has a clear name and type.
  2. Is loaded from environment variables automatically.
  3. Fails fast at startup if something required is missing.

WHY a settings class instead of just os.getenv() everywhere?
  - One source of truth.
  - Auto-validation (e.g. JWT_EXPIRES_MINUTES must be an int).
  - Makes it easy to swap config in tests.
"""
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Connection string for Postgres. Read from env. No default in prod.
    database_url: str = "postgresql+psycopg://taskboard:change-me-locally@db:5432/taskboard"

    # Secret used to sign JWT session tokens. MUST be overridden in prod.
    jwt_secret: str = "dev-only-please-change"
    jwt_algorithm: str = "HS256"
    jwt_expires_minutes: int = 60

    # CORS — which browser origins are allowed to call this API.
    # In production this would be your real frontend domain.
    cors_origins: str = "http://localhost:3000,http://localhost:5173"

    model_config = SettingsConfigDict(env_file=".env", case_sensitive=False)


@lru_cache
def get_settings() -> Settings:
    """Cached so we read env only once per process."""
    return Settings()
