# Ingress + HTTPS público (Fase 5)

Guia passo a passo pra expor o Grafana do SRE Lab em URL pública com cert
TLS válido emitido pelo Let's Encrypt — usando 1 Load Balancer free do OCI,
ingress-nginx, cert-manager e nip.io.

> **Custo.** 1 Load Balancer flexível do OCI (10 Mbps) é Always Free.
> nip.io é gratuito. Let's Encrypt é gratuito. Resultado: HTTPS público
> em URL própria por **$0/mês**.

---

## Arquitetura

```
                                  Internet
                                     │
                                     ▼
                  ┌─────────────────────────────────┐
                  │ OCI Load Balancer (Flexible 10 Mbps)
                  │ EXTERNAL-IP público
                  └─────────────────────────────────┘
                                     │
                                     ▼ (DNS via nip.io: <ip>.nip.io → IP)
                  ┌─────────────────────────────────┐
                  │ Service ingress-nginx-controller
                  │ namespace: ingress-nginx
                  └─────────────────────────────────┘
                                     │
                  ┌──────────────────┼──────────────────┐
                  ▼                  ▼                  ▼
              Ingress            Ingress            Ingress
              grafana            (futuro)           (futuro)
                  │
                  ▼
              Service kube-prometheus-stack-grafana
              namespace: monitoring

  cert-manager (namespace: cert-manager) provisiona TLS automático via
  Let's Encrypt usando HTTP-01 challenge servido pelo ingress-nginx.
```

---

## Pré-requisitos

- Cluster OKE rodando (ver [`oke-deployment.md`](oke-deployment.md))
- `kubectl`, `helm`, `oci-cli` configurados
- App + observabilidade já instalados (Grafana em `monitoring/kube-prometheus-stack-grafana`)

---

## 1. ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx

KUBECONFIG=~/.kube/config-oci kubectl create namespace ingress-nginx

KUBECONFIG=~/.kube/config-oci helm install ingress-nginx \
  ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f helm/oke/ingress-nginx-values.yaml \
  --wait --timeout 5m
```

Annotations críticas no values (`helm/oke/ingress-nginx-values.yaml`):

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-min: "10"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-max: "10"
```

O `flexible` + min=max=10 Mbps mantém o LB dentro do Always Free. Sem isso,
OCI cria por default um shape pago (100 Mbps).

### Pegar o IP público do LB

```bash
LB_IP=$(KUBECONFIG=~/.kube/config-oci kubectl -n ingress-nginx get svc \
  ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LB IP: $LB_IP"
```

OCI provisiona o LB em **~1 minuto** (mais rápido que AWS ELB).

---

## 2. cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

KUBECONFIG=~/.kube/config-oci kubectl create namespace cert-manager

KUBECONFIG=~/.kube/config-oci helm install cert-manager \
  jetstack/cert-manager \
  -n cert-manager \
  -f helm/oke/cert-manager-values.yaml \
  --wait --timeout 4m
```

CRDs são instaladas pelo chart (`installCRDs: true`).

### ClusterIssuers (staging + prod)

```bash
KUBECONFIG=~/.kube/config-oci kubectl apply \
  -f manifests/oke/ingress/clusterissuer-letsencrypt.yaml
```

Dois issuers são criados:
- **letsencrypt-staging** — pra testar setup sem consumir rate limit
- **letsencrypt-prod** — pra emitir cert real, browser-trusted

> **Importante:** `nip.io` está na [Public Suffix List](https://publicsuffix.org/),
> então cada `<ip>.nip.io` conta como domínio raiz separado pro rate limit
> do Let's Encrypt. Sem risco de bater no limite de outros usuários.

---

## 3. Ingress do Grafana com TLS

O manifest tem placeholder `__LB_IP__` que precisa ser substituído pelo IP
do LB (com pontos virando hífens):

```bash
LB_IP_HYPHEN=$(echo $LB_IP | tr '.' '-')
echo "Hostname: grafana.${LB_IP_HYPHEN}.nip.io"

