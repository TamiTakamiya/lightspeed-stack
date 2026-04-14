SHELL := /bin/bash

ARTIFACT_DIR := $(if $(ARTIFACT_DIR),$(ARTIFACT_DIR),tests/test_results)
PATH_TO_PLANTUML := ~/bin

# Python registry to where the package should be uploaded
PYTHON_REGISTRY = pypi


# Default configuration files (override with: make run CONFIG=myconfig.yaml)
CONFIG ?= lightspeed-stack.yaml
LLAMA_STACK_CONFIG ?= run.yaml

RAG_CONTENT_IMAGE ?= quay.io/ansible/aap-rag-content:latest
BYOK_RAG_CONTENT_IMAGE ?= quay.io/ansible/aap-byok-example:latest

PROVIDER_VECTOR_DB_ID_FILE ?= "./vector_db/provider_vector_db_id.ind"
PROVIDER_VECTOR_DB_ID ?= $(shell [ -f $(PROVIDER_VECTOR_DB_ID_FILE) ] && cat $(PROVIDER_VECTOR_DB_ID_FILE))
$(info PROVIDER_VECTOR_DB_ID is $(PROVIDER_VECTOR_DB_ID))

BYOK_LLAMA_STACK_YAML ?= "./byok_vector_db/llama-stack.yaml"
BYOK_PROVIDER_VECTOR_DB_ID ?= $(shell sed -n 's/.*vector_store_id: //p' $(BYOK_LLAMA_STACK_YAML) | tr -d '\n')
$(info BYOK_PROVIDER_VECTOR_DB_ID is $(BYOK_PROVIDER_VECTOR_DB_ID))

OPENAI_INFERENCE_MODEL ?= gpt-4o-mini
OPENAI_BASE_URL ?= https://api.openai.com/v1

# Container configuration
LLAMA_STACK_PORT ?= 8080
CONTAINER_DB_PATH ?= /.llama/data/distributions/ansible-chatbot

# Choose between docker and podman based on what is available
ifeq (, $(shell which podman))
	CONTAINER_RUNTIME ?= docker
	IMAGE_PREFIX ?=
else
	CONTAINER_RUNTIME ?= podman
	IMAGE_PREFIX ?= localhost/
endif

PLATFORM ?= "linux/amd64"

run: ## Run the service locally
	uv run src/lightspeed_stack.py -c $(CONFIG)

run-llama-stack: ## Start Llama Stack with enriched config (for local service mode)
	uv run src/llama_stack_configuration.py -c $(CONFIG) -i $(LLAMA_STACK_CONFIG) -o $(LLAMA_STACK_CONFIG) && \
	AZURE_API_KEY=$$(grep '^AZURE_API_KEY=' .env | cut -d'=' -f2-) \
	uv run llama stack run $(LLAMA_STACK_CONFIG)

test-unit: ## Run the unit tests
	@echo "Running unit tests..."
	@echo "Reports will be written to ${ARTIFACT_DIR}"
	COVERAGE_FILE="${ARTIFACT_DIR}/.coverage.unit" uv run python -m pytest tests/unit --cov=src --cov-report term-missing --cov-report "json:${ARTIFACT_DIR}/coverage_unit.json" --junit-xml="${ARTIFACT_DIR}/junit_unit.xml" --cov-fail-under=60

test-integration: ## Run integration tests tests
	@echo "Running integration tests..."
	@echo "Reports will be written to ${ARTIFACT_DIR}"
	COVERAGE_FILE="${ARTIFACT_DIR}/.coverage.integration" uv run python -m pytest tests/integration --cov=src --cov-report term-missing --cov-report "json:${ARTIFACT_DIR}/coverage_integration.json" --junit-xml="${ARTIFACT_DIR}/junit_integration.xml" --cov-fail-under=10

test-e2e: ## Run end to end tests for the service
	script -q -e -c "uv run behave --color --format pretty --tags=-skip -D dump_errors=true @tests/e2e/test_list.txt"

test-e2e-local: ## Run end to end tests for the service (no script wrapper)
	uv run behave --color --format pretty --tags=-skip -D dump_errors=true @tests/e2e/test_list.txt

# Tag-based subsets (@e2e_group_* on feature files). Default runs all groups; override for one shard, e.g.
#   E2E_BEHAVE_TAG_EXPR='not @skip and @e2e_group_2' make test-e2e-tagged-local
E2E_BEHAVE_TAG_EXPR ?= not @skip and (e2e_group_1 or e2e_group_2 or e2e_group_3)

