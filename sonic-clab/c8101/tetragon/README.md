# Tetragon on virtualized SONiC (Containerlab c8101)

**A POC collaboration with Cisco DSE Brian Shlisky**

### Architecture

```
Containerlab host
  └── clab-…-leaf00 container (c8000-clab-sonic)
        └── QEMU → SONiC guest  ← Tetragon runs here
```

### Prerequisites

On the **SONiC guest** (one node is enough for a demo, e.g. `leaf00`):

```bash
ssh admin@<sonic-ip>   # password: password

uname -r
test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo NO_BTF
```

Tetragon v1.x requires kernel BTF (`BTF_OK`). Without it, use a SONiC image built with `CONFIG_DEBUG_INFO_BTF`.

### Install (sinle node)

From the Containerlab host:

```bash
cd sonic-clab/c8101/tetragon
chmod +x install-on-sonic.sh start-tetragon.sh tetra.sh stop-tetragon.sh
./install-on-sonic.sh admin@172.20.2.100
```

Optional environment variables:

```bash
SONIC_PASS=password TETRAGON_VERSION=v1.7.0 ./install-on-sonic.sh admin@172.20.2.100
```

The script:

1. Verifies BTF on the guest
2. Downloads `tetragon-v1.7.0-amd64.tar.gz`
3. Installs under `/home/admin/tetragon` on the guest (writable; avoids read-only root issues)
4. Copies helper scripts and the **observe-only** demo policy

#### Manual install (alternative)

On the Containerlab host:

```bash
curl -LO https://github.com/cilium/tetragon/releases/download/v1.7.0/tetragon-v1.7.0-amd64.tar.gz
scp tetragon-v1.7.0-amd64.tar.gz admin@172.20.2.100:/home/admin/
```

On the SONiC guest:

```bash
ssh admin@172.20.2.100
mkdir -p /home/admin/tetragon/policies
tar xf /home/admin/tetragon-v1.7.0-amd64.tar.gz -C /home/admin/tetragon --strip-components=1
# Copy policies and start-tetragon.sh / tetra.sh / stop-tetragon.sh from this repo
chmod +x /home/admin/tetragon/*.sh
```

Avoid `sudo ./install.sh` from the upstream tarball on SONiC unless you know `/usr/local` and `/etc` are writable.

### Start Tetragon and watch events

On the SONiC guest:

```bash
/home/admin/tetragon/start-tetragon.sh
/home/admin/tetragon/tetra.sh getevents -o compact
```

In a second SSH session, run the demo:

```bash
sudo mkdir -p /home/admin/test
echo ok | sudo tee /home/admin/ok.txt              # allowed
echo try | sudo tee /home/admin/test/x.txt         # allowed; observe policy logs the write
```

You should see write events for `/home/admin/test/...` in `tetra getevents`.

If Tetragon fails to start:

```bash
cat /home/admin/tetragon/tetragon-stdout.log
```

### Demo policies

| File | Behavior |
|------|----------|
| `deny-write-home-admin-test-observe.yaml` | Logs writes under `/home/admin/test` only (**default after install**) |
| `deny-write-home-admin-test-enforce.yaml` | Primary enforce (sys_openat + file permission) |
| `deny-write-home-admin-test-enforce-fallback.yaml` | Use if primary enforce prevents Tetragon from starting |

Tetragon in this demo is **allow-by-default**: only matching operations are affected. Everything outside `/home/admin/test` is unchanged.

The enforce policy blocks **`security_inode_create`** (prevent empty file creation) and **`security_file_permission`** (block writes). It does **not** use `sys_openat` — your kernel reports:

`override action not supported on syscalls, bpf_override_return helper not available`

**Do not** put both `deny-write-home-admin-test-enforce.yaml` and `*-fallback.yaml` in `policies/` at once. Keep only one enforce file plus optionally the observe file.

**Do not** use `security_path_truncate` for this demo — it denies after the empty inode already exists.


## Enable blocking (optional)

When ready to enforce, from the Containerlab host:

