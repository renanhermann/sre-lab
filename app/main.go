package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// ── Métricas Prometheus (método RED) ─────────────────────────────────────────

var (
	// Rate — quantas requisições por segundo
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "traffic_simulator_requests_total",
		Help: "Total de requisições HTTP por método, path e status code",
	}, []string{"method", "path", "status"})

	// Duration — quanto tempo cada requisição demora (P50, P99)
	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "traffic_simulator_request_duration_seconds",
		Help:    "Duração das requisições HTTP em segundos",
		Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10},
	}, []string{"method", "path"})

	// Gauge auxiliar — requisições em andamento no momento
	activeRequests = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "traffic_simulator_active_requests",
		Help: "Número de requisições sendo processadas agora",
	})
)

// ── Middleware de instrumentação ──────────────────────────────────────────────

// responseWriter captura o status code para registrar na métrica
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// instrument envolve qualquer handler e coleta métricas RED automaticamente
func instrument(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()

		activeRequests.Inc()
		defer func() {
			activeRequests.Dec()
			status := fmt.Sprintf("%d", rw.status)
			dur := time.Since(start).Seconds()
			requestsTotal.WithLabelValues(r.Method, path, status).Inc()
			requestDuration.WithLabelValues(r.Method, path).Observe(dur)
		}()

		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"remote", r.RemoteAddr,
		)
		next(rw, r)
	}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// ── Handlers ──────────────────────────────────────────────────────────────────

// GET /health — liveness e readiness probe do Kubernetes
//
// Quando o chaos primitive /admin/fault está ativo, esta handler injeta 5xx
// numa taxa controlada. A injeção entra no path "/health" (caminho de
// produção) e portanto consome error budget do SLO de disponibilidade —
// ao contrário de /stress/error, que é excluído do SLI por design.
func handleHealth(w http.ResponseWriter, r *http.Request) {
	if rate := faultRate.Load(); rate > 0 {
		if rand.IntN(100) < int(rate) {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"status": "error",
				"reason": "fault injection active",
			})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
		"time":   time.Now().UTC().Format(time.RFC3339),
	})
}

// ── Chaos primitive: injeção de falha em /health ─────────────────────────────
//
// faultRate guarda a taxa atual (0-100) de requests a /health que devem
// retornar 5xx. Cada chamada a POST /admin/fault sobrescreve a anterior.
// Um timer separado faz auto-reset após `duration` — failsafe pra não
// deixar o cluster em modo degradado se o operador esquecer.
var (
	faultRate   atomic.Int64
	faultMu     sync.Mutex
	faultCancel context.CancelFunc
)

// POST /admin/fault?rate=N&duration=Xs
//
// rate     — % de requests a /health a falhar (0-100, default 20)
// duration — quanto tempo manter ativo (default 5m, máx 30m)
//
// rate=0 desativa imediatamente. Cap de 30min é safety: este é um
// laboratório, não um chaos game day em produção.
func handleFault(w http.ResponseWriter, r *http.Request) {
	rate := 20
	if v := r.URL.Query().Get("rate"); v != "" {
		fmt.Sscanf(v, "%d", &rate)
	}
	if rate < 0 {
		rate = 0
	}
	if rate > 100 {
		rate = 100
	}

	duration := 5 * time.Minute
	if v := r.URL.Query().Get("duration"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			duration = d
		}
	}
	if duration > 30*time.Minute {
		duration = 30 * time.Minute
	}

	faultMu.Lock()
	defer faultMu.Unlock()

	// cancela timer anterior antes de configurar um novo
	if faultCancel != nil {
		faultCancel()
		faultCancel = nil
	}

	faultRate.Store(int64(rate))

	if rate == 0 {
		slog.Warn("fault injection desativada manualmente")
		writeJSON(w, http.StatusOK, map[string]string{"status": "disabled"})
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	faultCancel = cancel
	go func() {
		select {
		case <-time.After(duration):
			faultRate.Store(0)
			faultMu.Lock()
			faultCancel = nil
			faultMu.Unlock()
			slog.Warn("fault injection expirou (auto-reset)")
		case <-ctx.Done():
			return
		}
	}()

	slog.Warn("fault injection ativada",
		"rate_pct", rate,
		"duration", duration,
		"target_path", "/health",
	)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":     "enabled",
		"rate_pct":   rate,
		"duration":   duration.String(),
		"expires_at": time.Now().Add(duration).UTC().Format(time.RFC3339),
		"target":     "/health",
	})
}

// POST /stress/cpu?seconds=N — queima CPU e dispara HPA + alerta de throttling
func handleCPU(w http.ResponseWriter, r *http.Request) {
	seconds := 10
	if s := r.URL.Query().Get("seconds"); s != "" {
		fmt.Sscanf(s, "%d", &seconds)
	}
	if seconds > 60 {
		seconds = 60 // limite de segurança
	}
	duration := time.Duration(seconds) * time.Second
	cpus := runtime.NumCPU()

	slog.Warn("cpu stress iniciado", "duration", duration, "cpus", cpus)

	ctx, cancel := context.WithTimeout(r.Context(), duration)
	defer cancel()

	var wg sync.WaitGroup
	for i := 0; i < cpus; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				default:
					// operação matemática pesada para queimar CPU
					_ = math.Sqrt(float64(time.Now().UnixNano()))
				}
			}
		}()
	}
	wg.Wait()

	slog.Info("cpu stress finalizado", "duration", duration)
	writeJSON(w, http.StatusOK, map[string]any{
		"action":   "cpu_stress",
		"duration": duration.String(),
		"cpus":     cpus,
	})
}

