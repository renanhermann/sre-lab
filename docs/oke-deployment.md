# Replicação do stack no OKE (Oracle Kubernetes Engine)

Guia passo a passo pra subir o SRE Lab no OKE, replicando exatamente o que
roda em Minikube — observabilidade, SLO, chaos test e agents.

> **Custos.** Tudo aqui cabe no Always Free do OCI. Único pago se você
> esquecer é o NAT Gateway (~$0.045/h ≈ $32/mês). Rode `./terraform/destroy-cluster.sh`
> quando não usar.

---

## Pré-requisitos

| Ferramenta | Versão testada | Como instalar |
|---|---|---|
| Terraform | 1.7+ | `brew install terraform` |
| OCI CLI | 3.83+ | `brew install oci-cli` |
| `kubectl` | 1.32+ | `brew install kubectl` |
| Helm | 4.1+ | `brew install helm` |
| Docker (com `buildx`) | 29+ | Docker Desktop |

**Conta OCI:** Free Tier ativo, com `~/.oci/config` configurado (`oci setup config`).

---

## 1. Infraestrutura (Terraform)

### 1.1 Foundation (VCN, gateways, subnets)

Só precisa rodar **uma vez** — recursos de rede sobrevivem entre ciclos de cluster.

```bash
cd terraform/00-foundation
cp terraform.tfvars.example terraform.tfvars   # editar com seus OCIDs
terraform init
terraform apply -auto-approve   # ~3 min
```

### 1.2 Cluster OKE + node pool

```bash
cd ../01-oke
cp terraform.tfvars.example terraform.tfvars
# Edite incluindo os outputs do 00-foundation (vcn_id, subnets)
terraform init
terraform apply -auto-approve   # ~10 min (control plane) + ~3 min (node pool)
```

Configuração default:
- K8s `v1.32.1`
- 2× `VM.Standard3.Flex` (Intel x86, 2 OCPU, 8GB RAM cada)
- API server público (`is_public_ip_enabled = true`)

### 1.3 Kubeconfig

```bash
# Comando exato sai como output do terraform: terraform output kubeconfig_command
oci ce cluster create-kubeconfig \
  --cluster-id $(terraform output -raw cluster_id) \
  --file ~/.kube/config-oci \
  --region sa-saopaulo-1 \
  --token-version 2.0.0

# Validar
KUBECONFIG=~/.kube/config-oci kubectl get nodes
```

> **Nota:** o create-kubeconfig faz *merge* no arquivo existente. Se você
> tinha o cluster antigo (destruído), o context novo sobrescreve o anterior.

---

## 2. Observabilidade

### 2.1 kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

KUBECONFIG=~/.kube/config-oci kubectl create namespace monitoring

KUBECONFIG=~/.kube/config-oci helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f helm/oke/kube-prometheus-stack-values.yaml \
  --wait --timeout 8m
```

**Diferenças vs values do Minikube:**
- Grafana e AlertManager **sem persistence** (OCI block volume mínimo é
  50GB por PV; Always Free total é 200GB — reservamos pro Prom e Loki)
- Grafana `service.type: ClusterIP` (acesso via port-forward até Fase 5 ter Ingress+LB)
- `adminPassword` mais forte (cluster com API pública)

### 2.2 Loki + Alloy

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

KUBECONFIG=~/.kube/config-oci kubectl create namespace logging

KUBECONFIG=~/.kube/config-oci helm install loki grafana/loki \
  -n logging -f helm/oke/loki-values.yaml --wait --timeout 5m

KUBECONFIG=~/.kube/config-oci helm install alloy grafana/alloy \
  -n logging -f helm/oke/alloy-values.yaml --wait --timeout 3m
```

**Cuidado com Loki:** ele precisa de filesystem persistente em `/var/loki`
— `persistence.enabled: false` resulta em `mkdir /var/loki: read-only
file system` e CrashLoopBackOff. Por isso o values do OKE liga persistence
(50GB) mesmo desabilitando pra Grafana/AM.

---

## 3. Aplicação (traffic-simulator) — build e push pro OCIR

### 3.1 OCIR Auth Token

OCIR (Oracle Container Registry) é privado por default. Precisa de Auth
Token (não senha do user) pra push e pra ImagePullSecret no K8s.

```bash
# Lista tokens existentes (vazio na primeira vez)
oci iam auth-token list --user-id $(oci iam user list --query 'data[0].id' --raw-output)

# Cria um (capture o output — só aparece uma vez)
oci iam auth-token create \
  --user-id $(oci iam user list --query 'data[0].id' --raw-output) \
  --description "OCIR sre-lab" \
  --query 'data.token' --raw-output > /tmp/ocir-token
chmod 600 /tmp/ocir-token
```

### 3.2 Login no OCIR

```bash
# Pega o namespace OCIR (= namespace de Object Storage do tenancy)
NS=$(oci os ns get --query 'data' --raw-output)

# Login (sa-saopaulo-1 = sua região home do free trial)
cat /tmp/ocir-token | docker login sa-saopaulo-1.ocir.io \
  -u "${NS}/seu-email@dominio.com" --password-stdin

rm /tmp/ocir-token   # token persiste no keychain do macOS após login
```

### 3.3 Build + push (cross-arch ARM → AMD64)