```bash
scp deny-write-home-admin-test-enforce.yaml admin@172.20.2.100:/home/admin/tetragon/policies/
ssh admin@172.20.2.100
rm /home/admin/tetragon/policies/deny-write-home-admin-test-observe.yaml
sudo rm -f /home/admin/test/*
/home/admin/tetragon/stop-tetragon.sh
/home/admin/tetragon/start-tetragon.sh
```

Test:

```bash
echo blocked | sudo tee /home/admin/test/test1.txt   # Permission denied; file should NOT appear
echo ok | sudo tee /home/admin/test2.txt                 # still works
sudo cp /home/admin/test2.txt /home/admin/test/test2.txt # Permission denied; no copy.txt
ls /home/admin/test                                  # should be empty (or only pre-existing allowed files)
```

### SONiC CLI: allow `show`, block `config`

Policy file: `deny-sonic-config-enforce.yaml` (separate from the `/home/admin/test` file policy).

SONiC `config` and `show` are Python scripts. **`sys_execve` + Sigkill does not block them** on this kernel — binfmt runs the interpreter, so the syscall hook never sees `/usr/local/bin/config` as the executable. Use **`security_bprm_check`** (and `security_bprm_creds_from_file` as backup) with **`Override` / `-13` (EACCES)**, same as the working file policy.

Only load **one** enforce policy type at a time while testing (file *or* config), or keep the file policy in `policies/disabled/` when demoing CLI blocking.

```bash
# Copy updated policy from git, then on leaf00:
cp /home/admin/tetragon/deny-sonic-config-enforce.yaml /home/admin/tetragon/policies/
/home/admin/tetragon/stop-tetragon.sh
/home/admin/tetragon/start-tetragon.sh
```

Verify paths on your image (adjust the YAML if these differ):

```bash
readlink -f "$(which config)"
readlink -f "$(which show)"
head -1 "$(which config)"
```

Optional: load `deny-sonic-config-observe.yaml` first and watch for `security_bprm_check` events with `linux_binprm` path `/usr/local/bin/config` before enabling enforce.

Demo:

```bash
show ip interfaces status          # allowed
show vlan brief                    # allowed
sudo config interface ip add Ethernet16 9.9.9.1/24   # Permission denied; IP should NOT appear
show ip int                        # Ethernet16 unchanged
```

Use `deny-sonic-config-observe.yaml` first if you want to confirm matches in `tetra getevents` without blocking.

**Caution:** this blocks **every** `config` invocation, including `config load` / `config save` and Ansible playbooks that call `config`. Remove the policy from `policies/` before running automation.

### Outbound SSH: block lateral movement to other lab nodes

Policy files: `deny-outbound-ssh-sonic-lab-enforce.yaml` (and `-observe.yaml`).

Blocks **outbound** TCP connections to port **22** on the c8101 management subnet (`172.20.2.0/24` — leaf00–leaf02, spine00–spine01 per `topology.yaml`). A compromised node cannot `ssh admin@172.20.2.101` to pivot to another switch.

- **Inbound SSH** (you logging into leaf00) is **not** affected — only `connect()` attempts from processes on the node.
- **Other traffic** (BGP, ping, HTTPS, SSH to hosts outside `172.20.2.0/24`) is unchanged.
- Can run **alongside** the file and config policies (different hooks).

```bash
cp /home/admin/tetragon/deny-outbound-ssh-sonic-lab-enforce.yaml /home/admin/tetragon/policies/
/home/admin/tetragon/stop-tetragon.sh
/home/admin/tetragon/start-tetragon.sh
```

Demo (from leaf00, after enforce is loaded):

```bash
ssh -o StrictHostKeyChecking=no admin@172.20.2.101   # Connection refused / Permission denied
nc -vz 172.20.2.101 22                             # also blocked (any TCP/22 to lab mgmt)
ping 172.20.2.101                                  # still allowed (ICMP)
curl -s --connect-timeout 2 https://example.com    # still allowed (not port 22)
```

