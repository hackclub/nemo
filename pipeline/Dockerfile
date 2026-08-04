FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app
COPY pipeline/pyproject.toml pipeline/uv.lock ./
RUN uv sync --no-dev --frozen

COPY pipeline/ ./
COPY dbt/ /dbt/
COPY dbt/profiles.yml.example /dbt/profiles.yml

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
