FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /sentry -ldflags="-s -w" ./cmd/sentry

# checkov:skip=CKV_DOCKER_2:scratch has no shell to run a HEALTHCHECK; ECS relies on the ALB target group's /healthz check instead
FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /sentry /sentry
COPY --from=builder /src/static /static
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/sentry"]
