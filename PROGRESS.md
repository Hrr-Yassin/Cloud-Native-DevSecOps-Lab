# Progress

| Milestone | Implemented | Executed evidence |
| --- | --- | --- |
| Host and application | Dedicated Git repository, Security Desk frontend and REST API, SQLite, authentication, roles, limits, security headers and monitoring | Host probe and five application tests passed. Backup restore and reopen exercised with SQLite. |
| Infrastructure and workloads | OpenTofu libvirt VM, Ansible, dedicated guest firewall, K3s, RBAC, quotas, ingress, policies and secret generation | Manifest checks and certificate checks passed. VM and live controls are blocked by execution access. |
| Security pipeline | GitHub Actions validation, controlled fixtures, scan and SBOM gates, keyless publishing and controlled promotion | Workflow source parsed. Hosted execution and package verification await a dedicated remote and permitted runner. |
| Runtime and dashboard | Falco, Prometheus, Alertmanager, Grafana, Loki, Alloy, report importer and SOC event exporter | Report and SOC conversion tests passed. The live runtime and dashboard require the provisioned VM. |
| AWS and portfolio | Opt-in Terraform module, README and diagrams, runbook, threat model, assessment, evidence and license | AWS remains undeployed. The weighted assessment uses only observed checks and gives 33/100. |

The managed environment exposed Fedora 45, 8 x86-64 logical CPUs, 31 GiB RAM, and 38 GiB project storage free. Libvirt, KVM, Podman namespaces, Docker, IPv4/Unix binds and public artifact DNS were unavailable to the session. The cached Chromium executable reported its version and failed during startup. The sandbox reported SELinux Disabled, leaving host enforcement pending independent verification. [Sanitized resource and blocker evidence](evidence/execution-boundary.md)
