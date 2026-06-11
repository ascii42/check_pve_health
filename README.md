# check_pve_health

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Monitoring](https://img.shields.io/badge/Monitoring-Icinga%2FNagios-blue.svg)](https://icinga.com/)
[![Version](https://img.shields.io/badge/version-1.4.0-orange.svg)](CHANGELOG.md)

A comprehensive Bash-based monitoring plugin for Proxmox Virtual Environment (PVE), compatible with Icinga and Nagios monitoring systems. This plugin monitors cluster health, nodes, virtual machines, containers, storage, subscriptions, replication, services, task logs, and more — directly via the Proxmox REST API. No agent or additional software required on the PVE hosts.

## Features

- **Direct API Access**: Connects to the PVE REST API (`https://<host>:8006/api2/json/`) — no agent, no SSH required
- **Cluster-Aware**: Automatically discovers all nodes in a PVE cluster; optionally restrict checks to a single node with `--node`
- **VM & Container Monitoring**: QEMU VM and LXC container status, resource thresholds, guest agent check, snapshot and replication details
- **Detailed Guest Metrics**: Real-time CPU%, memory%, swap%, disk%, disk I/O rates, and network rates via PVE rrddata (1-min averages)
- **Storage Checks**: Per-pool usage with percentage or free-bytes thresholds
- **Systemd Service Monitoring**: Per-node service states via the PVE services API, with configurable blacklists
- **Task Log Watch**: Scans recent PVE task history for errors and warnings across a configurable time window; filterable to a single VM/CT
- **Snapshot & Replication**: Age and count checks for VM/CT snapshots; replication job status, last-sync age, and error detection
- **Backup Monitoring**: Last backup age per VM/CT
- **Update Awareness**: Available package updates per node, with separate security-update threshold
- **PSI Support**: CPU/memory/IO pressure stall indicators (PVE 8.1+, Linux kernel 4.20+)
- **Flexible Authentication**: API token (recommended) or username/password
- **Opt-in Checks**: Use `-eX` flags to run only the modules you need, or `-A` for everything
- **Opt-out Suppression**: `--disable-X` flags to skip individual modules when using `-A`
- **Granular Thresholds**: Per-metric warn/crit for CPU, memory, swap, disk, load, network rates, snapshot age/count, replication age, backup age, time drift, SSD wearout, and more
- **Blacklisting**: Skip specific VMs, containers, storages, disks, interfaces, services, or replication jobs
- **Perfdata Output**: Full Nagios-compatible perfdata for all modules — works with PNP4Nagios, Graphite, InfluxDB, etc.
- **Verbose & Silent Modes**: Tunable output verbosity for dashboards and alert notifications

## Prerequisites

Ensure the following tools are installed on your monitoring server:

- **bash** (4.0 or higher — requires associative arrays)
- **curl** (for API communication)
- **jq** (for JSON parsing)
- **awk** (for text processing)

### Installation on Different Platforms

**Ubuntu/Debian:**
```bash
sudo apt-get update && sudo apt-get install curl jq gawk
```

**RHEL/CentOS/Rocky Linux:**
```bash
sudo dnf install curl jq gawk
```

**Gentoo:**
```bash
sudo emerge net-misc/curl app-misc/jq sys-apps/gawk
```

## Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ascii42/check_pve_health.git
   cd check_pve_health
   ```

2. **Make the script executable:**
   ```bash
   chmod +x check_pve_health.sh
   ```

3. **Copy to your monitoring plugins directory:**
   ```bash
   # For Icinga2
   sudo cp check_pve_health.sh /usr/lib/nagios/plugins/

   # For Nagios
   sudo cp check_pve_health.sh /usr/local/nagios/libexec/
   ```

## PVE API Token Setup

Create a dedicated read-only API token in the PVE GUI:

1. **Datacenter → Permissions → API Tokens → Add**
2. User: `root@pam` (or a dedicated monitoring user)
3. Token ID: `monitoring`
4. Uncheck **Privilege Separation** for simplest setup, or assign the `PVEAuditor` role
5. Copy the generated secret immediately — it is shown only once

The token format used with `-T` is:
```
USER@REALM!TOKENID=SECRET
```
Example:
```
root@pam!monitoring=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

> **Note:** Always wrap the token in single quotes on the command line — bash history expansion treats `!` specially in double quotes.

## Usage

### Basic Syntax

```bash
./check_pve_health.sh [-h] [-V] -H <host> { -T <token> | -U <user> -P <pass> } [options] [-eX ...]
```

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-H, --host <hostname\|IP>` | Hostname or IP address of the PVE node or cluster VIP |
| `-T, --token <token>` | API token (recommended) — full format: `USER@REALM!TOKENID=SECRET` |
| `-U, --username <user@realm>` | Username for password authentication |
| `-P, --password <password>` | Password for username/password authentication |

### Enable Flags (opt-in)

At least one `-eX` flag is required. Use `-A` to run all standard checks.

| Flag | Long form | Description |
|------|-----------|-------------|
| `-eSys` | `--enable-sys` | Per-node system resources: CPU%, memory%, swap%, load average, uptime, IOWait% |
| `-eCluster` | `--enable-cluster` | Cluster quorum status and node online/offline count |
| `-eVM` | `--enable-vm` | QEMU VM status (running/stopped/paused); resource thresholds; guest agent check |
| `-eCT` | `--enable-ct` | LXC container status (running/stopped/paused); resource thresholds |
| `-eStorage` | `--enable-storage` | Storage pool usage per node |
| `-eSub` | `--enable-sub` | Subscription status and expiry per node |
| `-eRepl` | `--enable-repl` | Replication job status: last sync age, errors, fail count |
| `-eTime` | `--enable-time` | Per-node system time, timezone, and drift vs. monitoring host |
| `-eDNS` | `--enable-dns` | Per-node DNS server configuration and consistency |
| `-eNet` | `--enable-net` | Per-node network interface link states and traffic rates |
| `-eDisk` | `--enable-disk` | Per-node disk SMART health and SSD wearout |
| `-ePSI` | `--enable-psi` | Per-node CPU/memory/IO pressure stall (PVE 8.1+, kernel 4.20+) |
| `-eSnap` | `--enable-snap` | VM/CT snapshot age and count (requires per-VM API calls) |
| `-eBackup` | `--enable-backup` | VM/CT last backup age — **not included in `-A`**, must be enabled explicitly |
| `-eUpdates` | `--enable-updates` | Available package updates per node |
| `-eServices` | `--enable-services` | Per-node systemd service states via the PVE services API |
| `-eLog` | `--enable-log` | PVE task log check — **not included in `-A`**, must be enabled explicitly |
| `-A, -eAll` | `--enable-all` | Enable all standard checks (excludes `-eBackup` and `-eLog`) |

### Disable Flags (opt-out)

Suppress individual modules when running with `-A`:

```
--disable-sys        --disable-cluster    --disable-vm
--disable-ct         --disable-storage    --disable-sub
--disable-repl       --disable-time       --disable-dns
--disable-net        --disable-disk       --disable-psi
--disable-snap       --disable-updates    --disable-services
```

### Threshold Options

Percentage values accept an optional trailing `%` (e.g. `80` and `80%` are equivalent).

| Option | Default | Description |
|--------|---------|-------------|
| `-wCPU, --warn-cpu <pct>` | 80 | Node CPU warn % |
| `-cCPU, --crit-cpu <pct>` | 95 | Node CPU crit % |
| `-wMem, --warn-mem <pct>` | 80 | Node memory warn % |
| `-cMem, --crit-mem <pct>` | 95 | Node memory crit % |
| `--warn-swap <pct>` | 20 | Swap usage warn % |
| `--crit-swap <pct>` | 50 | Swap usage crit % |
| `--warn-load <n>` | disabled | Load average warn (per-CPU) |
| `--crit-load <n>` | disabled | Load average crit (per-CPU) |
| `--warn-storage <val>` | 80% | Storage warn — N% used or N bytes free (K/M/G suffix OK) |
| `--crit-storage <val>` | 90% | Storage crit — N% used or N bytes free |
| `--warn-sub-days <days>` | 30 | Subscription expiry warn days |
| `--crit-sub-days <days>` | 14 | Subscription expiry crit days |
| `--warn-repl-age <min>` | 120 | Replication last-sync age warn minutes |
| `--crit-repl-age <min>` | 240 | Replication last-sync age crit minutes |
| `--warn-time-drift <sec>` | 60 | Time drift warn seconds |
| `--crit-time-drift <sec>` | 300 | Time drift crit seconds |
| `--warn-wearout <pct>` | 20 | SSD wearout remaining warn % |
| `--crit-wearout <pct>` | 10 | SSD wearout remaining crit % |
| `--warn-psi <pct>` | 20 | PSI avg10 pressure warn % |
| `--crit-psi <pct>` | 50 | PSI avg10 pressure crit % |
| `--warn-snap-age <days>` | 7 | Snapshot age warn days |
| `--crit-snap-age <days>` | 30 | Snapshot age crit days |
| `--warn-snap-count <n>` | disabled | Snapshot count warn threshold |
| `--crit-snap-count <n>` | disabled | Snapshot count crit threshold |
| `--warn-backup-age <hours>` | 26 | Last backup age warn hours |
| `--crit-backup-age <hours>` | 48 | Last backup age crit hours |
| `--warn-updates <n>` | 1 | Available update count warn |
| `--crit-updates <n>` | 1 | Security update count crit |
| `--warn-guest-cpu <pct>` | = `--warn-cpu` | VM/CT CPU warn % |
| `--crit-guest-cpu <pct>` | = `--crit-cpu` | VM/CT CPU crit % |
| `--warn-guest-mem <pct>` | = `--warn-mem` | VM/CT memory warn % |
| `--crit-guest-mem <pct>` | = `--crit-mem` | VM/CT memory crit % |
| `--warn-guest-disk <pct>` | 80 | VM/CT disk warn % (detail view) |
| `--crit-guest-disk <pct>` | 90 | VM/CT disk crit % (detail view) |
| `--warn-net-in <bytes>` | disabled | Network ingress rate warn (K/M/G suffixes OK) |
| `--crit-net-in <bytes>` | disabled | Network ingress rate crit |
| `--warn-net-out <bytes>` | disabled | Network egress rate warn |
| `--crit-net-out <bytes>` | disabled | Network egress rate crit |

### Filter & Behaviour Options

| Option | Description |
|--------|-------------|
| `--node <name>` | Restrict all checks to a specific cluster node |
| `--node-storage <node>` | Restrict storage checks to a specific node |
| `--blacklist-vm <list>` | Skip VMs by VMID or name (comma-separated) |
| `--blacklist-ct <list>` | Skip containers by VMID or name |
| `--blacklist-storage <list>` | Skip storage pools by name |
| `--blacklist-net <list>` | Skip network interfaces by name |
| `--blacklist-disk <list>` | Skip disks by device path or model |
| `--blacklist-repl <list>` | Skip replication jobs by ID |
| `--blacklist-snap <list>` | Skip VMs/CTs from snapshot checks by VMID |
| `--blacklist-backup <list>` | Skip VMs/CTs from backup checks by VMID |
| `--blacklist-service <list>` | Skip additional services from the service check |
| `--blacklist-log-type <list>` | Skip task types from the log check |
| `--warn-stopped-vm` | WARN on stopped VMs (default: OK) |
| `--crit-stopped-vm` | CRIT on stopped VMs |
| `--warn-stopped-ct` | WARN on stopped containers (default: OK) |
| `--crit-stopped-ct` | CRIT on stopped containers |
| `--ignore-vm-template` | Skip template VMs (default: skip) |
| `--ignore-no-sub` | Treat missing subscription as OK (not WARN) |
| `--expected-tz <tz>` | WARN when node timezone differs from expected (e.g. `Europe/Berlin`) |
| `--warn-failed-service` | Demote failed services from CRIT to WARN |
| `--ok-inactive-service` | Suppress WARN for enabled-but-inactive services |
| `--logcheck-time <dur>` | Task log look-back window (default: `1h`; supports `Nm`, `Nh`, `Nd`) |
| `--warn-log <n>` | WARN when ≥ N warning tasks in log (default: 1) |
| `--crit-log <n>` | CRIT when ≥ N failed tasks in log (default: 1) |

### Single VM / Container Detail View

When `--vm <vmid|name>` or `--ct <vmid|name>` is combined with `-eVM`/`-eCT`, the plugin fetches detailed real-time metrics for the selected guest from the PVE rrddata endpoint (1-minute averages):

- CPU%, memory%, swap%, disk usage%
- Disk I/O read/write rates (bytes/s)
- Network in/out rates (bytes/s)
- Snapshot count and newest snapshot age
- Replication job count and last-sync age
- QEMU guest agent status (VMs only, with `--warn-agent`)

Guest thresholds (`--warn-guest-*`, `--warn-net-in/out`) trigger WARN/CRIT for the selected VM/CT. Snapshot and replication age/count thresholds also apply in the detail view.

When `-eLog` is additionally active, the task log is automatically filtered to show only tasks for the selected VM/CT.

| Option | Description |
|--------|-------------|
| `--vm <vmid\|name>` | Select a single VM for detailed metrics |
| `--ct <vmid\|name>` | Select a single container for detailed metrics |
| `--warn-agent` | WARN if QEMU guest agent is not running (QEMU VMs only; works with `-eVM` or `-A`) |

### Output Options

| Option | Description |
|--------|-------------|
| `--prefetch` | Enable parallel background API prefetch (faster on low-latency links) |
| `--no-prefetch` | Force serial API calls — default; safer on hardened systems |
| `-v, --verbose` | Show all check details, not just problems |
| `-s, --silent` | Only output problem lines; suppress OK lines |
| `--no-perfdata` | Suppress the perfdata section entirely |
| `--port <port>` | API port (default: 8006) |
| `-d, --debug` | Enable bash trace output (`set -x`) |

## Examples

### Full Cluster Health Check
```bash
./check_pve_health.sh -H pve.example.com -T 'root@pam!monitoring=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -A
```

### Node Resources with Custom Thresholds
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eSys \
  -wCPU 70 -cCPU 90 -wMem 75% -cMem 90%
```

### VM Status with Guest Agent Check
```bash
./check_pve_health.sh -H pve.example.com -T 'root@pam!mon=...' -eVM --warn-agent -v
```

### Detailed Single VM Check
```bash
./check_pve_health.sh -H pve.example.com -T 'root@pam!mon=...' -eVM --vm 100 \
  --warn-guest-cpu 70 --crit-guest-cpu 90 \
  --warn-guest-mem 80 --crit-guest-mem 95 \
  --warn-snap-age 14 --crit-snap-age 30 \
  --warn-repl-age 60 --crit-repl-age 120 -v
```

### Replication with Age Thresholds
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eRepl \
  --warn-repl-age 60 --crit-repl-age 120
```

### Storage with Free-Bytes Threshold
```bash
# Warn when less than 100 GB free, critical at less than 20 GB
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eStorage \
  --warn-storage 100G --crit-storage 20G
```

### Service Check with Custom Blacklist
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eServices \
  --blacklist-service postfix,rpcbind
```

### Task Log — Last 4 Hours, Filtered to VM 100
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eVM -eLog \
  --vm 100 --logcheck-time 4h -v
```

### Snapshot Count and Age Alert
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eSnap \
  --warn-snap-age 7 --crit-snap-age 30 \
  --warn-snap-count 5 --crit-snap-count 10
```

### Backup Check (explicit, not in -A)
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eBackup \
  --warn-backup-age 26 --crit-backup-age 48
```

### All Checks, Suppress Storage and Updates
```bash
./check_pve_health.sh -H pve.example.com -T 'root@pam!mon=...' -A \
  --disable-storage --disable-updates -v
```

## Sample Output

### Verbose mode (`-A -v`)
```
[OK] - Cluster: quorum OK | 2 nodes online
---------------------------------------
[OK] - Node pve-node1 (10.0.0.11): online
[OK]   - pve-node1 CPU: 12% (warn: 80%, crit: 95%)
[OK]   - pve-node1 Memory: 54% (warn: 80%, crit: 95%)
[OK]   - pve-node1 Swap: 0%
[OK]   - pve-node1 Load: 1.23 (per-CPU: 0.31)
[OK]   - pve-node1 Uptime: 39d 4h
---------------------------------------
Virtual Machines:
---------------------------------------
[OK] -   VM 100 vm-prod01 (pve-node1): running | CPU: 2% | Mem: 41% | Up: 39d 4h
[OK]   -   VM 100 Guest agent: running
[WARNING] -   VM 115 vm-web01 (pve-node2): running | CPU: 0% | Mem: 27% | Up: 58d 23h
[WARNING] -   VM 115 Guest agent: not running
[WARNING] - Virtual Machines: 5 total | 5 running, 0 stopped, 0 paused | 1 warning
---------------------------------------
[OK] - Storage local-lvm (pve-node1): 42% used (56.3 GB / 100 GB)
[OK] - Storage ceph-pool: 61% used (1.2 TB / 2.0 TB)
[OK] - Subscription pve-node1: Active (expires 2027-01-15, 312d left)
[OK] - Replication: 2 job(s) OK, last sync 8m ago
[OK] - Task log: no errors/warnings in last 1h (47 tasks checked)
| cluster_nodes=2 cluster_online=2 pve_pve-node1_cpu=12;80;95;0;100 pve_pve-node1_mem=54%;80;95;0;100 ...
```

### Single VM detail (`--vm 100 -eVM -v`)
```
Virtual Machines:
---------------------------------------
[OK] -   VM 100 vm-prod01 (pve-node1): running | CPU: 2% | Mem: 41% | Up: 39d 4h
[OK]   -   VM 100 Guest agent: running
[OK] -   VM 100 CPU: 2.3%
[OK] -   VM 100 Memory: 3.3 GB / 8.0 GB (41.3%)
[OK] -   VM 100 Disk: 12.4 GB / 32.0 GB (38.8%)
[OK] -   VM 100 I/O rates (1-min avg): disk read 512 KB/s | disk write 1.2 MB/s | net in 84 KB/s | net out 22 KB/s
[OK] -   VM 100 I/O total (since boot): disk read 14.2 GB | disk write 89.1 GB | net in 2.1 GB | net out 430 MB
[OK] -   VM 100 Snapshots: 2 snapshot(s), newest: 3d ago
[OK] -   VM 100 Replication: 1 job(s), last sync: 12m ago
[WARNING] - Virtual Machines: 1 total | 1 running, 0 stopped | 0 warning
```

## Integration with Monitoring Systems

### Icinga2 Configuration

Create a command definition in `/etc/icinga2/conf.d/commands.conf`:

```icinga2
object CheckCommand "check_pve" {
    command = [ PluginDir + "/check_pve_health.sh" ]
    arguments = {
        "-H"  = "$pve_host$"
        "-T"  = "$pve_token$"
        "-A"  = {
            set_if = "$pve_check_all$"
        }
        "-v"  = {
            set_if = "$pve_verbose$"
        }
        "--node"              = "$pve_node$"
        "-wCPU"               = "$pve_warn_cpu$"
        "-cCPU"               = "$pve_crit_cpu$"
        "-wMem"               = "$pve_warn_mem$"
        "-cMem"               = "$pve_crit_mem$"
        "--warn-storage"      = "$pve_warn_storage$"
        "--crit-storage"      = "$pve_crit_storage$"
        "--warn-repl-age"     = "$pve_warn_repl_age$"
        "--crit-repl-age"     = "$pve_crit_repl_age$"
        "--warn-snap-age"     = "$pve_warn_snap_age$"
        "--crit-snap-age"     = "$pve_crit_snap_age$"
        "--warn-agent"        = {
            set_if = "$pve_warn_agent$"
        }
        "--disable-updates"   = {
            set_if = "$pve_disable_updates$"
        }
        "--no-perfdata"       = {
            set_if = "$pve_no_perfdata$"
        }
    }
    vars.pve_warn_cpu        = 80
    vars.pve_crit_cpu        = 95
    vars.pve_warn_mem        = 80
    vars.pve_crit_mem        = 95
    vars.pve_warn_storage    = "80%"
    vars.pve_crit_storage    = "90%"
    vars.pve_warn_repl_age   = 120
    vars.pve_crit_repl_age   = 240
    vars.pve_warn_snap_age   = 7
    vars.pve_crit_snap_age   = 30
    vars.pve_check_all       = true
    vars.pve_verbose         = false
    vars.pve_warn_agent      = false
    vars.pve_disable_updates = false
    vars.pve_no_perfdata     = false
}
```

Create a service definition:

```icinga2
apply Service "PVE Health" {
    check_command = "check_pve"
    vars.pve_host  = host.vars.pve_host
    vars.pve_token = host.vars.pve_token

    assign where host.vars.pve_host != ""
}
```

### Nagios Configuration

Add to `commands.cfg`:

```nagios
define command {
    command_name    check_pve
    command_line    $USER1$/check_pve_health.sh -H $ARG1$ -T $ARG2$ -A -wCPU $ARG3$ -cCPU $ARG4$
}
```

Add to `services.cfg`:

```nagios
define service {
    use                 generic-service
    host_name           pve-cluster
    service_description PVE Health
    check_command       check_pve!10.0.0.10!root@pam!monitoring=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx!80!95
}
```

## Security Considerations

- **API Token**: Create a dedicated read-only monitoring token. Assign the `PVEAuditor` role to its user, or use `root@pam` without privilege separation for simplicity.
- **Credential Storage**: Store the API token in your monitoring system's secrets store (Icinga2 constants, HashiCorp Vault, etc.) — not in plain-text config files.
- **Network Access**: The monitoring server requires HTTPS (port 8006) access to the PVE management IP. No outbound internet access is required.
- **Self-Signed Certificates**: The plugin uses `curl --insecure` to accept the default PVE self-signed certificate. If you use a CA-signed certificate on the PVE host, this has no effect on security.
- **Minimal Permissions**: The token only needs read access. No write permissions are required for any check module.

## Troubleshooting

### Common Issues

**`[UNKNOWN] - Authentication failed` or empty responses:**
- Verify the token format: must be `USER@REALM!TOKENID=SECRET` (single-quoted on the command line)
- Test connectivity:
  ```bash
  curl -sk -H "Authorization: PVEAPIToken=root@pam!monitoring=<secret>" \
    https://<host>:8006/api2/json/version
  ```
- Confirm the token has not been deleted or revoked in the PVE GUI (Datacenter → Permissions → API Tokens)

**`[UNKNOWN] - jq is required but not found in PATH`:**
- Install jq: `apt install jq` / `dnf install jq` / `emerge app-misc/jq`

**All checks show UNKNOWN for specific nodes:**
- If using `--node`, verify the node name matches exactly (case-sensitive) as shown in the PVE GUI or `pvesh get /nodes`
- Check that the PVE API is reachable on port 8006 from the monitoring server

**`-eServices` reports unexpected WARNs for `syslog` or `systemd-timesyncd`:**
- These services are inactive on PVE nodes that use `rsyslog`/`chrony` as replacements. They are pre-blacklisted by default. If you still see them, verify you are running a recent version of the plugin.

**`-eSnap` is slow on large clusters:**
- Snapshot checks require one API call per VM/CT. Use `--prefetch` to parallelise the requests, or restrict checks with `--node` or `--blacklist-snap`.

**`-eLog` shows no entries:**
- Ensure `--logcheck-time` covers a long enough window. Default is `1h`.
- When using `--vm <id>` or `--ct <id>`, the log is filtered to that guest's task history only.

**`--warn-agent` never triggers:**
- `--warn-agent` requires `-eVM` (or `-A`) to be active — the check runs inside the VM loop.
- The `qemu-guest-agent` package must be installed **and running** inside the VM, and the agent option must be enabled in the VM's hardware configuration in PVE (VM → Hardware → Add → QEMU Guest Agent).
- `--warn-agent` applies to QEMU VMs only — LXC containers do not have a guest agent.

### Debug Mode

Enable full bash trace output for deep troubleshooting:
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -A -d 2>&1 | less
```

Or use verbose for readable per-module detail:
```bash
./check_pve_health.sh -H 10.0.0.10 -T 'root@pam!mon=...' -eVM -eSys -v
```

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-new-check`)
3. Make your changes
4. Test against a real PVE cluster or captured API JSON fixtures
5. Submit a pull request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

For support, please:
1. Review the troubleshooting section above
2. Check existing GitHub issues
3. Open a new issue with your PVE version, cluster size, and the full plugin output with `-d` (debug) enabled

## Author

**Felix Longardt**
- Email: monitoring@longardt.com
- GitHub: [@ascii42](https://github.com/ascii42)

## Acknowledgments

- Proxmox Server Solutions for the comprehensive PVE REST API documentation
- The Icinga and Nagios communities for feedback and testing

---

**Note**: This plugin is not officially supported by Proxmox Server Solutions GmbH. Use at your own discretion and test thoroughly in your environment before deploying to production monitoring.
