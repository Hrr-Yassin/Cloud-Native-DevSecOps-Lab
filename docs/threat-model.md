# Threat model

## Assets

The SQLite database holds findings, remediation status, password hashes, and expiring session digests. Kubernetes contains the session HMAC key and ingress leaf key. The workstation holds the local TLS CA, client and backup keys, provider state, and local signing material. The release pipeline carries a tested image, SBOM, and workflow identity.

| Threat | Control | Validation evidence |
| --- | --- | --- |
| Unauthorized finding reads or changes | Session validation, administrator role on writes, SameSite cookie, exact Origin and session-bound CSRF | Request-handler tests passed for denied reads and changes, allowed operator actions, logout and expiration |
| Password guessing or session fixation | scrypt, bounded authentication work, per-account throttling, rotated random session tokens with stored digests | In-process throttle, rotation, expiration and revocation tests passed |
| Unsafe data in the browser or database | Text-only DOM rendering, fixed field validation and bound SQL | Source reviewed, input-boundary tests passed, browser and Semgrep execution pending |
| Public exposure and lateral movement | Host-only port-forwards, guest uplink rules, independent application and metrics services, default-deny pod ingress and egress | TLS SAN positive and negative checks passed, runtime network isolation pending |
| Overprivileged workload or workload tampering | Restricted PSS, native admission, scoped RBAC, zero capabilities, non-root UID, read-only root, resource quotas | Fixture structure and policy binding checked offline, Kubernetes enforcement pending |
| Vulnerable or substituted build | Pinned tools and base images, workflow permissions, image scan gate, exact digest and Cosign certificate identity | Workflow source reviewed, hosted runs and live registry verification pending |
| Lost or corrupted data after restart | WAL, one writer workload, online backup, integrity check, encrypted portable backup workflow | Restore to independent SQLite file and reopen passed, K3s and encrypted recovery pending |
| Missing or misleading operational evidence | Metadata-only audit policy, no raw session fields in app logs, allowlisted report labels and SOC fields | App log redaction and SOC/report conversion tests passed, centralized logging and delivery pending |

## Accepted limitations

- The VM is both a workload and control-plane failure domain. Local-path storage and the SQLite workload use a single replica.
- A compromised guest administrator can access local data, secrets, or integrity controls. Encryption protects Kubernetes Secret content in the datastore. Availability and host disk encryption depend on the workstation.
- Short-lived promotion credentials can patch one Deployment. The holder still has the implications of changing that workload. The controlled promotion command verifies image and SBOM identity. Native admission checks the digest and security settings.
- The application uses local accounts and does not integrate an identity provider, MFA, or automated password reset.
- Falco and host exporters have elevated guest visibility. Observability inputs and audit data remain local. The normalizer strips identifiers before optional SOC import.
- The safety of GitHub publication depends on branch protection, environment reviewers, package permissions, and whether the actual workflow gates have passed.