```bash
# OKE rodando em Intel; macOS Apple Silicon precisa cross-build
docker buildx build \
  --platform linux/amd64 \
  -t sa-saopaulo-1.ocir.io/${NS}/sre-lab/traffic-simulator:latest \
  --push \
  app/
```

OCIR cria o repositório `sre-lab/traffic-simulator` automaticamente no primeiro push.

### 3.4 ImagePullSecret no cluster

O Kubernetes precisa de outro token (o anterior foi consumido pelo Docker keychain):

```bash
oci iam auth-token create \
  --user-id $(oci iam user list --query 'data[0].id' --raw-output) \
  --description "OCIR k8s ImagePullSecret" \
  --query 'data.token' --raw-output > /tmp/ocir-token-k8s

KUBECONFIG=~/.kube/config-oci kubectl create secret docker-registry ocirsecret \
  --docker-server=sa-saopaulo-1.ocir.io \
  --docker-username="${NS}/seu-email@dominio.com" \
  --docker-password="$(cat /tmp/ocir-token-k8s)" \
  -n default

rm /tmp/ocir-token-k8s
```

---

## 4. Deploy do app + SLO

```bash
KUBECONFIG=~/.kube/config-oci kubectl apply \
  -f manifests/oke/app/deployment.yaml \
  -f manifests/app/service.yaml \
  -f manifests/app/hpa.yaml \
  -f manifests/app/pdb.yaml \
  -f manifests/app/servicemonitor.yaml \
  -f manifests/app/prometheusrule.yaml \
  -f manifests/slo/availability-slo.yaml \
  -f manifests/slo/latency-slo.yaml \
  -f manifests/slo/grafana-dashboard-slo.yaml
```

**Por que `manifests/oke/app/deployment.yaml` separado?** Só o deployment
muda entre Minikube e OKE (image ref + imagePullPolicy + imagePullSecrets).
Os outros (service, hpa, pdb, servicemonitor, prometheusrule) e os SLOs
são portáveis sem modificação.

---

## 5. Validação ponta a ponta

### 5.1 Port-forwards (Minikube tem `cluster/expose.sh`; aqui é manual por enquanto)

```bash
nohup kubectl --kubeconfig ~/.kube/config-oci -n monitoring \
  port-forward svc/kube-prometheus-stack-prometheus 9090:9090 > /tmp/pf-oke-prom.log 2>&1 &
nohup kubectl --kubeconfig ~/.kube/config-oci -n monitoring \
  port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 > /tmp/pf-oke-am.log 2>&1 &
nohup kubectl --kubeconfig ~/.kube/config-oci -n monitoring \
  port-forward svc/kube-prometheus-stack-grafana 3000:80 > /tmp/pf-oke-grafana.log 2>&1 &
nohup kubectl --kubeconfig ~/.kube/config-oci -n logging \
  port-forward svc/loki 3100:3100 > /tmp/pf-oke-loki.log 2>&1 &
nohup kubectl --kubeconfig ~/.kube/config-oci -n default \
  port-forward svc/traffic-simulator 8080:8080 > /tmp/pf-oke-app.log 2>&1 &
```

### 5.2 Chaos test no OKE

```bash
# Basta apontar o KUBECONFIG; chaos-test.sh cria port-forwards próprios em :18080/:19090
KUBECONFIG=~/.kube/config-oci make chaos-quick
```

Resultado esperado: alerta `SLOAvailabilityFastBurn` em `firing` em ~3 minutos,
cleanup automático, exit 0.

### 5.3 Postmortem do incidente

```bash
# Pegue START/END do output do chaos test e invoque o agent
# > use o postmortem-specialist pra gerar postmortem do "chaos-oke-validation"
#   entre <START> e <END>, severidade SEV2, contexto: validação do stack no OKE
```

---

## 6. Limpeza (parar custos)

```bash
# Destrói só o cluster (foundation/VCN permanecem)
./terraform/destroy-cluster.sh

# Pra destruir TUDO (inclusive NAT Gateway que custa $32/mês)
cd terraform/01-oke && terraform destroy -auto-approve
cd ../00-foundation && terraform destroy -auto-approve
```

> **Auth tokens OCIR** persistem na sua conta OCI mesmo após destruir o
> cluster. Pra limpar: `oci iam auth-token delete --user-id X --auth-token-id Y`,
> ou via console em Identity > Users > Auth Tokens.

---

## 7. Quota do Always Free — onde estamos

| Recurso | Limite | Uso atual deste lab |
|---|---|---|
| Compute (VM.Standard.A1 ARM) | 4 OCPU, 24GB | 0 (usando Standard3 Intel pago — mas dentro de crédito free trial) |
| Compute (VM.Standard.E2.1.Micro) | 2 instâncias | 0 |
| Block Volume | 200GB total | 100GB (50 Prom + 50 Loki) |
| Load Balancer flexível | 1 (10 Mbps) | 0 (Fase 5) |
| Object Storage | 10GB | 0 |
| Outbound transfer | 10TB/mês | desprezível |

**Pro Standard3.Flex (Intel) usado aqui:** consome crédito do Free Trial ($300
em 30 dias), não Always Free. Pra mover pra ARM Always Free (A1.Flex),
trocar `shape` no `terraform/01-oke/variable.tf` (mas mais setup —
imagem precisa ser ARM).