// POST /stress/error — força HTTP 500 para disparar alerta de error rate
func handleError(w http.ResponseWriter, r *http.Request) {
	slog.Error("erro forçado",
		"path", r.URL.Path,
		"reason", "stress endpoint acionado",
	)
	writeJSON(w, http.StatusInternalServerError, map[string]string{
		"error":  "forced error",
		"detail": "este endpoint sempre retorna 500 — usado para testar alertas",
	})
}

// POST /stress/latency?ms=N — resposta lenta para disparar alerta de P99
func handleLatency(w http.ResponseWriter, r *http.Request) {
	ms := 500
	if v := r.URL.Query().Get("ms"); v != "" {
		fmt.Sscanf(v, "%d", &ms)
	}
	if ms > 10000 {
		ms = 10000
	}
	slog.Warn("latência forçada", "ms", ms)
	time.Sleep(time.Duration(ms) * time.Millisecond)
	writeJSON(w, http.StatusOK, map[string]any{
		"action":   "latency",
		"slept_ms": ms,
	})
}

// ── Gerador de tráfego ────────────────────────────────────────────────────────

var (
	trafficMu     sync.Mutex
	trafficCancel context.CancelFunc
	running       atomic.Bool
	totalReqs     atomic.Int64
	totalErrors   atomic.Int64
)

func generateTraffic(ctx context.Context, rps int) {
	interval := time.Second / time.Duration(rps)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// endpoints que o gerador vai chamar em rodízio
	endpoints := []string{
		"/health",
		"/stress/latency?ms=10",
		"/stress/latency?ms=50",
		"/health",
		"/health",
	}
	client := &http.Client{Timeout: 5 * time.Second}
	base := "http://localhost:8080"
	i := 0

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			path := endpoints[i%len(endpoints)]
			i++
			go func(p string) {
				resp, err := client.Get(base + p)
				totalReqs.Add(1)
				if err != nil {
					totalErrors.Add(1)
					return
				}
				defer resp.Body.Close()
				if resp.StatusCode >= 500 {
					totalErrors.Add(1)
				}
			}(path)
		}
	}
}

// POST /traffic/start?rps=N — inicia gerador de tráfego em background
func handleTrafficStart(w http.ResponseWriter, r *http.Request) {
	trafficMu.Lock()
	defer trafficMu.Unlock()

	if running.Load() {
		writeJSON(w, http.StatusOK, map[string]string{"status": "já rodando"})
		return
	}

	rps := 5
	if v := r.URL.Query().Get("rps"); v != "" {
		fmt.Sscanf(v, "%d", &rps)
	}
	if rps < 1 {
		rps = 1
	}
	if rps > 50 {
		rps = 50
	}

	totalReqs.Store(0)
	totalErrors.Store(0)

	ctx, cancel := context.WithCancel(context.Background())
	trafficCancel = cancel
	running.Store(true)
	go generateTraffic(ctx, rps)

	slog.Info("gerador de tráfego iniciado", "rps", rps)
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "iniciado",
		"rps":    rps,
	})
}

// POST /traffic/stop — para o gerador e retorna estatísticas
func handleTrafficStop(w http.ResponseWriter, r *http.Request) {
	trafficMu.Lock()
	defer trafficMu.Unlock()

	if !running.Load() {
		writeJSON(w, http.StatusOK, map[string]string{"status": "não estava rodando"})
		return
	}

	trafficCancel()
	running.Store(false)

	total := totalReqs.Load()
	errors := totalErrors.Load()
	slog.Info("gerador de tráfego parado", "total", total, "errors", errors)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":     "parado",
		"total_reqs": total,
		"errors":     errors,
		"error_rate": fmt.Sprintf("%.2f%%", float64(errors)/float64(max(total, 1))*100),
	})
}

func max(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// ── Main ──────────────────────────────────────────────────────────────────────

func main() {
	// Log estruturado em JSON — aparece formatado no Grafana/Loki
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	mux := http.NewServeMux()

	// Observabilidade
	mux.HandleFunc("GET /health", instrument("/health", handleHealth))
	mux.Handle("GET /metrics", promhttp.Handler())

	// Endpoints de stress (testam alertas)
	mux.HandleFunc("POST /stress/cpu", instrument("/stress/cpu", handleCPU))
	mux.HandleFunc("POST /stress/error", instrument("/stress/error", handleError))
	mux.HandleFunc("POST /stress/latency", instrument("/stress/latency", handleLatency))
	mux.HandleFunc("GET /stress/latency", instrument("/stress/latency", handleLatency))

	// Gerador de tráfego
	mux.HandleFunc("POST /traffic/start", instrument("/traffic/start", handleTrafficStart))
	mux.HandleFunc("POST /traffic/stop", instrument("/traffic/stop", handleTrafficStop))

	// Chaos primitive — controle de fault injection.
	// O endpoint /admin/fault em si retorna 200 (acks de controle); quem
	// retorna 5xx é o /health, que está no caminho de produção e portanto
	// conta no SLI. Isso é proposital: queremos que o chaos consuma error
	// budget de verdade, pra exercitar burn rate alerts honestamente.
	mux.HandleFunc("POST /admin/fault", instrument("/admin/fault", handleFault))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	slog.Info("traffic-simulator iniciando", "port", port, "gomaxprocs", runtime.GOMAXPROCS(0))

	if err := http.ListenAndServe(":"+port, mux); err != nil {
		slog.Error("servidor encerrou", "err", err)
		os.Exit(1)
	}
}
