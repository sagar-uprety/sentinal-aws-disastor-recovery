FROM node:24-alpine AS styles
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY static ./static
RUN npm run build

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /sentinel -ldflags="-s -w" ./cmd/sentinel

# checkov:skip=CKV_DOCKER_2:scratch has no shell to run a HEALTHCHECK; ECS relies on the ALB target group's /healthz check instead
FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /sentinel /sentinel
COPY --from=builder /src/static /static
COPY --from=styles /src/static/app.css /static/app.css
COPY --from=styles /src/static/uPlot.iife.min.js /static/uPlot.iife.min.js
COPY --from=styles /src/static/uPlot.min.css /static/uPlot.min.css
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/sentinel"]
