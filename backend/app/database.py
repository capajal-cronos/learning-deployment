"""
Database wiring.

WHY this file exists:
  - FastAPI does not know about databases on its own.
  - We wrap SQLAlchemy here so the rest of the app just says "give me a DB session"
    and doesn't have to deal with engines or connection pools.

KEY CONCEPTS:
  - Engine: long-lived object that knows how to talk to Postgres.
  - Session: short-lived "conversation" with the DB for one request.
  - Base: parent class that every ORM model inherits from.
"""
from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import get_settings

settings = get_settings()

# The engine. `pool_pre_ping=True` checks the connection is alive before using it
# (handy because cloud DBs sometimes drop idle connections).
engine = create_engine(settings.database_url, pool_pre_ping=True, future=True)

# A factory that produces new Sessions when called.
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


class Base(DeclarativeBase):
    """All ORM models inherit from this."""


def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency. One request gets one session.
    The `yield` + `finally` pattern guarantees the session is closed
    even if the request raises an exception.
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
