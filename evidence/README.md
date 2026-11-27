# Sanitized evidence

## Live lab

| Evidence | Verified scope |
| --- | --- |
| [OpenTofu apply](live/provision.txt) · [K3s node](live/k3s-node.json) · [Teardown plan](live/vm-teardown-plan.json) | Six lab resources created, Ready K3s node and six owned deletes in the destroy plan |
| [Disposable VM lifecycle](live/disposable-vm-lifecycle.json) · [Disposable VM resource sample](live/disposable-vm-resources.txt) | Isolated VM provision, K3s and signed application deployment, six actual deletions and standing VM state preserved |
| [HTTPS](live/vm-https.json) · [Operator view](live/desk-operator.png) · [Reviewer view](live/desk-reviewer.png) · [Chromium report](live/chromium.json) | Real trusted HTTPS, account and session checks, role-separated UI with synthetic data |
| [Live controls](live/kubernetes-controls.txt) · [Deployment gate](live/deployment-gate.json) · [Audit](live/vm-audit.txt) · [Encryption](live/vm-encryption.txt) | Container restrictions, RBAC, resource and network isolation, positive and negative admission results, audit and API Secret encryption |
| [Semgrep](live/semgrep.json) · [Gitleaks fixture](live/secret-fixture.json) · [npm audit](live/npm-audit.json) · [Trivy IaC](live/iac-gate.json) · [Trivy image and SBOM](live/image-gate.json) | Executed local pipeline stages with summarized findings |
| [Docker archive scan](live/docker-image-gate.json) · [K3d workflow deployment step](live/k3d-ci-acceptance.json) · [Workflow action pins](live/workflow-pins.json) | Docker image scan, same archive deployed, compliant run exit 0, deliberate admission rejection exit 1 and both K3d clusters deleted |
| [Archive signature](live/cosign-local.txt) · [Signature rejection](live/vm-signature-rejection.txt) · [OCI registry verification](live/cosign-registry.json) | Verified archive, rejected substitution and verified image digest signature with CycloneDX attestation |
| [Backup](live/vm-backup.jsonl) · [Restored workload](live/vm-restored-workload.json) · [Workload restart](live/vm-restart.json) · [K3s restart](live/k3s-service-recovery.json) | Encrypted export and restore into an isolated live pod. Trusted HTTPS confirmed that the record persisted after both restarts. |
| [Grafana](live/grafana-overview.png) · [Chromium report](live/grafana-overview.json) · [Local CI metrics](live/local-ci-metrics.json) · [Prometheus](live/vm-metrics.json) · [Runtime alert](live/runtime-alertmanager.txt) · [SOC event](live/falco-fixture.jsonl) | Rendered local CI and workload telemetry, verified alert delivery and a minimized example event for external ingestion |
| [VM resource sample](live/vm-resources.txt) · [AWS provider validation](live/aws-validate.txt) | Measured guest resource use and local cloud module validation |

## Development baseline

| Evidence | Execution scope |
| --- | --- |
| [Application tests](app-tests.txt) · [Application resource use](app-resource-use.txt) | HTTP handler, on-disk SQLite, restore, wall time and peak memory |
| [Configuration and telemetry tests](config-and-telemetry-tests.txt) | HTTP over local IPC, manifest contracts, libvirt ownership and safe telemetry filtering |
| [Application CLI](cli-checks.txt) · [Backup orchestration](backup-orchestration.txt) | Account input via stdin, backup inspection and atomic publication |
| [TLS checks](tls-material.txt) · [qcow2 fixture](qcow2-fixture.json) | Certificate and hostname verification and a real synthetic thin-provisioned overlay |
| [Historical sandbox boundary](execution-boundary.md) | Initial access restrictions observed before escalated host execution was available |
