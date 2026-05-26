# SRE Lab

Laboratório pessoal de SRE — observabilidade, GitOps e operação de Kubernetes na prática.

## Stack

| Camada | Tecnologia |
|---|---|
| K8s local | Minikube (driver Docker) |
| Métricas | kube-prometheus-stack (Prometheus + Grafana + AlertManager) |
| Logs | Grafana Loki + Alloy |
| App de teste | (a definir) — gerador de tráfego com endpoints de stress |
| Automação | Claude Code (skills + agents) |

## Roadmap

- [ ] Fase 1 — Cluster local + observabilidade + app de teste
- [ ] Fase 2 — Migração pra Oracle Cloud (OKE) via Terraform
- [ ] Fase 3 — Diferencial sênior: SLO formal, error budget, runbook executável, postmortem flow, chaos test, FinOps

## Estrutura

```
sre-lab/
├── cluster/      # scripts pra subir/derrubar Minikube
├── manifests/    # manifests Kubernetes da aplicação e alertas
├── helm/         # values customizados dos charts
├── docs/         # runbooks, SLOs, postmortem template
└── .claude/      # agents e skills do Claude Code
```

## Como subir

```bash
./cluster/start.sh
```

## Como derrubar (sem perder dados)

```bash
minikube stop -p sre-lab
```

## Como destruir (apaga tudo)

```bash
minikube delete -p sre-lab
```
