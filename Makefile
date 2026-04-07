.PHONY: help docker-up docker-down migrate-up migrate-down test lint proto generate-mocks

SERVICES := auth-service inspection-service media-service report-service collaboration-service notification-service export-service

help:
	@echo "EcoComply NG — Available targets:"
	@echo "  docker-up          Start full stack"
	@echo "  docker-down        Stop full stack"
	@echo "  migrate-up         Run all pending migrations"
	@echo "  migrate-down       Roll back last migration"
	@echo "  test               Run all tests"
	@echo "  lint               Run golangci-lint"
	@echo "  proto              Compile protobuf definitions"
	@echo "  generate-mocks     Regenerate mockery mocks"
	@echo "  run-gateway        Run API gateway locally"
	@echo "  run-<service>      Run a specific service locally"

docker-up:
	docker compose up --build -d

docker-down:
	docker compose down

migrate-up:
	@bash scripts/migrate.sh up

migrate-down:
	@bash scripts/migrate.sh down

test:
	@for svc in $(SERVICES); do \
		echo "Testing $$svc..."; \
		(cd services/$$svc && go test ./... -v -cover); \
	done
	@echo "Testing api-gateway..."; \
	(cd api-gateway && go test ./... -v -cover)

lint:
	golangci-lint run ./...

proto:
	@bash scripts/proto.sh

generate-mocks:
	@for svc in $(SERVICES); do \
		echo "Generating mocks for $$svc..."; \
		(cd services/$$svc && mockery --all --output ./internal/mocks); \
	done

run-gateway:
	cd api-gateway && go run cmd/main.go

define run-service
run-$(1):
	cd services/$(1) && go run cmd/main.go
endef
$(foreach svc,$(SERVICES),$(eval $(call run-service,$(svc))))
