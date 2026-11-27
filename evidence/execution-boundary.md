# Execution environment

Observed on Fedora 45 during development.

| Probe | Observed result |
| --- | --- |
| CPU and memory | 8 logical x86-64 CPUs with VT-x capability. 31 GiB RAM, about 25 GiB available at inspection |
| Storage | 38 GiB free on the project filesystem, 16 GiB tmpfs available |
| Network | The execution namespace exposed loopback only. Netlink and IPv4/Unix socket binding returned operation not permitted. Public package and registry hostnames failed DNS resolution. |
| KVM and libvirt | The session did not expose the KVM device. The read-only system libvirt socket returned operation not permitted. User-session libvirt could not create its runtime directory. |
| SELinux | The sandbox command reported Disabled. Host Enforcing status remains unverified from this view. |
| Podman and Docker | Podman could not use the read-only default runtime. An isolated vfs runtime reached newuidmap and received operation not permitted. The Docker daemon socket denied access. |
| Provisioning tool download | The OpenTofu installer failed resolving its upstream host. Command escalation was rejected by the managed sandbox approval policy. |
| Chromium | Cached Google Chrome for Testing 158 reported its version. Even the standalone data-page process failed at browser startup because socket shutdown was denied. |
| GitHub lookup | The configured GitHub connector returned 404 for the intended repository name. Remote access and Actions history remain unconfirmed. |
| Node and SQLite | Node v22.23.1 and SQLite 3.54.1 executed the application tests. npm's offline audit reported zero third-party dependencies from the lockfile. The registry advisory service was unreachable. |

Guest CPU, memory, storage utilization, and live cluster metrics are pending measurement.
