FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml ./
RUN uv sync --no-dev

COPY . .

EXPOSE 8002
CMD ["uv", "run", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8002"]
