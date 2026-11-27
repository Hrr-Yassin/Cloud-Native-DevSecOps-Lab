# Progress

| Milestone | Status | Verified evidence |
| --- | --- | --- |
| Host and application | Verified | The dedicated host path provided KVM and libvirt access, rootless Podman, sockets and outbound HTTPS. Security Desk passed application tests, trusted HTTPS behavior and Chromium operator and reviewer flows. |
| Infrastructure and workloads | Provision, deployment and disposable teardown verified | The primary and disposable profiles booted with OpenTofu and Ansible. The disposable guest reached Ready and deployed the signed image, then removed all six owned resources. The primary VM identity and state were preserved. |
| Security pipeline | Local gates and Docker/K3d workflow deployment step verified | Semgrep, Gitleaks, npm audit, OpenTofu, Trivy and CycloneDX generation executed. The corrected and intentionally rejected fixtures returned 0 and 1 on Docker and K3d, and both clusters were deleted. Cosign verified the archive and a registry-backed image and attestation. Hosted Actions and promotion are pending. |
| Runtime and dashboard | Verified on VM | A bounded Falco fixture reached Loki and Alertmanager. Prometheus exposed the runtime counters and the verified local CI status, scan and SBOM. Chromium rendered those values with source labels. Hosted telemetry awaits a run import. |
| Recovery | Verified on VM | The encrypted SQLite backup reopened independently and started a fresh Desk pod on an isolated volume. The remediation record survived a workload rollout and K3s restart. |
| AWS and portfolio | Prepared | Provider and IaC validation passed locally. AWS remains undeployed. The current evidence supports 90/100. |

The existing ARIA, SOC and Active Directory infrastructure was undisturbed. [Acceptance matrix](docs/assessment.md) · [Evidence index](evidence/)
