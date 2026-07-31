FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app
COPY pipeline/pyproject.toml ./
RUN uv sync --no-dev

COPY pipeline/ ./
COPY dbt/ /dbt/
COPY dbt/profiles.yml.example /dbt/profiles.yml

ENV PATH="/app/.venv/bin:$PATH"
