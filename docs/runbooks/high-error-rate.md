# Runbook: HighErrorRate

**Alerta**: `HighErrorRate`
**Condição**: error rate > 5% por mais de 1 minuto
**Severidade**: warning
**Serviço**: traffic-simulator

---

## Sintomas

- Alerta `HighErrorRate` ativo no AlertManager
- Dashboard RED mostra error rate acima de 5%
- Logs com `"level":"ERROR"` frequentes no Grafana/Loki

## Diagnóstico (execute em ordem)

### 1. Confirmar o alerta
```bash
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool | grep -A5 "HighErrorRate"
```

### 2. Verificar error rate atual
```bash
curl -sg "http://localhost:9090/api/v1/query?query=sum(rate(traffic_simulator_requests_total{status=~'5..'}[5m]))/sum(rate(traffic_simulator_requests_total[5m]))*100" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('Error rate:', r[0]['value'][1]+'%' if r else '0%')"
```

### 3. Ver distribuição de erros por endpoint
```bash
curl -sg "http://localhost:9090/api/v1/query?query=sum by(path)(rate(traffic_simulator_requests_total{status=~'5..'}[5m]))" \
  | python3 -c "
import json,sys
results = json.load(sys.stdin)['data']['result']
for r in results:
    print(f\"{r['metric'].get('path','?'):30} {float(r['value'][1]):.4f} req/s\")
"
```

### 4. Verificar logs de erro no Loki
```bash
curl -sg --data-urlencode 'query={namespace="default",app="traffic-simulator"} |= "ERROR"' \
  --data-urlencode 'limit=20' \
  --data-urlencode "start=$(date -v-10M +%s)000000000" \
  "http://localhost:3100/loki/api/v1/query_range" \
  | python3 -c "
import json,sys
for s in json.load(sys.stdin)['data']['result']:
    for ts,line in s['values'][-10:]:
        print(line[:300])
"
```

### 5. Verificar pods
```bash
kubectl get pods -l app=traffic-simulator
kubectl logs -l app=traffic-simulator --tail=20 | grep -i error
```

## Causas comuns

| Causa | Indicador | Ação |
|-------|-----------|------|
| Endpoint `/stress/error` sendo chamado | logs com "forced error" | Quem está chamando? Parar o caller |
| Bug no código após deploy | erros em múltiplos endpoints | Rollback: `kubectl rollout undo deployment/traffic-simulator` |
| Dependência externa falhando | erros concentrados num endpoint | Verificar conectividade |
| OOMKill causando restarts | restarts no `kubectl get pods` | Ver runbook: high-memory |

## Remediação

### Se for stress endpoint sendo chamado:
```bash
# Verificar se gerador de tráfego está mandando erros
curl -X POST http://localhost:8080/traffic/stop
```

### Se for bug/deploy ruim:
```bash
# Rollback imediato
kubectl rollout undo deployment/traffic-simulator

# Verificar status
kubectl rollout status deployment/traffic-simulator
```

### Se for problema intermitente:
```bash
# Aumentar replicas temporariamente (reduz impacto)
kubectl scale deployment traffic-simulator --replicas=4
```

## Validação (alerta deve sumir em ~2 minutos)

```bash
# Monitorar error rate caindo
watch -n 5 'curl -sg "http://localhost:9090/api/v1/query?query=sum(rate(traffic_simulator_requests_total{status=~\"5..\"}[2m]))/sum(rate(traffic_simulator_requests_total[2m]))*100" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"data\"][\"result\"]; print(\"Error rate:\", r[0][\"value\"][1]+\"%\" if r else \"0%\")"'
```

## Postmortem

Após resolução, documentar em `docs/postmortems/YYYY-MM-DD-high-error-rate.md`:
- Timeline do incidente
- Causa raiz
- Impacto (duração, % de usuários afetados)
- Ação corretiva
- Como prevenir na próxima vez
