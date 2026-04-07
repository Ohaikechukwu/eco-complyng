FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY api-gateway/ ./api-gateway/
WORKDIR /app/api-gateway
RUN go mod download
RUN go build -o /bin/api-gateway ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/api-gateway .
EXPOSE 8080
CMD ["./api-gateway"]
