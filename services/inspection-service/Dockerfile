FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/inspection-service/ ./services/inspection-service/
WORKDIR /app/services/inspection-service
RUN go mod download
RUN go build -o /bin/inspection-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/inspection-service .
EXPOSE 8082
CMD ["./inspection-service"]
