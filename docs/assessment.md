# Acceptance and portfolio assessment

**Verified readiness is 34/100. The 90/100 target remains open.** This score credits working paths exercised in the managed environment and locally checked configuration contracts. Live deployment, external workflow execution, cloud delivery, and screenshots earn zero execution credit until they are observed.

## Acceptance results

| Acceptance item | State | Evidence or blocker |
| --- | --- | --- |
| Infrastructure provisioning and teardown | Blocked | KVM device unavailable and libvirt socket access denied. OpenTofu and Ansible provider execution requires a network-enabled host. |
| Application deployment and Chromium | Blocked | IPv4/Unix socket access prevented a live HTTP listener. K3s and Podman could not start. Chromium failed before rendering a standalone test page. |
| Application behavior | Verified locally | Five Node tests exercised route logic, SQLite, roles, input validation, sessions, rate limiting, structured requests and metrics. A separate test sent HTTP/1.1 bytes through the production Node HTTP parsers over anonymous IPC and verified readiness and separation of metrics from the public routes. [Node output](../evidence/app-tests.txt) · [Regression output](../evidence/config-and-telemetry-tests.txt) |
| Pipeline success and failure | Pending | The GitHub workflows are ready for a dedicated remote. Their intentionally rejected fixture and corrected counterpart have a local structure test. Hosted execution and scanner results are pending. |
| Container security enforcement | Pending | UID, capabilities, seccomp, token, and root-filesystem assertions are in the live K3s script. Image build and execution are blocked by container access and dependency downloads. |
| Kubernetes RBAC and NetworkPolicy | Pending | Scope and wiring were checked offline. Live authorization and connectivity probes require the isolated cluster. |
| Admission policy | Partial | Offline tests proved the fixtures differ only in the writable root and match the binding scope. API-server deny and allow outcomes are pending. |
| Secret detection, image scan, SBOM and signing | Pending | The pipeline uses Gitleaks, Trivy and Cosign. Their binaries and registry access were unavailable in this session. |
| TLS issuance | Verified offline | A trusted lab hostname passed verification and an unrelated hostname failed. The private keys had mode 0600. A live TLS handshake awaits Traefik. [Output](../evidence/tls-material.txt) |
| Runtime alert and live dashboard | Pending | Falco, Alloy, Loki, Prometheus, and Grafana installs require the running cluster. Local tests verified the telemetry import conversion and SOC data minimization. [Output](../evidence/config-and-telemetry-tests.txt) |
| Backup and restoration | Partial | A live SQLite database produced an online backup that reopened independently with the expected record. A shell fixture checked exact-pod selection and atomic destination publication. Both hosted workflows now run the encrypted round trip before restart when they execute. [Shell evidence](../evidence/backup-orchestration.txt) |
| Controlled restart | Partial | Reopening the application and database preserved the record and valid session. Pod and K3s service restart evidence is pending. |
| AWS security extension | Undeployed | Source implements the private network, IAM role, key, secret and audit archive. Provider validation and AWS service delivery remain pending. |

## Weighted score

| Criterion | Earned | Maximum | Basis |
| --- | ---: | ---: | --- |
| Architecture and engineering quality | 10 | 15 | Working application core, tested controls and a documented architecture with local and release entry points |
| Infrastructure reproducibility | 2 | 15 | Checked configuration structure and repeatable TLS material issuance. VM lifecycle and real provider validation remain pending. |
| DevSecOps pipeline | 4 | 20 | Executed application and configuration tests, source checks, and dependency inventory. Hosted security gates and promotion remain pending. |
| Container and Kubernetes security | 2 | 20 | Checked admission fixture scope and ingress versus metrics contracts. No live container or Kubernetes enforcement credit. |
| Runtime security and observability | 2 | 10 | Executed application metric, log redaction, report conversion and normalized SOC paths. Centralized runtime delivery remains pending. |
| Real validation and evidence | 6 | 10 | Real SQLite persistence and restore, HTTP/1.1 integration over anonymous IPC, role and session checks, certificate and qcow2 checks, captured outputs and measured test resources |
| GitHub portfolio quality | 8 | 10 | Dedicated local source, diagrams, threat model, runbook, curated evidence and license. Screenshots and workflow history remain pending. |
| **Total** | **34** | **100** | **Local baseline verified** |

The host exposed 8 logical CPUs, 31 GiB RAM and 38 GiB free project storage. The configured guest requests 4 vCPUs and 8 GiB RAM with a 24 GiB thin-provisioned disk. The Node test command took approximately 8.9 seconds and peaked at 104 MiB RSS. Guest and monitor resource figures remain pending. [Environment](../evidence/execution-boundary.md) · [Resource output](../evidence/app-resource-use.txt)

The repository is suitable for a private validation draft. Public portfolio readiness requires the acceptance artifacts above and a fresh sanitized evidence review.