sed "s/__LB_IP__/${LB_IP_HYPHEN}/g" \
  manifests/oke/ingress/grafana-ingress.yaml | \
  KUBECONFIG=~/.kube/config-oci kubectl apply -f -
```

Anotações importantes no Ingress:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

- `cert-manager.io/cluster-issuer` dispara a emissão do cert via ACME
- `ssl-redirect` força `HTTP 308` redirect pra HTTPS

---

## 4. Aguardar emissão do cert (~30s a 3min)

```bash
KUBECONFIG=~/.kube/config-oci kubectl -n monitoring get certificate grafana-tls -w
```

Quando `READY=True`, o cert está emitido e armazenado no Secret
`grafana-tls`. Cadeia de objetos que o cert-manager cria:

```
Certificate → CertificateRequest → Order → Challenge (HTTP-01)
                                              │
                                              ▼ Let's Encrypt valida
                                              ▼
                                          Secret grafana-tls
```

---

## 5. Validar HTTPS

```bash
# Cabeçalho HTTPS
curl -sI https://grafana.${LB_IP_HYPHEN}.nip.io/login | head -3

# Detalhes do cert
echo | openssl s_client -connect grafana.${LB_IP_HYPHEN}.nip.io:443 \
  -servername grafana.${LB_IP_HYPHEN}.nip.io 2>/dev/null | \
  openssl x509 -noout -subject -issuer -dates

# Redirect HTTP → HTTPS
curl -sI http://grafana.${LB_IP_HYPHEN}.nip.io/ | head -3
```

Resultados esperados:
- `HTTP/2 200` no HTTPS
- `issuer=C=US, O=Let's Encrypt, CN=...`
- `HTTP/1.1 308 Permanent Redirect` no HTTP

**Acesse no navegador:** `https://grafana.<ip-com-hifens>.nip.io`
Cadeado verde, sem aviso de cert inválido.

---

## Troubleshooting

### Cert fica em `READY=False` por mais de 5min

```bash
KUBECONFIG=~/.kube/config-oci kubectl -n monitoring describe certificate grafana-tls
KUBECONFIG=~/.kube/config-oci kubectl -n monitoring get challenges -A
```

Causas comuns:
- DNS ainda não propagou (nip.io é instantâneo, raro)
- LB não está roteando porta 80 (HTTP-01 challenge usa HTTP)
- Rate limit do Let's Encrypt prod (5 cert/semana/raiz — improvável com nip.io)

Mude pro **staging** trocando `letsencrypt-prod` → `letsencrypt-staging` no
Ingress pra debugar. Cert do staging não é browser-trusted mas o fluxo é igual.

### LB fica em `EXTERNAL-IP: <pending>` por mais de 10min

```bash
KUBECONFIG=~/.kube/config-oci kubectl -n ingress-nginx describe svc \
  ingress-nginx-controller
```

OCI pode falhar se:
- Quota de LB já foi consumida (limite é 1 no Always Free)
- Annotations malformadas
- Subnets sem rota pra internet (caso raro — Foundation deste lab já tem)

---

## Custo

| Componente | Custo |
|---|---|
| OCI LoadBalancer Flexible (10/10 Mbps) | **Always Free** (1 instance) |
| nip.io | **Free** (serviço público mantido por SSLip) |
| Let's Encrypt | **Free** (org sem fins lucrativos) |
| Tráfego egress | **Always Free até 10 TB/mês** |

Total: **$0/mês** enquanto o cluster OKE estiver rodando.

---

## Próximos passos sugeridos

- Expor Prometheus em `prom.<ip>.nip.io` (mesma técnica, novo Ingress)
- Expor AlertManager em `am.<ip>.nip.io`
- Adicionar basic auth nas Ingress de Prom/AM (Grafana já tem auth próprio)
- Trocar nip.io por domínio próprio quando comprar um (`renanhermann.dev`?)
