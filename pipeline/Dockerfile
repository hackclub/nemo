FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app
COPY pipeline/pyproject.toml pipeline/uv.lock ./
RUN uv sync --no-dev --frozen

COPY pipeline/ ./
COPY dbt/ /dbt/
COPY dbt/profiles.yml.example /dbt/profiles.yml

RUN groupadd --system --gid 1000 pipeline && \
    useradd pipeline --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R pipeline:pipeline /app /dbt
USER 1000:1000

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV HOME=/home/pipeline

ENTRYPOINT ["/app/bin/docker-entrypoint"]
