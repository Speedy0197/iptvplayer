FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -o iptv-backend .

FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /app
COPY --from=builder /app/iptv-backend .
RUN mkdir -p /data
VOLUME ["/data"]
EXPOSE 8080
CMD ["./iptv-backend"]
