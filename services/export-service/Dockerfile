FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/export-service/ ./services/export-service/
WORKDIR /app/services/export-service
RUN go mod download
RUN go build -o /bin/export-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/export-service .
EXPOSE 8087
CMD ["./export-service"]
