# Handoff

The lab is running in its dedicated KVM guest. The [acceptance matrix](docs/assessment.md) records 86/100 against the 90/100 target. The [evidence index](evidence/) links to the sanitized local results and screenshots. The [operator runbook](docs/runbook.md) covers operating the VM and reproducing the checks.

Two actions remain for full acceptance.

1. Create the approved GitHub repository, run the compliant and noncompliant workflows, verify the signed GHCR release and promote its digest to a fresh hosted K3s environment. Import the resulting authentic run summary and release evidence into Grafana. Record which repository branch and environment controls the current GitHub plan enforces.
2. Verify the encrypted backup, then apply the lab-owned six-resource destroy plan only after approval. Confirm that the six project resources are absent. Reprovision the guest and verify a Ready node and Desk. Keep the encrypted backup and its private recovery material outside the guest.

The VM, Kubernetes administrative kubeconfig, local signing key, TLS material and portable encrypted backups are scoped to the lab. Use only the dedicated kubeconfig and project-local credentials when resuming. AWS deployment and any SOC-side changes require separate authorization.
