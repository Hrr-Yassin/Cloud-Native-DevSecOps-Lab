# Handoff

The primary lab is in its dedicated KVM guest. The [acceptance matrix](docs/assessment.md) records 90/100 from the available evidence. The disposable profile completed provision, deployment and teardown. Its Docker and K3d runs exercised both outcomes of the workflow deployment step, and both clusters were removed. The [evidence index](evidence/) links to the sanitized results and screenshots. The [operator runbook](docs/runbook.md) covers reproduction.

After approval, create the private GitHub repository, run both workflow fixtures, verify the signed GHCR release and promote its digest to a fresh hosted K3s environment. Import the resulting workflow summary and release evidence into Grafana. Record the repository branch and environment controls that GitHub actually enforces.

The VM, Kubernetes administrative kubeconfig, local signing key, TLS material and portable encrypted backups are scoped to the lab. Use only the dedicated kubeconfig and project-local credentials when resuming. AWS deployment and any SOC-side changes require separate authorization.
