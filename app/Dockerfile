FROM golang:1.26-alpine AS builder
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /sentinel -ldflags="-s -w" .

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /sentinel /sentinel
COPY --from=builder /src/static /static
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/sentinel"]
