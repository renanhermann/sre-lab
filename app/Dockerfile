# ── Stage 1: build ───────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copia dependências primeiro (melhor cache do Docker)
COPY go.mod go.sum ./
RUN go mod download

# Copia código e compila
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-w -s" \
    -o traffic-simulator .

# ── Stage 2: imagem final ─────────────────────────────────────────────────────
# scratch = zero dependências, imagem de ~8MB
FROM scratch

COPY --from=builder /app/traffic-simulator /traffic-simulator

EXPOSE 8080

ENTRYPOINT ["/traffic-simulator"]
