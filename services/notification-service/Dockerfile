FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/notification-service/ ./services/notification-service/
WORKDIR /app/services/notification-service
RUN go mod download
RUN go build -o /bin/notification-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/notification-service .
EXPOSE 8086
CMD ["./notification-service"]
