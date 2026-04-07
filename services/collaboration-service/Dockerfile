FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/collaboration-service/ ./services/collaboration-service/
WORKDIR /app/services/collaboration-service
RUN go mod download
RUN go build -o /bin/collaboration-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/collaboration-service .
EXPOSE 8085
CMD ["./collaboration-service"]
