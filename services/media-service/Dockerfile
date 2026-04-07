FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY shared/ ./shared/
COPY services/media-service/ ./services/media-service/
WORKDIR /app/services/media-service
RUN go mod download
RUN go build -o /bin/media-service ./cmd/main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /root/
COPY --from=builder /bin/media-service .
EXPOSE 8083
CMD ["./media-service"]
