# Handoff

The working repository is `Cloud-Native-DevSecOps-Lab`. Development and check outputs are indexed in [evidence](evidence/). Current weighted readiness is 34/100. The [acceptance assessment](docs/assessment.md) specifies where the target remains open.

Resume on a network-enabled workstation session with KVM, libvirt, rootless Podman, and working sockets. Follow the [runbook](docs/runbook.md) for the dedicated VM, locally signed build, Kubernetes controls, live browser and dashboard verification, runtime alert, encrypted restore, service restart and teardown. Record actual guest resource use and sanitize UI captures and logs before adding evidence.

A dedicated GitHub repository can then run the hosted compliant and noncompliant workflows, publish the signed release, and validate controlled promotion. Complete the score from the resulting artifacts. AWS and SOC-side deployments require separate authorization.
