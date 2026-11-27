# Sanitized evidence

| Evidence | Execution scope |
| --- | --- |
| [Application tests](app-tests.txt) | Node HTTP handler with request streams, real on-disk SQLite and an independently opened backup |
| [Application resource use](app-resource-use.txt) | Wall time and maximum resident memory for the Node test command |
| [Configuration and telemetry tests](config-and-telemetry-tests.txt) | Manifest parsing and relationships, report conversion and sanitized SOC output |
| [Application operator CLI](cli-checks.txt) | Account creation from stdin, SQLite backup and independent inspection |
| [TLS certificate checks](tls-material.txt) | OpenSSL CA and leaf generation, exact hostname verification, unrelated hostname rejection, and private key permissions |
| [Environment boundary](execution-boundary.md) | Sanitized results of resource, virtualization, container, browser, and tool probes |

Live application and dashboard screenshots await successful Chromium startup in the deployment environment. Add sanitized captures from synthetic sessions after completing the runbook.
