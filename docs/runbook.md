# Operator runbook

## 1. Start the lab VM

Use a Linux x86-64 workstation with access to the system libvirt daemon and KVM, a working rootless Podman installation, and outbound HTTPS. Have a compatible `kubectl`, Helm 3, `jq`, `flock`, OpenSSL, `mkisofs`, and Python with venv available. Use `virsh --connect qemu:///system list` and `podman info` to establish access before starting. Keep the Fedora host's SELinux policy in its operating mode.

```bash
mkdir -p .lab/bin .lab/local-release
scripts/install-ci-tools.sh "$PWD/.lab/bin" tofu kubectl helm uv trivy cosign age
export UV_PYTHON_INSTALL_DIR="$PWD/.lab/python" UV_CACHE_DIR="$PWD/.lab/uv-cache"
.lab/bin/uv venv --python 3.13.13 "$PWD/.lab/host-tools"
.lab/bin/uv pip install --python "$PWD/.lab/host-tools/bin/python" ansible-core==2.20.6
export PATH="$PWD/.lab/bin:$PWD/.lab/host-tools/bin:$PATH"
export TRIVY_CACHE_DIR="$PWD/.lab/trivy-cache" ANSIBLE_LOCAL_TEMP="$PWD/.lab/ansible-tmp"
scripts/lab-vm.sh up
scripts/lab-vm.sh configure
```

On the first connection the isolated guest's SSH key is recorded in a lab-only known-hosts file. Future CLI connections check the stored key. Check routing on the workstation and use the default guest CIDR if available. Set `LAB_GUEST_NETWORK` to an unused 172.16.0.0/12 slice of size /24 before the first provision. Keep that value for teardown. The wrapper serializes VM operations and verifies live libvirt object IDs and volume ownership against local state before changing resources.

Keep the API tunnel running in a separate terminal. In each lab administration terminal use the dedicated kubeconfig.

```bash
scripts/lab-vm.sh tunnel
```

```bash
export KUBECONFIG="$PWD/.lab/admin.kubeconfig"
kubectl get nodes
ssh -F .lab/ssh.conf devsecops-lab 'sudo k3s secrets-encrypt status'
```

## 2. Deploy and access Security Desk

Generate a dedicated passphrase-protected local signing key. Its public key is the local release trust anchor. The release script builds through rootless Podman, runs Trivy and SBOM generation, verifies the signed OCI archive, imports it into containerd in the guest, and deploys by digest.

```bash
cosign generate-key-pair --output-key-prefix .lab/local-release/signing
scripts/local-release.sh
```

Use `scripts/local-release.sh prepare` to build, scan, and sign on a host before the cluster starts. Run `scripts/local-release.sh deploy` to verify and deploy the prepared archive once the tunnel is running. The host build uses a project-specific Podman image store.

