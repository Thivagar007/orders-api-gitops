# ---------- Stage 1: build the Go binary ----------
FROM golang:1-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/orders-api .

# ---------- Stage 2: tiny, shell-less runtime image ----------
# distroless/static has no package manager or shell -> very few CVEs for Trivy to find
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/orders-api /orders-api
# Numeric UID so Kubernetes "runAsNonRoot" can verify it
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/orders-api"]