Use `-observe.yaml` first to confirm `security_socket_connect` events in `tetra getevents` before enforcing.

**Note:** this also blocks **you** from SSH'ing *out* from leaf00 to other lab nodes while the policy is active. Remove from `policies/` when you need cross-node SSH from the guest.

### Stop / rollback

```bash
/home/admin/tetragon/stop-tetragon.sh
```

### Tetra CLI to see policies

Overview
```bash
/home/admin/tetragon/tetra.sh tracingpolicy list
```

For more detail
```bash
/home/admin/tetragon/tetra.sh tracingpolicy list -o json | jq
```



Remove policies from `/home/admin/tetragon/policies/` and restart, or delete `/home/admin/tetragon` to fully uninstall.

## Files in this directory

| File | Purpose |
|------|---------|
| `install-on-sonic.sh` | Deploy from Containerlab host to a SONiC guest |
| `start-tetragon.sh` | Start daemon on guest (installed to `/home/admin/tetragon/`) |
| `tetra.sh` | CLI wrapper for `getevents`, `tracingpolicy add/delete`, etc. |
| `stop-tetragon.sh` | Stop daemon |
| `deny-write-home-admin-test-observe.yaml` | Observe-only file policy |
| `deny-write-home-admin-test-enforce.yaml` | Enforce file policy (`/home/admin/test`) |
| `deny-write-home-admin-test-enforce-fallback.yaml` | File enforce without `security_inode_create` |
| `deny-sonic-config-observe.yaml` | Observe SONiC `config` exec |
| `deny-sonic-config-enforce.yaml` | Block SONiC `config` exec; allow `show` |
| `deny-outbound-ssh-sonic-lab-observe.yaml` | Observe outbound TCP/22 to lab mgmt net |
| `deny-outbound-ssh-sonic-lab-enforce.yaml` | Block outbound SSH to other c8101 nodes |

### Tips

- Always start with the **observe** policy before enabling **enforce**.
- Re-run `./install-on-sonic.sh` if a previous run failed partway through (e.g. before helper scripts were added).

### Troubleshooting: Tetragon exits immediately

If `start-tetragon.sh` reports success but `ps` shows no tetragon and `tetra getevents` gets **connection refused**, a policy in `policies/` failed to load and the daemon exited.

1. Re-run start (updated script prints the log tail):

```bash
/home/admin/tetragon/start-tetragon.sh
```

2. Or read the log directly:

```bash
tail -40 /home/admin/tetragon/tetragon-stdout.log
```

3. **Recover** — keep a single enforce policy in `policies/`:

```bash
mkdir -p /home/admin/tetragon/policies/disabled
mv /home/admin/tetragon/policies/deny-write-home-admin-test-enforce-fallback.yaml \
   /home/admin/tetragon/policies/disabled/ 2>/dev/null || true
# Update enforce.yaml from git (no sys_openat), then:
cp /home/admin/tetragon/deny-write-home-admin-test-enforce.yaml \
   /home/admin/tetragon/policies/
/home/admin/tetragon/stop-tetragon.sh
/home/admin/tetragon/start-tetragon.sh
```

4. **Syscall Override not available** on this SONiC image — `sys_openat` + `Override` will always fail. Security hooks (`security_*`) still work.

### Quick demo script

1. Logging on terminal one
```bash
/home/admin/tetragon/tetra.sh getevents -o compact
```

2. Filesystem enforcement
```bash
echo blocked | sudo tee /home/admin/test/test1.txt   
echo ok | sudo tee /home/admin/test2.txt                
sudo cp /home/admin/test2.txt /home/admin/test/test2.txt 
ls /home/admin/test                                  
```

3. CLI enforcement
```bash
show ip interfaces
sudo config ip remove Ethernet16 9.9.9.1/24 
```

4. Outbound ssh
```bash
ip route
ssh 10.1.1.0
ssh 10.0.0.1
```

5. List policies
```bash
/home/admin/tetragon/tetra.sh tracingpolicy list
```