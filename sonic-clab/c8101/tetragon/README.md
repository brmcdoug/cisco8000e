# Tetragon on virtualized SONiC (Containerlab c8101)

Run [Cilium Tetragon](https://tetragon.io/) **inside the SONiC guest OS** (the VM you reach with `ssh admin@172.20.2.100`), not on the Containerlab host or outer `c8000-clab-sonic` container.

## Architecture

```
Containerlab host
  └── clab-…-leaf00 container (c8000-clab-sonic)
        └── QEMU → SONiC guest  ← Tetragon runs here
```

Policy paths (e.g. `/home/admin/test`) are **guest paths** on the emulated switch.

## Prerequisites

On the **SONiC guest** (one node is enough for a demo, e.g. `leaf00`):

```bash
ssh admin@172.20.2.100   # password: password

uname -r
test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo NO_BTF
```

Tetragon v1.x requires kernel BTF (`BTF_OK`). Without it, use a SONiC image built with `CONFIG_DEBUG_INFO_BTF`.

On the **Containerlab host**:

- Outbound HTTPS (to download the Tetragon release tarball)
- `sshpass` (or edit `install-on-sonic.sh` to use SSH keys)
- Containerlab topology deployed (`clab deploy -t topology.yaml`)

## Install (one node)

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

### Manual install (alternative)

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

## Start Tetragon and watch events

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

## Demo policies

| File | Behavior |
|------|----------|
| `deny-write-home-admin-test-observe.yaml` | Logs writes under `/home/admin/test` only (**default after install**) |
| `deny-write-home-admin-test-enforce.yaml` | Denies writes there with `Override` / `-EACCES` (not `Sigkill`) |

Tetragon is **allow-by-default**: only matching operations are affected. Everything outside `/home/admin/test` is unchanged.

## Enable blocking (optional)

When ready to enforce, from the Containerlab host:

```bash
scp deny-write-home-admin-test-enforce.yaml admin@172.20.2.100:/home/admin/tetragon/policies/
ssh admin@172.20.2.100
rm /home/admin/tetragon/policies/deny-write-home-admin-test-observe.yaml
/home/admin/tetragon/stop-tetragon.sh
/home/admin/tetragon/start-tetragon.sh
```

Test:

```bash
echo blocked | sudo tee /home/admin/test/nope.txt   # Permission denied
echo ok | sudo tee /home/admin/ok.txt               # still works
sudo cp /home/admin/ok.txt /home/admin/test/copy.txt # blocked (write to test dir)
```

## Stop / rollback

```bash
/home/admin/tetragon/stop-tetragon.sh
```

Remove policies from `/home/admin/tetragon/policies/` and restart, or delete `/home/admin/tetragon` to fully uninstall.

## Files in this directory

| File | Purpose |
|------|---------|
| `install-on-sonic.sh` | Deploy from Containerlab host to a SONiC guest |
| `start-tetragon.sh` | Start daemon on guest (installed to `/home/admin/tetragon/`) |
| `tetra.sh` | CLI wrapper for `getevents`, `tracingpolicy add/delete`, etc. |
| `stop-tetragon.sh` | Stop daemon |
| `deny-write-home-admin-test-observe.yaml` | Observe-only policy |
| `deny-write-home-admin-test-enforce.yaml` | Enforce policy |

## Tips

- Use **one node** (`leaf00` / `172.20.2.100`) for the demo.
- Always start with the **observe** policy before enabling **enforce**.
- Re-run `./install-on-sonic.sh` if a previous run failed partway through (e.g. before helper scripts were added).
