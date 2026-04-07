FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/auth-service/ ./services/auth-service/
WORKDIR /app/services/auth-service
RUN go mod download
RUN go build -o /bin/auth-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/auth-service .
EXPOSE 8081
CMD ["./auth-service"]
