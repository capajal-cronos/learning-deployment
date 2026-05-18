"""
Pydantic schemas — the SHAPE of data coming into and going out of the API.

WHY separate from the ORM models?
  - Models describe how data is stored. Schemas describe how data is sent over HTTP.
  - We must NEVER leak `password_hash` to the client, for example.
  - The frontend only needs to know about the public shape.
"""
from datetime import datetime
from pydantic import BaseModel, EmailStr, Field


# --- Auth ---

class UserCreate(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class UserOut(BaseModel):
    id: int
    email: EmailStr
    created_at: datetime

    class Config:
        from_attributes = True  # allows .from_orm-style conversion


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


# --- Tasks ---

class TaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str | None = None


class TaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = None
    done: bool | None = None


class TaskOut(BaseModel):
    id: int
    title: str
    description: str | None
    done: bool
    created_at: datetime

    class Config:
        from_attributes = True
