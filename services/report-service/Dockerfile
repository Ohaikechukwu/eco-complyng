FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/report-service/ ./services/report-service/
WORKDIR /app/services/report-service
RUN go mod download
RUN go build -o /bin/report-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/report-service .
EXPOSE 8084
CMD ["./report-service"]
