FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /shortener -ldflags="-s -w" ./cmd/shortener

# checkov:skip=CKV_DOCKER_2:scratch has no shell; ECS uses the ALB /healthz check
FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /shortener /shortener
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/shortener"]
