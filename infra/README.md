# infra

Deployment and orchestration config that spans services. Each service keeps its own `Dockerfile` (build context lives with the code); this directory wires them together.

```
docker-compose.yml     # postgres, web, events-listener (service), nightly-sync (cron)
.env.example
bootstrap.sh           # brings a fresh instance up to a working schema
test-db.sh             # builds the database the rails suite runs against
postgres/
  init.sql             # schemas (raw / analytics / app) + roles enforcing write ownership
```

The proxy is not here. It holds the Slack credentials, runs on its own machine, and every other
service reaches it over the network at `INTERNAL_PROXY_URL`.

`web` is the exposed service and it forces SSL, so plain HTTP redirects to `https://`. Two ways to
give it TLS, both with the same image: set `TLS_DOMAIN` and thruster obtains a certificate itself,
which needs `WEB_HTTP_PORT=80` and `WEB_HTTPS_PORT=443`, or terminate TLS in front of it and pass
`X-Forwarded-Proto: https`, which Rails already trusts. It runs `db:migrate` on boot.

`CONTAINER_PROXY_URL` exists for the case where the proxy runs on the same host as the containers
rather than another machine. Set it to `http://host.docker.internal:8002` and the three services use
that instead of `INTERNAL_PROXY_URL`, which stays pointed at wherever the host itself reaches.

## A fresh instance

```
cp infra/.env.example infra/.env    # fill it in, including BOOTSTRAP_ADMIN_SLACK_ID
docker compose -f infra/docker-compose.yml up -d postgres
infra/bootstrap.sh
```

`bootstrap.sh` creates the database if it is missing, applies `init.sql`, sets the role passwords
from `.env`, runs the Rails migrations, applies the raw schema, seeds the first community manager,
and runs dbt once so `analytics` has tables. It is safe to re-run. Until that dbt build has happened
the dashboard cannot render, because every card reads a mart.

What it deliberately does not do: start the proxy, which is deployed separately and holds the Slack
credentials, or start the containers. Both are printed as the next steps.

`bin/rails test` refuses to run against any database whose name does not end in `_test`.
Build one with `infra/test-db.sh`, or `infra/test-db.sh --recreate` to start over. It applies
`init.sql`, the Rails migrations, the raw schema, one seed row and dbt, in that order, against
`POSTGRES_TEST_DB` (default `${POSTGRES_DB}_test`). CI runs the same script.

Two pipeline runtime shapes: `events_listener` runs as a long-lived service; `nightly_sync` runs on a cron schedule. Don't cron the listener.
