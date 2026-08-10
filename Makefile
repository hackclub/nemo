COMPOSE := docker compose -f deploy/compose.dev.yml
NEMO := ./bin/nemo
SCALE ?= dev
ROLE ?= serve
PORT ?= 3000

.PHONY: help up down logs provision transform seed serve test test-db lint doctor build image clean

help:
	@echo "make up            postgres for local work"
	@echo "make down          stop everything"
	@echo "make provision     schemas, roles, grants, both migration sets"
	@echo "make transform     dbt build"
	@echo "make seed          seed, transform and verify   [SCALE=tiny|dev|full]"
	@echo "make serve         the dashboard on PORT=$(PORT)"
	@echo "make test-db       rebuild the database the rails suite runs against"
	@echo "make test          pytest and rails test"
	@echo "make lint          ruff and rubocop"
	@echo "make doctor        the env a role needs           [ROLE=$(ROLE)]"
	@echo "make image         build the one image"
	@echo "make clean         drop the test database"

up:
	$(COMPOSE) up -d postgres

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

provision:
	$(NEMO) provision --create

transform:
	$(NEMO) transform

seed:
	$(NEMO) seed --scale $(SCALE)

serve:
	PORT=$(PORT) $(NEMO) serve

test-db:
	POSTGRES_DB=$${POSTGRES_TEST_DB:-mnemosyne_test} $(NEMO) provision --create
	POSTGRES_DB=$${POSTGRES_TEST_DB:-mnemosyne_test} $(NEMO) seed --scale tiny

test:
	cd pipeline && PYTHONPATH=. .venv/bin/python -m pytest -q
	cd web && bin/rails test

lint:
	cd pipeline && .venv/bin/ruff check .
	cd web && bundle exec rubocop

doctor:
	$(NEMO) doctor $(ROLE)

build image:
	docker build -t mnemosyne:latest .

clean:
	$(COMPOSE) exec -T postgres psql -U $${POSTGRES_USER:-postgres} -d postgres \
	  -c "drop database if exists $${POSTGRES_TEST_DB:-mnemosyne_test} with (force)"
