ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 libpq5 python3.13 python3.13-venv && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/pipeline \
    PATH="/app/pipeline/.venv/bin:/app/bin:$PATH"

FROM base AS gems

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /app/web
COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY web/ ./
RUN bundle exec bootsnap precompile app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base AS pyenv

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app/pipeline
COPY pipeline/pyproject.toml pipeline/uv.lock ./
RUN uv sync --no-dev --frozen --python 3.13 --python-preference only-system

FROM base

RUN groupadd --system --gid 1000 nemo && \
    useradd nemo --uid 1000 --gid 1000 --create-home --shell /bin/bash

COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=gems --chown=1000:1000 /app/web /app/web
COPY --from=pyenv --chown=1000:1000 /app/pipeline/.venv /app/pipeline/.venv

COPY --chown=1000:1000 pipeline/ /app/pipeline/
COPY --chown=1000:1000 warehouse/ /app/warehouse/
COPY --chown=1000:1000 warehouse/profiles.yml.example /app/warehouse/profiles.yml
COPY --chown=1000:1000 schemas/ /app/schemas/
COPY --chown=1000:1000 db/ /app/db/
COPY --chown=1000:1000 bin/nemo /app/bin/nemo

USER 1000:1000

ENV HOME=/home/nemo

EXPOSE 80
ENTRYPOINT ["/app/bin/nemo"]
CMD ["serve"]
