# Runbook: HighLatencyP99

**Alerta**: `HighLatencyP99`
**Condição**: P99 latência > 1s por mais de 2 minutos
**Severidade**: warning
**Serviço**: traffic-simulator

---

## Sintomas

- Alerta `HighLatencyP99` ativo no AlertManager
- Dashboard RED mostra P99 > 1 segundo
- Usuários relatando lentidão

## Diagnóstico (execute em ordem)

### 1. Confirmar latência atual por percentil
```bash
for p in 0.5 0.95 0.99; do
  val=$(curl -sg "http://localhost:9090/api/v1/query?query=histogram_quantile($p,sum(rate(traffic_simulator_request_duration_seconds_bucket[5m]))by(le))" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'N/A')")
  echo "P$(echo $p | tr -d '0.')  latência: ${val}s"
done
```

### 2. Ver latência por endpoint
```bash
curl -sg "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,sum by(path)(rate(traffic_simulator_request_duration_seconds_bucket[5m]))by(le,path))" \
  | python3 -c "
import json,sys
results = json.load(sys.stdin)['data']['result']
for r in sorted(results, key=lambda x: float(x['value'][1]), reverse=True):
    print(f\"{r['metric'].get('path','?'):30} P99: {float(r['value'][1]):.3f}s\")
"
```

### 3. Verificar saturação de CPU (throttling)
```bash
kubectl top pods -l app=traffic-simulator
kubectl describe pod -l app=traffic-simulator | grep -A5 "Limits\|Requests"
```

### 4. Verificar uso de memória (swap/pressão)
```bash
kubectl top nodes
kubectl describe node sre-lab | grep -A10 "Allocated resources"
```

### 5. Verificar active requests (saturação)
```bash
curl -sg "http://localhost:9090/api/v1/query?query=traffic_simulator_active_requests" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('Active requests:', r[0]['value'][1] if r else '0')"
```

## Causas comuns

| Causa | Indicador | Ação |
|-------|-----------|------|
| Endpoint `/stress/latency` sendo chamado | latência alta em `/stress/latency` | Parar caller ou traffic stop |
| CPU throttling | `kubectl top` mostra CPU no limite | Aumentar CPU limit ou escalar |
| Muitas conexões simultâneas | active_requests alto | Escalar horizontalmente |
| GC pressure (Go) | latência esporádica, não constante | Analisar padrão de spike |

## Remediação

### Se for stress endpoint:
```bash
curl -X POST http://localhost:8080/traffic/stop
```

### Se for CPU throttling — aumentar limite temporariamente:
```bash
kubectl set resources deployment traffic-simulator \
  --limits=cpu=500m,memory=128Mi \
  --requests=cpu=100m,memory=64Mi
```

### Se for sobrecarga — escalar:
```bash
kubectl scale deployment traffic-simulator --replicas=4
# Verificar se HPA vai assumir o controle depois
kubectl get hpa traffic-simulator -w
```

## Validação

```bash
# P99 deve cair abaixo de 1s em ~2 minutos
watch -n 10 'curl -sg "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,sum(rate(traffic_simulator_request_duration_seconds_bucket[2m]))by(le))" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"data\"][\"result\"]; print(\"P99:\", r[0][\"value\"][1]+\"s\" if r else \"N/A\")"'
```

## Postmortem

Após resolução, documentar em `docs/postmortems/YYYY-MM-DD-high-latency.md`:
- O que disparou a latência
- Qual endpoint foi afetado
- Quanto tempo durou
- Solução aplicada
- SLO impactado (% do error budget consumido)
