.PHONY: build run clean lint test docker-build

APP_NAME := signaling
CMD_DIR := ./cmd/signaling

build:
	go build -o $(APP_NAME) $(CMD_DIR)

run: build
	./$(APP_NAME)

clean:
	rm -f $(APP_NAME)
	rm -f oretty.db
	rm -f oretty.db-wal
	rm -f oretty.db-shm

lint:
	golangci-lint run ./... 2>/dev/null || go vet ./...

test:
	go test ./... -v

docker-build:
	docker build -t oretty-signaling:latest -f Dockerfile ..

deps:
	go mod tidy
	go mod download

all: deps lint build
