# Operator runbook

## 1. Start the lab VM

Use a Linux x86-64 workstation with access to the system libvirt daemon and KVM, a working rootless Podman installation, and outbound HTTPS. Have a compatible `kubectl`, Helm 3, `jq`, `flock`, OpenSSL, `mkisofs`, and Python with venv available. Use `virsh --connect qemu:///system list` and `podman info` to establish access before starting. Keep the Fedora host's SELinux policy in its operating mode.

```bash
mkdir -p .lab/bin .lab/local-release
scripts/install-ci-tools.sh "$PWD/.lab/bin" tofu trivy cosign
python3 -m venv .lab/ansible
.lab/ansible/bin/pip install ansible-core==2.20.6
export PATH="$PWD/.lab/bin:$PWD/.lab/ansible/bin:$PATH"
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
kubectl -n lab-observability port-forward --address 127.0.0.1 service/monitor-grafana 3000:80
```

Open `http://127.0.0.1:3000/d/devsecops-lab`. The Grafana administrator username is `admin`. Retrieve the generated password in a private terminal with the command below. Leave the password out of transcripts, screenshots, and exported reports.

```bash
kubectl -n lab-observability get secret lab-grafana-admin \
  -o 'jsonpath={.data.admin-password}' | base64 --decode
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

Install `age` for encrypted exports. Keep the private identity under operator control and save only the public recipient in the project-local recipient file. The export stays on one ready Desk pod throughout snapshot creation and streaming. The restore check opens an isolated copy and verifies SQLite integrity and the finding count. Hosted acceptance performs the encrypted export and restore check before restarting the workload.

```bash
age-keygen -o .lab/backup-identity
age-keygen -y .lab/backup-identity > .lab/backup-recipients
scripts/backup.sh export .lab/backup-recipients .lab/desk-backup.age
scripts/backup.sh restore-check .lab/backup-identity .lab/desk-backup.age
kubectl -n security-desk rollout restart deployment/desk
kubectl -n security-desk rollout status deployment/desk --timeout=120s
```

After the restart, confirm a known synthetic record through the reviewer account. For a guest recovery check, capture the record, restart K3s inside the dedicated VM, and repeat the readiness and record checks. Before any teardown, keep a copy of an approved encrypted backup and the recovery material away from the VM.

```bash
ssh -F .lab/ssh.conf devsecops-lab 'sudo systemctl restart k3s'
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl -n security-desk rollout status deployment/desk --timeout=180s
```

## 5. GitHub validation and promotion

Prepare the GitHub repository under the intended owner. Configure main-branch protection to require the validation check, disallow direct changes from unreviewed branches, and restrict the `release` and `lab` environments to main. Require environment approval where available. Approve public GHCR package access if running the hosted signed-promotion workflow. Use GitHub-hosted runners for public repository workflows.

1. Run **Security gates** from a pull request. Verify the application tests, gate results, disposable cluster creation and teardown, and HTTP check artifact.
2. Manually dispatch the workflow on main with the **compliant** fixture. Confirm success. Repeat with **noncompliant** and verify admission rejected the writable-root fixture and the job failed. Both fixture requests run server-side dry runs.
3. After reviewed main-branch changes, the release job pushes the exact candidate to GHCR, verifies the OIDC-signed digest and CycloneDX attestation, and archives the release evidence.
4. Use the **Promote signed release** dispatch and environment approval to verify that digest and deploy it to a fresh hosted disposable cluster. Archive health, control, and recovery evidence.
5. To promote the same digest to the long-running VM, use the local `scripts/promote.sh` with a short-lived TokenRequest kubeconfig for `lab-promoter`. Retain the CA and loopback server from the lab kubeconfig and replace the admin auth entry with the token. Keep the token in the private `.lab` directory.

```bash
scripts/promote.sh 'ghcr.io/owner/cloud-native-devsecops-lab@sha256:REPLACE_WITH_DIGEST' \
  'owner/Cloud-Native-DevSecOps-Lab'
```

The signature check uses the release workflow path on main and the GitHub OIDC issuer. Public release pulls use anonymous registry access. Private package use needs an explicitly provisioned read-only registry credential.

## 6. Dispose of the local guest

Stop the loopback forwards. Check that the state in `infra/libvirt` contains only the project VM, pool, volumes, and lab network. The command destroys the dedicated guest and its local Kubernetes disks. It also removes the corresponding private client connection files.

```bash
tofu -chdir=infra/libvirt state list
scripts/lab-vm.sh destroy
virsh --readonly --connect qemu:///system list --all --name
```

The workflow archives its cluster deletion result independently.