test-e2e-tagged: ## Run e2e tests with E2E_BEHAVE_TAG_EXPR (default: all @e2e_group_*)
	script -q -e -c "uv run behave --color --format pretty --tags=\"$(E2E_BEHAVE_TAG_EXPR)\" -D dump_errors=true @tests/e2e/test_list.txt"

test-e2e-tagged-local: ## Same as test-e2e-tagged without script wrapper
	uv run behave --color --format pretty --tags="$(E2E_BEHAVE_TAG_EXPR)" -D dump_errors=true @tests/e2e/test_list.txt

benchmarks: ## Run benchmarks
	uv run python -m pytest -vv tests/benchmarks/

check-types: ## Checks type hints in sources
	uv run mypy --explicit-package-bases --disallow-untyped-calls --disallow-untyped-defs --disallow-incomplete-defs --ignore-missing-imports --disable-error-code attr-defined src/ tests/unit tests/integration tests/e2e/ dev-tools/

security-check: ## Check the project for security issues
	uv run bandit -c pyproject.toml -r src tests dev-tools

format: ## Format the code into unified format
	uv run black .
	uv run ruff check . --fix

schema:	## Generate OpenAPI schema file
	uv run scripts/generate_openapi_schema.py docs/openapi.json

openapi-doc:	docs/openapi.json scripts/fix_openapi_doc.py	## Generate OpenAPI documentation
	openapi-to-markdown --input_file docs/openapi.json --output_file output.md
	# LCORE-1494: don't overwrite the original docs/output.md for now
	python3 scripts/fix_openapi_doc.py < output.md > openapi2.md
	rm output.md

generate-documentation:	## Generate documentation
	scripts/gen_doc.py

doc:	## Generate documentation for developers
	scripts/gen_doc.py

docs/config.puml:	src/models/config.py ## Generate PlantUML class diagram for configuration
	uv run pyreverse src/models/config.py --output puml --output-directory=docs/
	mv docs/classes.puml docs/config.puml

# Omit --theme rose on the CLI: it fails with some plantuml.jar builds on pyreverse output.
# To use rose, add a line after @startuml: !theme rose  (requires a recent JAR).
# PNG is capped at 4096px per side by default; pyreverse class diagrams are often wider—raise the limit.
docs/config.png:	docs/config.puml ## Generate an image with configuration graph
	pushd docs && \
	java -DPLANTUML_LIMIT_SIZE=16384 -jar ${PATH_TO_PLANTUML}/plantuml.jar config.puml && \
	mv classes.png config.png && \
	popd

docs/config.svg:	docs/config.puml ## Generate an SVG with configuration graph
	pushd docs && \
	java -jar ${PATH_TO_PLANTUML}/plantuml.jar config.puml -tsvg && \
	xmllint --format classes.svg > config.svg && \
	rm -f classes.svg && \
	popd

