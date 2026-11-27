# Milestones

| Order | Milestone | Acceptance evidence |
| --- | --- | --- |
| 1 | Host discovery and security desk | Resource inventory, real SQLite tests, browser-rendered frontend if runnable |
| 2 | Isolated infrastructure and workloads | Local VM created and destroyed, configuration checks, RBAC, policy, network, TLS and recovery results |
| 3 | CI security gates and promotion | Expected success and rejection runs, scan reports, SBOM, digest and signature, bounded smoke tests |
| 4 | Runtime and observability | Grafana data, structured logs, Falco rule evidence, alert delivery and optional SOC event contract |
| 5 | AWS mapping and portfolio | Infrastructure validation, diagrams, threat model, acceptance matrix and weighted score |

The target profile assigns the guest 4 vCPUs, 8 GiB of RAM and a 24 GiB thin-provisioned disk. A 4-vCPU runner can use a smaller Kubernetes-only validation profile without the monitoring stack.