The separate [registry evidence](../evidence/live/cosign-registry.json) used a temporary loopback registry and `skopeo copy --preserve-digests` to publish the prepared OCI archive without changing its digest. `cosign sign` and `cosign attest --type cyclonedx` used the lab key and an empty signing config from `cosign signing-config create`. Verification used the lab public key with local HTTP and transparency-log exceptions scoped to the loopback test. The hosted verification commands require the GitHub OIDC issuer and the release workflow identity. [Cosign signing config](https://docs.sigstore.dev/cosign/system_config/custom_components/)

Create application accounts with the CLI. Supply each password through stdin. Use synthetic findings and role accounts when collecting shareable evidence.

```bash
read -rs -p 'Lab operator password: ' desk_password
printf '\n'
printf '%s\n' "$desk_password" |
  kubectl -n security-desk exec -i deployment/desk -- node app/cli.mjs user operator admin
unset desk_password

read -rs -p 'Lab reviewer password: ' desk_password
printf '\n'
printf '%s\n' "$desk_password" |
  kubectl -n security-desk exec -i deployment/desk -- node app/cli.mjs user reviewer viewer
unset desk_password
```

Keep the ingress forward running separately. Then verify the TLS chain and hostname against the private CA.

```bash
kubectl -n kube-system port-forward --address 127.0.0.1 service/traefik 8443:443
```

```bash
curl --fail --noproxy '*' --cacert .lab/tls/ca.crt \
  --resolve desk.lab.invalid:8443:127.0.0.1 https://desk.lab.invalid:8443/readyz
scripts/check-controls.sh "$(cat .lab/local-release/image.ref)"
```

Chromium can use a dedicated profile with a pin derived from the verified leaf and a loopback-only hostname mapping. Sign in as the operator, add and resolve a synthetic finding, then sign in as the reviewer and confirm the status. Capture those views only after removing browser chrome, private URLs, and user or machine identifiers from the frame.

The hosted acceptance job drives Chromium against its disposable lab and archives operator and reviewer PNGs. The job verifies the lab CA and hostname before launching, and captures the page only when the expected single synthetic remediation record is visible. Browser acceptance runs with the browser's normal sandbox. [GitHub Ubuntu runner software](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md#browsers-and-drivers)

```bash
desk_pin=$(openssl x509 -in .lab/tls/desk.crt -pubkey -noout |
  openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64 -A)
chromium --user-data-dir="$PWD/.lab/chromium-desk" --no-proxy-server \
  --host-resolver-rules='MAP desk.lab.invalid 127.0.0.1' \
  --ignore-certificate-errors-spki-list="$desk_pin" https://desk.lab.invalid:8443
```

Run the deploy script again to refresh an expiring leaf before its trust anchor expires. For CA rotation, issue new material in a separate private directory, verify the new CA and leaf, deploy with `LAB_TLS_DIR` pointing to that directory, and update client trust.

## 3. Collect runtime and observability evidence

```bash
scripts/observability.sh
scripts/runtime-check.sh
kubectl -n lab-observability port-forward --address 127.0.0.1 service/monitor-grafana 13000:80
```

Open `http://127.0.0.1:13000/d/devsecops-lab`. The Grafana administrator username is `admin`. To verify browser rendering after creating and resolving one high-severity finding and running the Falco fixture, use the automated check. Set `CHROMIUM` to the path of a Chromium executable.

```bash
(
  umask 077
  password_file=$(mktemp "$PWD/.lab/grafana-password.XXXXXXXX")
  trap 'rm -f -- "$password_file"' EXIT
  kubectl -n lab-observability get secret lab-grafana-admin \
    -o 'jsonpath={.data.admin-password}' | base64 --decode > "$password_file"
  node scripts/dashboard-acceptance.mjs "${CHROMIUM:?Set the Chromium executable path}" \
    "$password_file" .reports/dashboard
)
```

The runtime check matches one newly generated marker in Falco and Loki, checks the Prometheus counter and requires a fresh Alertmanager notification. Successful checks write a dedicated directory under `.reports/runtime-check.XXXXXXXX`. Check the available replica count, resource panels, remediation counts, audit denials, and Falco warnings. Grafana shows no imported CI value until the operator imports an actual workflow report. To import a completed run, download its `lab-security-report` artifact from the repository. For a signed result, download `lab-signed-release` from the same run. Check the run and workflow identity in GitHub first. Use a loopback forward to the Pushgateway.

```bash
kubectl -n lab-observability port-forward --address 127.0.0.1 service/lab-ci 19091:9091
```

```bash
python3 scripts/pipeline-metrics.py --report .reports/summary.json --push
# For the same run that published a signed artifact:
python3 scripts/pipeline-metrics.py --report .reports/summary.json --release .reports/release.json --push
```

For portable SOC output, run the exporter against approved application, Falco, or audit JSON lines. It emits the timestamp, source, class, and severity. The existing SOC's Wazuh agent supports JSON collection, so an administrator could add a purpose-specific `localfile` mapping to receive the normalized stream. The exporter runs in this repository and writes NDJSON to stdout. SOC-side changes require separate authorization. [Wazuh JSON localfile support](https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/localfile.html)

```bash
kubectl -n security-desk logs deployment/desk --since=5m |
  python3 scripts/export-soc-events.py --source desk > .reports/desk-events.jsonl
```

For resource usage, record `kubectl top nodes` and `kubectl top pods -n lab-observability`. Read the dedicated guest filesystem with `ssh -F .lab/ssh.conf devsecops-lab 'df -h /'`. Preserve only counts and capacity figures in portfolio evidence.

## 4. Backup, restore and recover

Install `age` for encrypted exports. Keep the private identity under operator control and save only the public recipient in the project-local recipient file. The export stays on one ready Desk pod throughout snapshot creation and streaming. The restore check opens an isolated copy and verifies SQLite integrity and the finding count. The restore probe starts a temporary Desk pod with an empty volume and compares the restored finding count with that instance's metrics.

```bash
age-keygen -o .lab/backup-identity
age-keygen -y .lab/backup-identity > .lab/backup-recipients
scripts/backup.sh export .lab/backup-recipients .lab/desk-backup.age
scripts/backup.sh restore-check .lab/backup-identity .lab/desk-backup.age
scripts/backup.sh restore-probe .lab/backup-identity .lab/desk-backup.age
kubectl -n security-desk rollout restart deployment/desk
kubectl -n security-desk rollout status deployment/desk --timeout=120s
```

After the restart, confirm a known synthetic record through the reviewer account. For a guest recovery check, capture the record, restart K3s inside the dedicated VM, and repeat the readiness and record checks. Reopen any port forwards that closed during the restart. Before any teardown, keep a copy of an approved encrypted backup and the recovery material away from the VM.

```bash
ssh -F .lab/ssh.conf devsecops-lab 'sudo systemctl restart k3s'
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl -n security-desk rollout status deployment/desk --timeout=180s
```

## 5. GitHub validation and promotion

Prepare the GitHub repository under the intended owner. Configure main-branch protection to require the validation check, disallow direct changes from unreviewed branches, and restrict the `release` and `lab` environments to main where the plan offers those settings. Require environment approval where available. Grant the repository Actions access to its GHCR package. The hosted promotion runner uses a short-lived read token for private image verification and pull access. [GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) · [GitHub deployment environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

1. Run **Security gates** from a pull request. Verify the application tests, gate results, disposable cluster creation and teardown, and HTTP check artifact.
2. Manually dispatch the workflow on main with the **compliant** fixture. Confirm success. Repeat with **noncompliant** and verify admission rejected the writable-root fixture and the job failed. Both fixture requests run server-side dry runs.
3. After reviewed main-branch changes, the release job pushes the exact candidate to GHCR, verifies the OIDC-signed digest and CycloneDX attestation, and archives the release evidence.
4. Use the **Promote signed release** dispatch and environment approval to verify that digest and deploy it to a fresh hosted disposable cluster. Archive health, control, and recovery evidence.
5. To promote the same digest to the long-running VM, use the local `scripts/promote.sh` with a short-lived TokenRequest kubeconfig for `lab-promoter`. Retain the CA and loopback server from the lab kubeconfig and replace the admin auth entry with the token. Keep the token in the private `.lab` directory.

From an authenticated, authorized GitHub CLI session, the initial private push and explicit fixture dispatches use:

```bash
gh repo create Hrr-Yassin/Cloud-Native-DevSecOps-Lab --private --source=. --remote=origin --push
gh workflow run security.yml --ref main -f policy_fixture=compliant
gh workflow run security.yml --ref main -f policy_fixture=noncompliant
gh run list --workflow security.yml --limit 6
gh run view "$RELEASE_RUN_ID" --exit-status
gh run download "$RELEASE_RUN_ID" --name lab-signed-release --dir .reports/hosted-release
gh workflow run promote.yml --ref main -f image="$(jq -er .image .reports/hosted-release/release.json)"
```

The initial main push schedules the signed release job after validation. Set `RELEASE_RUN_ID` from that run and check the expected success and failure conclusions of the two fixture dispatches separately.

```bash
scripts/promote.sh 'ghcr.io/owner/cloud-native-devsecops-lab@sha256:REPLACE_WITH_DIGEST' \
  'owner/Cloud-Native-DevSecOps-Lab'
```

The signature check uses the release workflow path on main and the GitHub OIDC issuer. For an operator-side promotion of a private release, provision the lab’s read-only GHCR credential before changing the workload image.

## 6. Dispose of the local guest

Stop the loopback forwards. Check that the state in `infra/libvirt` contains only the project VM, pool, volumes, and lab network. The command destroys the dedicated guest and its local Kubernetes disks. It also removes the corresponding private client connection files.

```bash
tofu -chdir=infra/libvirt state list
scripts/lab-vm.sh destroy
test "$(python3 infra/libvirt/preflight.py infra/libvirt/terraform.tfstate up)" = absent
```

The workflow archives its cluster deletion result independently.
