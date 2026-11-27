# Progress

| Milestone | Status | Verified evidence |
| --- | --- | --- |
| Host and application | Verified | The dedicated host path provided KVM and libvirt access, rootless Podman, sockets and outbound HTTPS. Security Desk passed application tests, trusted HTTPS behavior and Chromium operator and reviewer flows. |
| Infrastructure and workloads | Provisioned and deployed | OpenTofu created six dedicated libvirt resources. Ansible configured K3s. Live RBAC, NetworkPolicy, admission, quotas, secret encryption and audit checks passed. The teardown plan passed its ownership review. |
| Security pipeline | Local gates verified | Semgrep, Gitleaks, npm audit, OpenTofu, Trivy scans and CycloneDX generation executed. The corrected and intentionally rejected Kubernetes fixtures reached their expected gate outcomes. Cosign verified the archive and a registry-backed manifest and attestation. Hosted Actions and promotion are pending. |
| Runtime and dashboard | Verified on VM | A bounded Falco fixture reached Loki and Alertmanager, Prometheus exposed the expected counters, and Chromium rendered live Grafana data. The hosted pipeline telemetry panels await a real run import. |
| Recovery | Verified on VM | The encrypted SQLite backup reopened independently and started a fresh Desk pod on an isolated volume. The remediation record survived a workload rollout and K3s restart. |
| AWS and portfolio | Prepared | Provider and IaC validation passed locally. AWS remains undeployed. The current evidence supports 86/100. |

The existing ARIA, SOC and Active Directory infrastructure was undisturbed. [Acceptance matrix](docs/assessment.md) · [Evidence index](evidence/)
