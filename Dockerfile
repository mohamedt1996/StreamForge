# syntax=docker/dockerfile:1

# ---- build ---------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY go.mod go.sum* ./
RUN if [ -f go.sum ]; then go mod download; fi
COPY . .
# Until go.sum is committed, resolve it at build time.
RUN [ -f go.sum ] || go mod tidy
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/streamforge-sync . \
 && mkdir -p /out/data

# ---- runtime: distroless, no shell, runs as uid 65532 ----------------------------
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/streamforge-sync /usr/local/bin/streamforge-sync
COPY --from=build --chown=65532:65532 /out/data /data
ENV STREAMFORGE_ADDR=:8484 \
    STREAMFORGE_DATA=/data
USER 65532:65532
VOLUME /data
EXPOSE 8484
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/streamforge-sync", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/streamforge-sync"]