shellcheck: ## Run shellcheck
	wget -qO- "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz" | tar -xJv \
	shellcheck --version
	shellcheck -- */*.sh

black:	## Check source code using Black code formatter
	uv run black --check .

pylint:	## Check source code using Pylint static code analyser
	uv run pylint src tests dev-tools

pyright:	## Check source code using Pyright static type checker
	uv run pyright src dev-tools

docstyle:	## Check the docstring style using Docstyle checker
	uv run pydocstyle -v src dev-tools

ruff:	## Check source code using Ruff linter
	uv run ruff check . --per-file-ignores=tests/*:S101 --per-file-ignores=scripts/*:S101

verify:	## Run all linters
	$(MAKE) black
	$(MAKE) pylint
	$(MAKE) pyright
	$(MAKE) ruff
	$(MAKE) docstyle
	$(MAKE) check-types

distribution-archives:	## Generate distribution archives to be uploaded into Python registry
	rm -rf dist
	uv run python -m build

upload-distribution-archives:	## Upload distribution archives into Python registry
	uv run python -m twine upload --repository ${PYTHON_REGISTRY} dist/*

konflux-requirements:	## Generate hermetic requirements.*.txt file for konflux build
	./scripts/konflux_requirements.sh

konflux-rpm-lock:	## Generate rpm.lock.yaml file for konflux build
	./scripts/generate-rpm-lock.sh

konflux-artifacts-lock: ## Regenerate artifacts.lock.yaml file for konflux build
	./scripts/generate-artifacts-lock.sh

help: ## Show this help screen
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@grep -E '^[ a-zA-Z0-9_./-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-33s\033[0m %s\n", $$1, $$2}'
	@echo ''

setup-vector-db: vector_db/aap_faiss_store.db byok_vector_db/faiss_store.db

vector_db/aap_faiss_store.db:
	@echo "Setting up vector db and embedding image..."
	rm -rf ./vector_db ./embeddings_model
	mkdir -p ./vector_db
	$(CONTAINER_RUNTIME) run --platform $(PLATFORM) -d --rm --name rag-content $(RAG_CONTENT_IMAGE) sleep infinity
	$(CONTAINER_RUNTIME) cp rag-content:/rag/llama_stack_vector_db/faiss_store.db.gz ./vector_db/aap_faiss_store.db.gz
	$(CONTAINER_RUNTIME) cp rag-content:/rag/llama_stack_vector_db/provider_vector_db_id.ind ./vector_db/provider_vector_db_id.ind
	$(CONTAINER_RUNTIME) cp rag-content:/rag/embeddings_model .
	$(CONTAINER_RUNTIME) kill rag-content
	gzip -d ./vector_db/aap_faiss_store.db.gz
	# this permission changes will allow the container user 1001 to read/write the files
	# in these directories
	chmod -R og+rw ./vector_db/
	chmod -R og+rw ./embeddings_model/

byok_vector_db/faiss_store.db:
	@echo "Setting up BYOK vector db..."
	rm -rf ./byok_vector_db
	mkdir -p ./byok_vector_db
	$(CONTAINER_RUNTIME) run --platform $(PLATFORM) -d --rm --name rag-content $(BYOK_RAG_CONTENT_IMAGE) sleep infinity
	$(CONTAINER_RUNTIME) cp rag-content:/rag/vector_db/faiss_store.db.gz ./byok_vector_db/faiss_store.db.gz
	$(CONTAINER_RUNTIME) cp rag-content:/rag/vector_db/llama-stack.yaml ./byok_vector_db/llama-stack.yaml
	$(CONTAINER_RUNTIME) kill rag-content
	gzip -d ./byok_vector_db/faiss_store.db.gz
	# this permission changes will allow the container user 1001 to read/write the files
	# in these directories
	chmod -R og+rw ./byok_vector_db/

run-container:
	@echo "Running Ansible Chatbot Stack container..."
	@echo "Using vLLM URL: $(ANSIBLE_CHATBOT_VLLM_URL)"
	@echo "Using inference model: $(ANSIBLE_CHATBOT_INFERENCE_MODEL)"
	@mkdir -p ./container_data/distributions/ansible-chatbot
	@chmod -R og+rw ./container_data 2>/dev/null || true
	$(CONTAINER_RUNTIME) run --platform $(PLATFORM) --security-opt label=disable -it -p $(LLAMA_STACK_PORT):8080 \
	  -v ./embeddings_model:/.llama/data/embeddings_model \
	  -v ./vector_db/aap_faiss_store.db:$(CONTAINER_DB_PATH)/aap_faiss_store.db \
	  -v ./byok_vector_db:/.llama/data/byok/distributions/ansible-chatbot \
	  -v ./lightspeed-stack-byok.yaml:/.llama/distributions/ansible-chatbot/config/lightspeed-stack.yaml \
	  -v ./ansible-chatbot-run.yaml:/.llama/distributions/llama-stack/config/ansible-chatbot-run.yaml \
	  -v ./ansible-chatbot-system-prompt.txt:/.llama/distributions/ansible-chatbot/system-prompts/default.txt \
	  -v ./container_data/distributions:/.llama/data/distributions \
	  --env OPENAI_INFERENCE_MODEL=$(OPENAI_INFERENCE_MODEL) \
	  --env OPENAI_API_KEY=$(OPENAI_API_KEY) \
	  --env OPENAI_BASE_URL=$(OPENAI_BASE_URL) \
	  --env PROVIDER_VECTOR_DB_ID=$(PROVIDER_VECTOR_DB_ID) \
	  --env OTEL_SDK_DISABLED=true \
	  --env LLAMA_STACK_LOGGING="all=info" \
	  --env BYOK_PROVIDER_VECTOR_DB_ID=$(BYOK_PROVIDER_VECTOR_DB_ID) \
	  quay.io/lightspeed-core/lightspeed-stack:latest \
	    --config /.llama/distributions/ansible-chatbot/config/lightspeed-stack.yaml
