#!/bin/bash
#
# Monitor plugin for checking Proxmox Virtual Environment (PVE) via REST API
#
# Author:
#   Felix Longardt <monitoring@longardt.com>
#
# Version history (compact):
# 1.0.0  2026-06-10  Initial release: -eSys -eCluster -eVM -eCT -eStorage -eSub -eRepl -eAll
# 1.1.0  2026-06-10  -eTime -eDNS -eNet -eDisk -ePSI -eSnap -eBackup -eUpdates;
#                    -eSys: swap + load avg checks (from /nodes/{node}/status);
#                    -s/-d/-A flags; fix silent mode separator guard
# 1.3.0  2026-06-10  --no-prefetch default (serial API calls); --prefetch to re-enable parallel;
#                    --vm / --ct single item filter with detailed disk+net I/O stats
# 1.4.0  2026-06-11  -eServices: systemd service state check via PVE services API;
#                    -eLog: PVE task log check with configurable time window (--logcheck-time);
#                    --vm/--ct: CPU/mem/disk/swap/net thresholds + guest agent check;
#                    --warn-guest-cpu/mem/disk, --warn-net-in/out thresholds for VMs/CTs;
#                    guest CPU/mem thresholds in -eVM/-eCT loop trigger WARN/CRIT
# 1.2.0  2026-06-10  Fix storage: use .disk/.maxdisk (not .used/.total) from cluster/resources;
#                    Fix subscription: case-insensitive notfound/expired matching;
#                    -eTime verbose: show system time + drift value;
#                    -eNet verbose: add cumulative traffic totals per node;
#                    -eSys: add IOWait% from node status to verbose + perfdata;
#                    Token format validation + auth error detection


## VARIABLES
PROGNAME="${0##*/}"
PROGPATH="${0%/*}"
REVISION="1.4.0"
JQ="$(which jq)"
CURL="$(which curl)"
AWK="$(which awk)"

status_ok="[OK]"
status_warn="[WARNING]"
status_crit="[CRITICAL]"
status_unknown="[UNKNOWN]"

exit_unknown() {
	echo "UNKNOWN: ${1}"
	exit 3
}

## FUNCTIONS
print_usage() {
	echo "Usage: ${PROGNAME} [-h] [-V] -H <host> { -T <token> | -U <user> -P <pass> } [-opts] [-eX]"
}

print_revision() {
	echo "${1} - v${2}"
}

print_help() {
	print_revision "${PROGNAME}" "${REVISION}"
	echo ""
	print_usage
cat << EOM


 This plugin monitors Proxmox Virtual Environment (PVE) nodes and clusters
 via the Proxmox REST API (https://<host>:8006/api2/json/).

 Connects directly to the PVE host using HTTPS (self-signed certs accepted).
 Authentication via API token (preferred) or username/password.

Options:
 -h, --help
    Print detailed help screen
 -V, --version
    Print version information

 -H, --host <hostname|IP>
    Hostname or IP address of the PVE node
 --port <port>
    API port (default: 8006)
 -T, --token, -a <token>
    API token — FULL format required: USER@REALM!TOKENID=SECRET
    Example: -T 'root@pam!monitoring=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    Use single quotes — bash expands '!' in double quotes (history expansion)
    (PVE GUI: Datacenter > Permissions > API Tokens > Add)
 -U, --username <user@realm>
    Username for password authentication (e.g. root@pam)
 -P, --password <password>
    Password for authentication

 --node <name>
    Restrict checks to a specific node (default: all nodes in cluster)

 Enable flags (opt-in — at least one -eX flag is required):
 -eSys,     --enable-sys
    Per-node system resources: CPU%, memory%, swap%, uptime, load average
    Thresholds: -wCPU/-cCPU (default: 80/95%), -wMem/-cMem (default: 80/95%)
    Swap thresholds: --warn-swap/--crit-swap (default: 20/50%)
    Load thresholds: --warn-load/--crit-load (default: -1 disabled, per-CPU)
 -eCluster, --enable-cluster
    Cluster quorum status, nodes online/offline
    CRITICAL when quorum lost; CRITICAL when any node offline
 -eVM,      --enable-vm
    Virtual machine (QEMU) status: running/stopped/paused
    WARN on paused/suspended; CRIT on error state
    --warn-stopped-vm: also WARN on stopped VMs
    --crit-stopped-vm: CRIT on stopped VMs
    --ignore-vm-template: skip template VMs (default: skip)
    --blacklist-vm <vmid[,vmid,...]>: skip specific VMs by VMID or name
 -eCT,      --enable-ct
    Container (LXC) status: running/stopped/paused
    --warn-stopped-ct: also WARN on stopped containers
    --crit-stopped-ct: CRIT on stopped containers
    --blacklist-ct <vmid[,vmid,...]>: skip specific containers by VMID or name
 -eStorage, --enable-storage
    Storage pool usage per node
    Thresholds: --warn-storage/--crit-storage (default: 80%/90%)
    Supports N% (percentage used) or plain N (free bytes remaining)
    --blacklist-storage <list>: skip specific storage pools
    --node-storage <node>: restrict storage checks to specific node
 -eSub,     --enable-sub
    Subscription status (Active/NotFound/Invalid/Expired) per node
    --warn-sub-days <days>: WARN when expiry within N days (default: 30)
    --crit-sub-days <days>: CRIT when expiry within N days (default: 14)
    --ignore-no-sub: treat NotFound/no subscription as OK (not WARN)
 -eRepl,    --enable-repl
    Replication job status: last sync time, errors, fail count
    --warn-repl-age <min>: WARN when last sync older than N minutes (default: 120)
    --crit-repl-age <min>: CRIT when last sync older than N minutes (default: 240)
    --blacklist-repl <id[,id,...]>: skip specific replication job IDs
 -eTime,    --enable-time
    Per-node system time: timezone, time drift vs monitoring host
    --expected-tz <tz>:       WARN when node timezone != expected (e.g. Europe/Berlin)
    --warn-time-drift <sec>:  WARN when drift > N seconds (default: 60)
    --crit-time-drift <sec>:  CRIT when drift > N seconds (default: 300)
 -eDNS,     --enable-dns
    Per-node DNS configuration: DNS servers configured and consistent
 -eNet,     --enable-net
    Per-node network interface link state and traffic counters
    --blacklist-net <iface[,iface,...]>: skip specific interfaces
    --warn-net-in <bytes>:  WARN when ingress rate > N bytes/s (K/M/G suffixes OK)
    --crit-net-in <bytes>:  CRIT when ingress rate > N bytes/s (applies to host/-eNet, --vm, --ct)
    --warn-net-out <bytes>: WARN when egress rate > N bytes/s
    --crit-net-out <bytes>: CRIT when egress rate > N bytes/s
 -eDisk,    --enable-disk
    Per-node disk health (SMART) and SSD wearout
    --warn-wearout <pct>:     WARN when SSD wearout remaining < N% (default: 20)
    --crit-wearout <pct>:     CRIT when SSD wearout remaining < N% (default: 10)
    --blacklist-disk <dev[,dev,...]>: skip specific disks by devpath or model
 -ePSI,     --enable-psi
    Per-node CPU/memory/IO pressure stall (PSI, PVE 8.1+, Linux kernel 4.20+)
    --warn-psi <pct>:         WARN when any avg10 pressure > N% (default: 20)
    --crit-psi <pct>:         CRIT when any avg10 pressure > N% (default: 50)
 -eSnap,    --enable-snap
    VM/CT snapshot age/count (requires per-VM API calls)
    --warn-snap-age <days>:   WARN when snapshot older than N days (default: 7)
    --crit-snap-age <days>:   CRIT when snapshot older than N days (default: 30)
    --warn-snap-count <n>:    WARN when snapshot count >= N (default: disabled)
    --crit-snap-count <n>:    CRIT when snapshot count >= N (default: disabled)
    --blacklist-snap <vmid[,vmid,...]>: skip specific VMIDs
 -eBackup,  --enable-backup
    VM/CT backup status (NOT included in -eAll; enable explicitly)
    --warn-backup-age <hours>: WARN when last backup older than N hours (default: 26)
    --crit-backup-age <hours>: CRIT when last backup older than N hours (default: 48)
    --blacklist-backup <vmid[,vmid,...]>: skip specific VMIDs
 -eUpdates, --enable-updates
    Available package updates per node
    --warn-updates <count>:   WARN when >= N updates available (default: 1)
    --crit-updates <count>:   CRIT when >= N security updates available (default: 1)
 -eServices, --enable-services
    Per-node systemd service states (via PVE services API)
    Enabled+running → OK; disabled/masked/static → skip
    Failed → CRIT (use --warn-failed-service for WARN)
    Enabled but inactive → WARN (use --ok-inactive-service to suppress)
    --warn-failed-service:   demote failed services from CRIT to WARN
    --ok-inactive-service:   suppress WARN for enabled-but-inactive services
    --blacklist-service <svc[,svc,...]>: skip additional service names
    default blacklist: syslog, systemd-timesyncd (inactive when chrony/journald run)
 -eLog, --enable-log
    PVE task log check: scans recent task history for errors and warnings
    NOT included in -eAll; enable explicitly with -eLog
    --logcheck-time <dur>:   look-back window (default: 1h; supports Nm/Nh/Nd)
    --warn-log <n>:          WARN when >= N warning tasks (default: 1)
    --crit-log <n>:          CRIT when >= N failed tasks (default: 1)
    --blacklist-log-type <type[,type,...]>: skip specific task types
 --vm <vmid|name>
    Restrict -eVM output to a single VM (by VMID or name);
    fetches detailed metrics: CPU, mem, swap, disk, I/O rates, net rates
    guest thresholds (--warn-guest-cpu/mem/disk, --warn-net-in/out) trigger WARN/CRIT
    --warn-agent: warn if QEMU guest agent is not running on the selected VM
 --ct <vmid|name>
    Restrict -eCT output to a single container (by VMID or name);
    fetches detailed metrics: CPU, mem, swap, disk, I/O rates, net rates
    guest thresholds (--warn-guest-cpu/mem/disk, --warn-net-in/out) trigger WARN/CRIT
 -eAll, -A, --enable-all
    Enable all checks (note: -eBackup and -eLog are never included in -eAll)

 Disable flags (useful with -eAll):
 --disable-sys       --disable-cluster     --disable-vm
 --disable-ct        --disable-storage     --disable-sub
 --disable-repl      --disable-time        --disable-dns
 --disable-net       --disable-disk        --disable-psi
 --disable-snap      --disable-updates     --disable-services

 Threshold options:
 -wCPU, --warn-cpu <pct>       CPU warn threshold (default: 80)
 -cCPU, --crit-cpu <pct>       CPU crit threshold (default: 95)
 -wMem, --warn-mem <pct>       Memory warn threshold (default: 80)
 -cMem, --crit-mem <pct>       Memory crit threshold (default: 95)
 --warn-swap <pct>             Swap warn threshold (default: 20)
 --crit-swap <pct>             Swap crit threshold (default: 50)
 --warn-storage <val>          Storage used warn (N% or free bytes, default: 80%)
 --crit-storage <val>          Storage used crit (N% or free bytes, default: 90%)
 --warn-sub-days <days>        Subscription expiry warn days (default: 30)
 --crit-sub-days <days>        Subscription expiry crit days (default: 14)
 --warn-repl-age <min>         Replication max age warn minutes (default: 120)
 --crit-repl-age <min>         Replication max age crit minutes (default: 240)
 --warn-time-drift <sec>       Time drift warn seconds (default: 60)
 --crit-time-drift <sec>       Time drift crit seconds (default: 300)
 --warn-wearout <pct>          SSD wearout remaining warn % (default: 20)
 --crit-wearout <pct>          SSD wearout remaining crit % (default: 10)
 --warn-psi <pct>              PSI avg10 warn % (default: 20)
 --crit-psi <pct>              PSI avg10 crit % (default: 50)
 --warn-snap-age <days>        Snapshot age warn days (default: 7)
 --crit-snap-age <days>        Snapshot age crit days (default: 30)
 --warn-snap-count <n>         Snapshot count warn threshold (default: disabled)
 --crit-snap-count <n>         Snapshot count crit threshold (default: disabled)
 --warn-backup-age <hours>     Last backup warn hours (default: 26)
 --crit-backup-age <hours>     Last backup crit hours (default: 48)
 --warn-updates <count>        Update count warn threshold (default: 1)
 --crit-updates <count>        Security update crit threshold (default: 1)
 --warn-guest-cpu <pct>        VM/CT CPU warn % (default: same as --warn-cpu)
 --crit-guest-cpu <pct>        VM/CT CPU crit % (default: same as --crit-cpu)
 --warn-guest-mem <pct>        VM/CT memory warn % (default: same as --warn-mem)
 --crit-guest-mem <pct>        VM/CT memory crit % (default: same as --crit-mem)
 --warn-guest-disk <pct>       VM/CT disk warn % (default: 80)
 --crit-guest-disk <pct>       VM/CT disk crit % (default: 90)
 --warn-net-in <bytes>         Net ingress rate warn (K/M/G suffix supported)
 --crit-net-in <bytes>         Net ingress rate crit
 --warn-net-out <bytes>        Net egress rate warn
 --crit-net-out <bytes>        Net egress rate crit
 --warn-agent                  Warn if QEMU guest agent not running (requires --vm)

 Output options:
 --prefetch
    Enable parallel API prefetch (background curl jobs); faster on
    low-latency networks, but may cause issues on hardened systems
 --no-prefetch
    Force serial API calls (default)
 -v, --verbose
    Verbose output: show all check details, not just problems
 --no-perfdata
    Suppress performance data output
 -s, --silent
    Only output problem lines (no OK lines); useful for notifications
 -d, --debug
    Enable bash debug output (set -x)

EOM
}

[[ -z "${JQ}" ]]   && exit_unknown "jq is required but not found in PATH"
[[ -z "${CURL}" ]] && exit_unknown "curl is required but not found in PATH"
[[ -z "${AWK}" ]]  && exit_unknown "awk is required but not found in PATH"

## ARGUMENT PARSING
while [[ -n "${1}" ]]; do
	case "${1}" in
	-h|--help)
		print_help
		exit 0
		;;
	-V|--version)
		print_revision "${PROGNAME}" "${REVISION}"
		exit 0
		;;
	-H|--host)
		shift; pve_host="${1}" ;;
	--port)
		shift; pve_port="${1}" ;;
	-T|--token|-a|--api-token)
		shift; api_token="${1}" ;;
	-U|--username)
		shift; api_user="${1}" ;;
	-P|--password)
		shift; api_pass="${1}" ;;
	--node)
		shift; pve_node="${1}" ;;

	# Enable flags
	-eSys|--enable-sys)         enable_sys=1 ;;
	-eCluster|--enable-cluster) enable_cluster=1 ;;
	-eVM|--enable-vm)           enable_vm=1 ;;
	-eCT|--enable-ct)           enable_ct=1 ;;
	-eStorage|--enable-storage) enable_storage=1 ;;
	-eSub|--enable-sub)         enable_sub=1 ;;
	-eRepl|--enable-repl)       enable_repl=1 ;;
	-eTime|--enable-time)       enable_time=1 ;;
	-eDNS|--enable-dns)         enable_dns=1 ;;
	-eNet|--enable-net)         enable_net=1 ;;
	-eDisk|--enable-disk)       enable_disk=1 ;;
	-ePSI|--enable-psi)         enable_psi=1 ;;
	-eSnap|--enable-snap)       enable_snap=1 ;;
	-eBackup|--enable-backup)   enable_backup=1 ;;
	-eUpdates|--enable-updates) enable_updates=1 ;;
	-eServices|--enable-services) enable_services=1 ;;
	-eLog|--enable-log)         enable_log=1 ;;
	-eAll|-A|--enable-all)      enable_all=1 ;;

	# Disable flags
	--disable-sys)      disable_sys=1 ;;
	--disable-cluster)  disable_cluster=1 ;;
	--disable-vm)       disable_vm=1 ;;
	--disable-ct)       disable_ct=1 ;;
	--disable-storage)  disable_storage=1 ;;
	--disable-sub)      disable_sub=1 ;;
	--disable-services) disable_services=1 ;;
	--disable-repl)    disable_repl=1 ;;
	--disable-time)    disable_time=1 ;;
	--disable-dns)     disable_dns=1 ;;
	--disable-net)     disable_net=1 ;;
	--disable-disk)    disable_disk=1 ;;
	--disable-psi)     disable_psi=1 ;;
	--disable-snap)    disable_snap=1 ;;
	--disable-updates) disable_updates=1 ;;

	# CPU/memory thresholds
	-wCPU|--warn-cpu)  shift; warn_cpu="${1}" ;;
	-cCPU|--crit-cpu)  shift; crit_cpu="${1}" ;;
	-wMem|--warn-mem)  shift; warn_mem="${1}" ;;
	-cMem|--crit-mem)  shift; crit_mem="${1}" ;;
	--warn-swap)       shift; warn_swap="${1}" ;;
	--crit-swap)       shift; crit_swap="${1}" ;;
	--warn-load)       shift; warn_load="${1}" ;;
	--crit-load)       shift; crit_load="${1}" ;;
	--warn-guest-cpu)  shift; warn_guest_cpu="${1}" ;;
	--crit-guest-cpu)  shift; crit_guest_cpu="${1}" ;;
	--warn-guest-mem)  shift; warn_guest_mem="${1}" ;;
	--crit-guest-mem)  shift; crit_guest_mem="${1}" ;;
	--warn-guest-disk) shift; warn_guest_disk="${1}" ;;
	--crit-guest-disk) shift; crit_guest_disk="${1}" ;;

	# Storage thresholds
	--warn-storage)         shift; warn_storage="${1}" ;;
	--crit-storage)         shift; crit_storage="${1}" ;;
	--blacklist-storage)    shift; storage_blacklist="${1}" ;;
	--node-storage)         shift; storage_node="${1}" ;;

	# Subscription thresholds
	--warn-sub-days)  shift; warn_sub_days="${1}" ;;
	--crit-sub-days)  shift; crit_sub_days="${1}" ;;
	--ignore-no-sub)  ignore_no_sub=1 ;;

	# Replication thresholds
	--warn-repl-age)    shift; warn_repl_age="${1}" ;;
	--crit-repl-age)    shift; crit_repl_age="${1}" ;;
	--blacklist-repl)   shift; repl_blacklist="${1}" ;;

	# VM/CT options
	--warn-stopped-vm)      warn_stopped_vm=1 ;;
	--crit-stopped-vm)      crit_stopped_vm=1 ;;
	--ignore-vm-template)   ignore_vm_template=1 ;;
	--no-ignore-vm-template) ignore_vm_template="" ;;
	--warn-stopped-ct)      warn_stopped_ct=1 ;;
	--crit-stopped-ct)      crit_stopped_ct=1 ;;
	--blacklist-vm)         shift; vm_blacklist="${1}" ;;
	--blacklist-ct)         shift; ct_blacklist="${1}" ;;
	--vm)                   shift; vm_filter="${1}" ;;
	--ct)                   shift; ct_filter="${1}" ;;
	--warn-agent)           warn_agent=1 ;;
	--blacklist-snap)       shift; snap_blacklist="${1}" ;;
	--blacklist-backup)     shift; backup_blacklist="${1}" ;;

	# Time thresholds
	--expected-tz)          shift; expected_tz="${1}" ;;
	--warn-time-drift)      shift; warn_time_drift="${1}" ;;
	--crit-time-drift)      shift; crit_time_drift="${1}" ;;

	# Network
	--blacklist-net)        shift; net_blacklist="${1}" ;;
	--warn-net-in)          shift; warn_net_in="${1}" ;;
	--crit-net-in)          shift; crit_net_in="${1}" ;;
	--warn-net-out)         shift; warn_net_out="${1}" ;;
	--crit-net-out)         shift; crit_net_out="${1}" ;;

	# Disk thresholds
	--warn-wearout)         shift; warn_wearout="${1}" ;;
	--crit-wearout)         shift; crit_wearout="${1}" ;;
	--blacklist-disk)       shift; disk_blacklist="${1}" ;;

	# PSI thresholds
	--warn-psi)             shift; warn_psi="${1}" ;;
	--crit-psi)             shift; crit_psi="${1}" ;;

	# Snapshot thresholds
	--warn-snap-age)        shift; warn_snap_age="${1}" ;;
	--crit-snap-age)        shift; crit_snap_age="${1}" ;;
	--warn-snap-count)      shift; warn_snap_count="${1}" ;;
	--crit-snap-count)      shift; crit_snap_count="${1}" ;;

	# Backup thresholds
	--warn-backup-age)      shift; warn_backup_age="${1}" ;;
	--crit-backup-age)      shift; crit_backup_age="${1}" ;;

	# Updates thresholds
	--warn-updates)         shift; warn_updates="${1}" ;;
	--crit-updates)         shift; crit_updates="${1}" ;;

	# Service check options
	--warn-failed-service)  warn_failed_service=1 ;;
	--ok-inactive-service)  ok_inactive_service=1 ;;
	--blacklist-service)    shift; service_blacklist="${1}" ;;

	# Log/task check options
	--logcheck-time)        shift; logcheck_time="${1}" ;;
	--warn-log)             shift; warn_log="${1}" ;;
	--crit-log)             shift; crit_log="${1}" ;;
	--blacklist-log-type)   shift; log_blacklist_type="${1}" ;;

	# Output options
	--prefetch)         no_prefetch="" ;;
	--no-prefetch)      no_prefetch=1 ;;
	-v|--verbose)       verbose=1 ;;
	--no-perfdata)      no_perfdata=1 ;;
	-s|--silent)        silent=1 ;;
	-d|--debug)         debug=1 ;;
	--tmp-dir)          shift; tmp_dir="${1}" ;;

	*)
		echo "Unknown option: ${1}"
		print_usage
		exit 3
		;;
	esac
	shift
done

## VALIDATION
[[ -z "${pve_host}" ]] && { echo "Error: -H <host> required"; print_usage; exit 3; }
[[ -z "${api_token}" && ( -z "${api_user}" || -z "${api_pass}" ) ]] && \
	{ echo "Error: -T <token>  OR  -U <user> -P <pass> required"; print_usage; exit 3; }
# Token format check: must be USER@REALM!TOKENID=SECRET (contains @ ! and =)
if [[ -n "${api_token}" ]]; then
	if [[ "${api_token}" != *@*!*=* ]]; then
		echo "Error: API token format invalid. Expected: USER@REALM!TOKENID=SECRET"
		echo "       Example: root@pam!mytoken=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
		echo "       Note:    use single quotes to prevent bash from expanding '!'"
		echo "                -T 'root@pam!mytoken=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
		echo "       Create tokens at: PVE GUI > Datacenter > Permissions > API Tokens"
		exit 3
	fi
fi

_any_enabled=0
for _ef in enable_sys enable_cluster enable_vm enable_ct enable_storage \
           enable_sub enable_repl enable_time enable_dns enable_net enable_disk \
           enable_psi enable_snap enable_backup enable_updates \
           enable_services enable_log enable_all; do
	[[ -n "${!_ef}" ]] && { _any_enabled=1; break; }
done
[[ "${_any_enabled}" -eq 0 ]] && { echo "Error: at least one -eX check flag required"; print_usage; exit 3; }

## DEFAULTS
[[ -z "${pve_port}" ]]       && pve_port=8006
[[ -z "${warn_cpu}" ]]       && warn_cpu=80
[[ -z "${crit_cpu}" ]]       && crit_cpu=95
[[ -z "${warn_mem}" ]]       && warn_mem=80
[[ -z "${crit_mem}" ]]       && crit_mem=95
[[ -z "${warn_swap}" ]]      && warn_swap=20
[[ -z "${crit_swap}" ]]      && crit_swap=50
[[ -z "${warn_load}" ]]      && warn_load=-1
[[ -z "${crit_load}" ]]      && crit_load=-1
[[ -z "${warn_storage}" ]]   && warn_storage=80%
[[ -z "${crit_storage}" ]]   && crit_storage=90%
[[ -z "${warn_sub_days}" ]]  && warn_sub_days=30
[[ -z "${crit_sub_days}" ]]  && crit_sub_days=14
[[ -z "${warn_repl_age}" ]]    && warn_repl_age=120
[[ -z "${crit_repl_age}" ]]    && crit_repl_age=240
[[ -z "${ignore_vm_template}" ]] && ignore_vm_template=1
[[ -z "${warn_time_drift}" ]]  && warn_time_drift=60
[[ -z "${crit_time_drift}" ]]  && crit_time_drift=300
[[ -z "${warn_wearout}" ]]     && warn_wearout=20
[[ -z "${crit_wearout}" ]]     && crit_wearout=10
[[ -z "${warn_psi}" ]]         && warn_psi=20
[[ -z "${crit_psi}" ]]         && crit_psi=50
[[ -z "${warn_snap_age}" ]]    && warn_snap_age=7
[[ -z "${crit_snap_age}" ]]    && crit_snap_age=30
[[ -z "${warn_backup_age}" ]]  && warn_backup_age=26
[[ -z "${crit_backup_age}" ]]  && crit_backup_age=48
[[ -z "${warn_updates}" ]]     && warn_updates=1
[[ -z "${crit_updates}" ]]     && crit_updates=1
[[ -z "${no_prefetch}" ]]      && no_prefetch=1   # serial by default; pass --prefetch to enable parallel
[[ -z "${warn_log}" ]]         && warn_log=1
[[ -z "${crit_log}" ]]         && crit_log=1
[[ -z "${logcheck_time}" ]]    && logcheck_time="1h"
# Parse logcheck duration to seconds for tasks API ?since= param
_logcheck_secs=$(echo "${logcheck_time}" | "${AWK}" '{
    v=$1; u=tolower(v)
    if (u ~ /d$/) { sub(/d$/, "", v); printf "%d", v*86400 }
    else if (u ~ /h$/) { sub(/h$/, "", v); printf "%d", v*3600 }
    else if (u ~ /m$/) { sub(/m$/, "", v); printf "%d", v*60 }
    else printf "%d", v
}')
_logcheck_since=$(( $(date +%s) - _logcheck_secs ))
# Guest thresholds default to node thresholds (set after node defaults above)
[[ -z "${warn_guest_cpu}" ]]  && warn_guest_cpu="${warn_cpu}"
[[ -z "${crit_guest_cpu}" ]]  && crit_guest_cpu="${crit_cpu}"
[[ -z "${warn_guest_mem}" ]]  && warn_guest_mem="${warn_mem}"
[[ -z "${crit_guest_mem}" ]]  && crit_guest_mem="${crit_mem}"
[[ -z "${warn_guest_disk}" ]] && warn_guest_disk=80
[[ -z "${crit_guest_disk}" ]] && crit_guest_disk=90

# Strip optional trailing % from pure-percentage thresholds
for _v in warn_cpu crit_cpu warn_mem crit_mem warn_swap crit_swap \
          warn_wearout crit_wearout warn_psi crit_psi \
          warn_guest_cpu crit_guest_cpu warn_guest_mem crit_guest_mem \
          warn_guest_disk crit_guest_disk; do
    printf -v "${_v}" '%s' "${!_v//%/}"
done
unset _v

if [[ -n "${debug}" ]]; then
	echo "Debugging mode ON." 1>&2
	set -x
fi

## API SETUP
PVE_API="https://${pve_host}:${pve_port}/api2/json"
CURL_OPTS="--insecure --silent --max-time 30"

if [[ -n "${api_token}" ]]; then
	pve_api_get() { ${CURL} ${CURL_OPTS} -H "Authorization: PVEAPIToken=${api_token}" "$@"; }
else
	# Password auth: get ticket and CSRF token
	_auth_resp=$(${CURL} ${CURL_OPTS} -X POST \
		-d "username=${api_user}&password=${api_pass}" \
		"${PVE_API}/access/ticket" 2>/dev/null)
	_pve_ticket=$(echo "${_auth_resp}" | "${JQ}" -r '.data.ticket // empty' 2>/dev/null)
	_pve_csrf=$(echo "${_auth_resp}"   | "${JQ}" -r '.data.CSRFPreventionToken // empty' 2>/dev/null)
	if [[ -z "${_pve_ticket}" ]]; then
		exit_unknown "Authentication failed — no ticket received (check credentials)"
	fi
	pve_api_get() {
		${CURL} ${CURL_OPTS} \
			-b "PVEAuthCookie=${_pve_ticket}" \
			-H "CSRFPreventionToken: ${_pve_csrf}" "$@"
	}
fi

## TEMP DIRECTORY
if [[ -n "${tmp_dir}" ]]; then
	[[ ! -d "${tmp_dir}" ]] && exit_unknown "--tmp-dir '${tmp_dir}' does not exist"
	_pf=$(mktemp -d "${tmp_dir}/.pve_check_XXXXXX") || exit_unknown "mktemp failed in ${tmp_dir}"
else
	_pf=$(mktemp -d /tmp/.pve_check_XXXXXX) || exit_unknown "mktemp failed in /tmp"
fi

## PREFETCH HELPER (parallel or serial depending on --no-prefetch)
_pf_get() {
	if [[ -n "${no_prefetch}" ]]; then
		pve_api_get "$1" > "${_pf}/$2" 2>/dev/null
	else
		pve_api_get "$1" > "${_pf}/$2" 2>/dev/null &
	fi
}

## PREFETCH
_pf_get "${PVE_API}/cluster/resources"  cluster_resources.json
_pf_get "${PVE_API}/cluster/status"     cluster_status.json
_pf_get "${PVE_API}/nodes"              nodes.json
[[ ( -n "${enable_repl}" || -n "${enable_vm}" || -n "${enable_ct}" || -n "${enable_all}" ) ]] && \
	_pf_get "${PVE_API}/cluster/replication" cluster_replication.json

[[ -z "${no_prefetch}" ]] && wait  # collect parallel prefetch jobs

## LOAD BASE DATA
_res_buf=$(cat "${_pf}/cluster_resources.json"     2>/dev/null)
_cls_buf=$(cat "${_pf}/cluster_status.json"        2>/dev/null)
_nod_buf=$(cat "${_pf}/nodes.json"                 2>/dev/null)
_repl_buf=$(cat "${_pf}/cluster_replication.json"  2>/dev/null)

## AUTH / CONNECTIVITY CHECK
# nodes.json must contain valid data; empty or error JSON means auth failure or unreachable host
_auth_check=$(echo "${_nod_buf}" | "${JQ}" -r '.data // empty' 2>/dev/null)
if [[ -z "${_auth_check}" || "${_auth_check}" == "null" ]]; then
	_raw_err=$(echo "${_nod_buf}" | "${JQ}" -r '.errors // empty' 2>/dev/null)
	if [[ -z "${_nod_buf}" ]]; then
		exit_unknown "Cannot reach PVE API at ${PVE_API} (host unreachable or wrong port)"
	elif [[ -n "${_raw_err}" ]]; then
		exit_unknown "PVE API authentication failed: ${_raw_err}"
	else
		exit_unknown "PVE API returned no node data — check token permissions (requires PVEAuditor role)"
	fi
fi

## OUTPUT ACCUMULATORS
pve_output=""
pve_problem_output=""
pve_perf=""

## NODE LIST (used by multiple checks)
mapfile -t _all_nodes < <(echo "${_nod_buf}" | "${JQ}" -r '.data[].node // empty' 2>/dev/null)
[[ -n "${pve_node}" ]] && _all_nodes=("${pve_node}")

## SECOND PREFETCH (per-node, after node list is known)
_need_node_status=0
{ [[ ( -n "${enable_sys}"  || -n "${enable_all}" ) && -z "${disable_sys}"  ]] || \
  [[ ( -n "${enable_psi}"  || -n "${enable_all}" ) && -z "${disable_psi}"  ]]; } && _need_node_status=1
for _pfn in "${_all_nodes[@]}"; do
    [[ "${_need_node_status}" -eq 1 ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/status"     "node_status_${_pfn}.json"
    [[ ( -n "${enable_time}" || -n "${enable_all}" ) && -z "${disable_time}" ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/time"       "node_time_${_pfn}.json"
    [[ ( -n "${enable_dns}"  || -n "${enable_all}" ) && -z "${disable_dns}"  ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/dns"        "node_dns_${_pfn}.json"
    [[ ( -n "${enable_net}"  || -n "${enable_all}" ) && -z "${disable_net}"  ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/network"    "node_net_${_pfn}.json"
    [[ ( -n "${enable_net}"  || -n "${enable_all}" ) && -z "${disable_net}" && \
       ( -n "${warn_net_in}" || -n "${crit_net_in}" || -n "${warn_net_out}" || -n "${crit_net_out}" ) ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/rrddata?timeframe=hour&cf=AVERAGE" "node_rrd_${_pfn}.json"
    [[ ( -n "${enable_disk}" || -n "${enable_all}" ) && -z "${disable_disk}" ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/disks/list" "node_disks_${_pfn}.json"
    [[ ( -n "${enable_updates}" || -n "${enable_all}" ) && -z "${disable_updates}" ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/apt/update" "node_updates_${_pfn}.json"
    [[ -n "${enable_backup}" ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/tasks?typefilter=vzdump&limit=100" \
                "node_tasks_backup_${_pfn}.json"
    [[ ( -n "${enable_services}" || -n "${enable_all}" ) && -z "${disable_services}" ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/services" "node_services_${_pfn}.json"
    [[ -n "${enable_log}" ]] && \
        _pf_get "${PVE_API}/nodes/${_pfn}/tasks?limit=500&since=${_logcheck_since}" \
                "node_tasks_log_${_pfn}.json"
done
[[ ( -n "${enable_backup}" ) ]] && \
    _pf_get "${PVE_API}/cluster/backup-info/not-backed-up" "cluster_backup_notcovered.json"
[[ -z "${no_prefetch}" ]] && wait  # collect per-node parallel jobs

# Cluster or standalone?
_is_cluster=0
"${JQ}" -e '.data[]? | select(.type=="cluster")' <<< "${_cls_buf}" >/dev/null 2>&1 && _is_cluster=1

# Human-readable bytes helper (used in multiple checks)
_parse_duration() {
	echo "${1:-3600}" | "${AWK}" '{
		v=$1; u=tolower(v)
		if (u ~ /d$/) { sub(/d$/, "", v); printf "%d", v*86400 }
		else if (u ~ /h$/) { sub(/h$/, "", v); printf "%d", v*3600 }
		else if (u ~ /m$/) { sub(/m$/, "", v); printf "%d", v*60 }
		else printf "%d", v
	}'
}
_parse_bytes() {
	echo "${1:-0}" | "${AWK}" '{
		v=$1; u=toupper(v)
		if (u ~ /G$/) { sub(/[Gg]$/, "", v); printf "%d", v*1073741824 }
		else if (u ~ /M$/) { sub(/[Mm]$/, "", v); printf "%d", v*1048576 }
		else if (u ~ /K$/) { sub(/[Kk]$/, "", v); printf "%d", v*1024 }
		else printf "%d", v
	}'
}
# Parse net rate thresholds after _parse_bytes is defined
[[ -n "${warn_net_in}" ]]  && warn_net_in=$(_parse_bytes "${warn_net_in}")
[[ -n "${crit_net_in}" ]]  && crit_net_in=$(_parse_bytes "${crit_net_in}")
[[ -n "${warn_net_out}" ]] && warn_net_out=$(_parse_bytes "${warn_net_out}")
[[ -n "${crit_net_out}" ]] && crit_net_out=$(_parse_bytes "${crit_net_out}")

_fmt_bytes() {
	echo "${1}" | "${AWK}" '{
		if ($1>=1099511627776) printf "%.1f TB",$1/1099511627776
		else if ($1>=1073741824) printf "%.1f GB",$1/1073741824
		else if ($1>=1048576)    printf "%.1f MB",$1/1048576
		else if ($1>=1024)       printf "%.1f kB",$1/1024
		else printf "%d B",$1
	}'
}

# ---------------------------------------------------------------------------
# System Resources Check (-eSys)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_sys}" || -n "${enable_all}" ) && -z "${disable_sys}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="System Resources:\n---------------------------------------\n"
	fi

	_sys_any_crit=0; _sys_any_warn=0

	while IFS=$'\t' read -r _snode _scpu _smaxcpu _smem _smaxmem _sdisk _smaxdisk _suptime; do
		[[ -z "${_snode}" ]] && continue

		# CPU: value from API is 0..1 float
		_cpu_pct=$(echo "${_scpu}" | "${AWK}" '{printf "%d", $1*100+0.5}')

		# Memory %
		_mem_pct=0
		[[ "${_smaxmem}" -gt 0 ]] 2>/dev/null && \
			_mem_pct=$(( _smem * 100 / _smaxmem ))

		# Root disk %
		_disk_pct=0
		[[ "${_smaxdisk}" -gt 0 ]] 2>/dev/null && \
			_disk_pct=$(( _sdisk * 100 / _smaxdisk ))

		# Swap + loadavg from node status (fetched in second prefetch)
		_sstbuf=$(cat "${_pf}/node_status_${_snode}.json" 2>/dev/null)
		_swap_used=$(echo "${_sstbuf}" | "${JQ}" -r '.data.swap.used // 0' 2>/dev/null)
		_swap_total=$(echo "${_sstbuf}" | "${JQ}" -r '.data.swap.total // 0' 2>/dev/null)
		_swap_pct=0
		[[ "${_swap_total}" -gt 0 ]] 2>/dev/null && \
			_swap_pct=$(( _swap_used * 100 / _swap_total ))
		_loadavg=$(echo "${_sstbuf}" | "${JQ}" -r 'if (.data.loadavg | length) > 0 then .data.loadavg[0] else "0" end' 2>/dev/null)

		# Uptime formatting
		_udays=$(( _suptime / 86400 ))
		_uhours=$(( (_suptime % 86400) / 3600 ))
		_umins=$(( (_suptime % 3600) / 60 ))
		_uptime_s="${_udays}d ${_uhours}h ${_umins}m"
		[[ "${_udays}" -eq 0 ]] && _uptime_s="${_uhours}h ${_umins}m"

		_node_state="${status_ok}"
		_node_detail=""

		if [[ "${_cpu_pct}" -ge "${crit_cpu}" ]]; then
			_node_state="${status_crit}"; (( _sys_any_crit++ ))
			_node_detail+=" CPU:${_cpu_pct}%"
		elif [[ "${_cpu_pct}" -ge "${warn_cpu}" ]]; then
			[[ "${_node_state}" == "${status_ok}" ]] && _node_state="${status_warn}"
			(( _sys_any_warn++ ))
			_node_detail+=" CPU:${_cpu_pct}%"
		fi

		if [[ "${_mem_pct}" -ge "${crit_mem}" ]]; then
			[[ "${_node_state}" != "${status_crit}" ]] && _node_state="${status_crit}"
			(( _sys_any_crit++ ))
			_node_detail+=" MEM:${_mem_pct}%"
		elif [[ "${_mem_pct}" -ge "${warn_mem}" ]]; then
			[[ "${_node_state}" == "${status_ok}" ]] && _node_state="${status_warn}"
			(( _sys_any_warn++ ))
			_node_detail+=" MEM:${_mem_pct}%"
		fi

		if [[ "${_swap_total}" -gt 0 ]] 2>/dev/null; then
			if [[ "${_swap_pct}" -ge "${crit_swap}" ]]; then
				[[ "${_node_state}" != "${status_crit}" ]] && _node_state="${status_crit}"
				(( _sys_any_crit++ ))
				_node_detail+=" SWAP:${_swap_pct}%"
			elif [[ "${_swap_pct}" -ge "${warn_swap}" ]]; then
				[[ "${_node_state}" == "${status_ok}" ]] && _node_state="${status_warn}"
				(( _sys_any_warn++ ))
				_node_detail+=" SWAP:${_swap_pct}%"
			fi
		fi

		# Load average (threshold -1 = disabled)
		_load_int=$(echo "${_loadavg}" | "${AWK}" '{printf "%d", $1*100+0.5}')
		if [[ "${crit_load}" -ge 0 ]] 2>/dev/null; then
			_crit_load_int=$(( crit_load * 100 ))
			if [[ "${_load_int}" -ge "${_crit_load_int}" ]]; then
				[[ "${_node_state}" != "${status_crit}" ]] && _node_state="${status_crit}"
				(( _sys_any_crit++ ))
				_node_detail+=" LOAD:${_loadavg}"
			fi
		fi
		if [[ "${warn_load}" -ge 0 ]] 2>/dev/null; then
			_warn_load_int=$(( warn_load * 100 ))
			if [[ "${_load_int}" -ge "${_warn_load_int}" ]]; then
				[[ "${_node_state}" == "${status_ok}" ]] && _node_state="${status_warn}"
				(( _sys_any_warn++ ))
				_node_detail+=" LOAD:${_loadavg}"
			fi
		fi

		_mem_mb=$(( _smaxmem / 1048576 ))
		_mem_used_mb=$(( _smem / 1048576 ))
		_swap_mb=$(( _swap_total / 1048576 ))
		_swap_used_mb=$(( _swap_used / 1048576 ))
		_perf_lbl="${_snode//-/_}"

		# iowait from node status
		_iowait=$(echo "${_sstbuf}" | "${JQ}" -r '.data.wait // 0' 2>/dev/null)
		_iowait_pct=$(echo "${_iowait}" | "${AWK}" '{printf "%d", $1*100+0.5}')

		if [[ -n "${verbose}" ]]; then
			pve_output+="${_node_state} - Node ${_snode}: CPU: ${_cpu_pct}% (warn: ${warn_cpu}%, crit: ${crit_cpu}%)"
			pve_output+=" | Memory: ${_mem_pct}% (${_mem_used_mb}/${_mem_mb} MB)"
			[[ "${_swap_total}" -gt 0 ]] 2>/dev/null && \
				pve_output+=" | Swap: ${_swap_pct}% (${_swap_used_mb}/${_swap_mb} MB)"
			[[ "${_smaxdisk}" -gt 0 ]] 2>/dev/null && \
				pve_output+=" | RootFS: ${_disk_pct}% ($(_fmt_bytes "${_sdisk}")/$(_fmt_bytes "${_smaxdisk}"))"
			pve_output+=" | IOWait: ${_iowait_pct}% | Load: ${_loadavg} | Uptime: ${_uptime_s}\n"
		fi

		[[ "${_node_state}" != "${status_ok}" ]] && \
			pve_problem_output+="${_node_state} - Node ${_snode}: resources degraded:${_node_detail}\n"

		pve_perf+=" pve_${_perf_lbl}_cpu=${_cpu_pct};${warn_cpu};${crit_cpu};0;100"
		pve_perf+=" pve_${_perf_lbl}_mem=${_mem_pct}%;${warn_mem};${crit_mem};0;100"
		pve_perf+=" pve_${_perf_lbl}_mem_used=${_mem_used_mb}MB"
		pve_perf+=" pve_${_perf_lbl}_mem_total=${_mem_mb}MB"
		[[ "${_swap_total}" -gt 0 ]] 2>/dev/null && \
			pve_perf+=" pve_${_perf_lbl}_swap=${_swap_pct}%;${warn_swap};${crit_swap};0;100"
		[[ "${_smaxdisk}" -gt 0 ]] 2>/dev/null && \
			pve_perf+=" pve_${_perf_lbl}_rootfs_pct=${_disk_pct}%;85;95;0;100"
		pve_perf+=" pve_${_perf_lbl}_iowait=${_iowait_pct}"
		[[ "${_suptime}" =~ ^[0-9]+$ ]] && \
			pve_perf+=" pve_${_perf_lbl}_uptime=${_suptime}"

	done < <(echo "${_res_buf}" | "${JQ}" --unbuffered -r '
		.data[]? | select(.type=="node") | [
			(.node // ""),
			((.cpu // 0) | tostring),
			((.maxcpu // 1) | tostring),
			((.mem // 0) | tostring),
			((.maxmem // 1) | tostring),
			((.disk // 0) | tostring),
			((.maxdisk // 0) | tostring),
			((.uptime // 0) | tostring)
		] | join("\t")' 2>/dev/null)

	if [[ "${_sys_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - System Resources: ${_sys_any_crit} node(s) critical\n"
	elif [[ "${_sys_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - System Resources: ${_sys_any_warn} node(s) warning\n"
	else
		pve_output+="${status_ok} - System Resources: all nodes within thresholds\n"
	fi

	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Cluster Status Check (-eCluster)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_cluster}" || -n "${enable_all}" ) && -z "${disable_cluster}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="Cluster Status:\n---------------------------------------\n"
	fi

	if [[ "${_is_cluster}" -eq 0 ]]; then
		pve_output+="${status_ok} - Cluster: standalone node (no cluster configured)\n"
	else
		_cls_name=$(echo "${_cls_buf}" | "${JQ}" -r '.data[]? | select(.type=="cluster") | .name // "unknown"' 2>/dev/null)
		_cls_quorate=$(echo "${_cls_buf}" | "${JQ}" -r '.data[]? | select(.type=="cluster") | .quorate // 0' 2>/dev/null)
		_cls_nodes=$(echo "${_cls_buf}" | "${JQ}" -r '.data[]? | select(.type=="cluster") | .nodes // 0' 2>/dev/null)

		_cls_online=0; _cls_offline=0
		_cls_node_lines=""
		while IFS=$'\t' read -r _cn _co _cl; do
			[[ -z "${_cn}" ]] && continue
			if [[ "${_co}" == "1" ]]; then
				(( _cls_online++ ))
				_cn_state="${status_ok}"
			else
				(( _cls_offline++ ))
				_cn_state="${status_crit}"
			fi
			_local_s=""; [[ "${_cl}" == "1" ]] && _local_s=" (local)"
			_cls_node_lines+="${_cn_state} -   Node ${_cn}: $([ "${_co}" == "1" ] && echo online || echo offline)${_local_s}\n"
		done < <(echo "${_cls_buf}" | "${JQ}" --unbuffered -r '
			.data[]? | select(.type=="node") | [
				(.name // ""), ((.online // 0) | tostring), ((.local // 0) | tostring)
			] | join("\t")' 2>/dev/null)

		_cls_state="${status_ok}"
		_cls_detail=""
		if [[ "${_cls_quorate}" != "1" ]]; then
			_cls_state="${status_crit}"
			_cls_detail=" (QUORUM LOST)"
			pve_problem_output+="${status_crit} - Cluster ${_cls_name}: quorum lost\n"
		elif [[ "${_cls_offline}" -gt 0 ]]; then
			_cls_state="${status_crit}"
			_cls_detail=" (${_cls_offline} node(s) offline)"
			pve_problem_output+="${status_crit} - Cluster ${_cls_name}: ${_cls_offline}/${_cls_nodes} node(s) offline\n"
		fi

		[[ -n "${verbose}" ]] && pve_output+="${_cls_node_lines}"
		pve_output+="${_cls_state} - Cluster ${_cls_name}: ${_cls_online}/${_cls_nodes} nodes online${_cls_detail}\n"

		pve_perf+=" cluster_nodes_total=${_cls_nodes}"
		pve_perf+=" cluster_nodes_online=${_cls_online}"
		pve_perf+=" cluster_quorate=${_cls_quorate}"
	fi

	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Virtual Machine Status Check (-eVM)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Pre-build per-VMID replication summary (used in -eVM, -eCT, --vm, --ct)
# ---------------------------------------------------------------------------
declare -A _vrepl_cnt=() _vrepl_last=() _vrepl_ok=()
_repl_now=$(date +%s)
if [[ -n "${_repl_buf}" ]]; then
	while IFS=$'\t' read -r _rvm _rlsync _rerr _rfail; do
		[[ -z "${_rvm}" || "${_rvm}" == "0" ]] && continue
		_vrepl_cnt["${_rvm}"]=$(( ${_vrepl_cnt["${_rvm}"]:-0} + 1 ))
		if [[ -n "${_rerr}" && "${_rerr}" != "null" ]]; then
			_vrepl_ok["${_rvm}"]="crit"
		elif [[ "${_rfail}" =~ ^[0-9]+$ && "${_rfail}" -gt 0 ]]; then
			[[ "${_vrepl_ok[${_rvm}]:-ok}" != "crit" ]] && _vrepl_ok["${_rvm}"]="warn"
		else
			[[ -z "${_vrepl_ok[${_rvm}]:-}" ]] && _vrepl_ok["${_rvm}"]="ok"
		fi
		if [[ "${_rlsync}" =~ ^[0-9]+$ && "${_rlsync}" -gt "${_vrepl_last[${_rvm}]:-0}" ]]; then
			_vrepl_last["${_rvm}"]="${_rlsync}"
		fi
	done < <(echo "${_repl_buf}" | "${JQ}" -r '
		.data[]? | select((.disable // 0) != 1) | [
			((.vmid // 0) | tostring),
			((.last_sync // 0) | tostring),
			(.error // ""),
			((.fail_count // 0) | tostring)
		] | join("\t")' 2>/dev/null)
fi

# Helper: format replication summary for a given VMID
_fmt_repl_summary() {
	local vmid="$1" cnt ok lst age_m age_s lbl
	cnt="${_vrepl_cnt[${vmid}]:-0}"
	[[ "${cnt}" -eq 0 ]] && return
	ok="${_vrepl_ok[${vmid}]:-ok}"
	lst="${_vrepl_last[${vmid}]:-0}"
	lbl="${status_ok}"
	[[ "${ok}" == "warn" ]] && lbl="${status_warn}"
	[[ "${ok}" == "crit" ]] && lbl="${status_crit}"
	if [[ "${lst}" -gt 0 ]]; then
		age_m=$(( (_repl_now - lst) / 60 ))
		if [[ "${age_m}" -ge 60 ]]; then
			age_s="$(( age_m / 60 ))h $(( age_m % 60 ))m ago"
		else
			age_s="${age_m}m ago"
		fi
		echo "${lbl} -   ${2} Replication: ${cnt} job(s), last sync: ${age_s}"
	else
		echo "${lbl} -   ${2} Replication: ${cnt} job(s), never synced"
	fi
}

if [[ ( -n "${enable_vm}" || -n "${enable_all}" ) && -z "${disable_vm}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="Virtual Machines:\n---------------------------------------\n"
	fi

	declare -A _vm_bl_map=()
	if [[ -n "${vm_blacklist}" ]]; then
		IFS=',' read -ra _vm_bl_arr <<< "${vm_blacklist}"
		for _e in "${_vm_bl_arr[@]}"; do _vm_bl_map["${_e// /}"]=1; done
	fi

	_vm_total=0; _vm_running=0; _vm_stopped=0; _vm_paused=0; _vm_other=0
	_vm_any_crit=0; _vm_any_warn=0
	_vm_sel_id=""; _vm_sel_node=""  # track matched VM for --vm detail fetch

	while IFS=$'\t' read -r _vmid _vmname _vmstatus _vmnode _vmcpu _vmcpumax \
	                          _vmmem _vmmmem _vmtemplate _vmdisk _vmmdisk _vmuptime; do
		[[ -z "${_vmid}" ]] && continue
		# Skip templates unless explicitly included
		[[ -n "${ignore_vm_template}" && "${_vmtemplate}" == "1" ]] && continue
		# Apply blacklist
		[[ -n "${_vm_bl_map[${_vmid}]:-}" || -n "${_vm_bl_map[${_vmname}]:-}" ]] && continue
		# Node filter
		[[ -n "${pve_node}" && "${_vmnode}" != "${pve_node}" ]] && continue
		# Single-VM filter (--vm)
		if [[ -n "${vm_filter}" ]]; then
			[[ "${_vmid}" != "${vm_filter}" && "${_vmname}" != "${vm_filter}" ]] && continue
			_vm_sel_id="${_vmid}"; _vm_sel_node="${_vmnode}"
		fi

		(( _vm_total++ ))

		_cpu_pct=$(echo "${_vmcpu}" | "${AWK}" '{printf "%d", $1*100+0.5}')
		_mem_pct=0
		[[ "${_vmmmem}" -gt 0 ]] 2>/dev/null && _mem_pct=$(( _vmmem * 100 / _vmmmem ))

		_vm_state="${status_ok}"
		case "${_vmstatus}" in
			running)
				(( _vm_running++ ))
				;;
			stopped)
				(( _vm_stopped++ ))
				if [[ -n "${crit_stopped_vm}" ]]; then
					_vm_state="${status_crit}"; (( _vm_any_crit++ ))
				elif [[ -n "${warn_stopped_vm}" ]]; then
					_vm_state="${status_warn}"; (( _vm_any_warn++ ))
				fi
				;;
			paused|suspended)
				(( _vm_paused++ ))
				_vm_state="${status_warn}"; (( _vm_any_warn++ ))
				;;
			*)
				(( _vm_other++ ))
				_vm_state="${status_crit}"; (( _vm_any_crit++ ))
				;;
		esac

		[[ "${_vm_state}" != "${status_ok}" ]] && \
			pve_problem_output+="${_vm_state} - VM ${_vmid}/${_vmname} on ${_vmnode}: ${_vmstatus}\n"

		# Guest resource thresholds for running VMs (-eVM)
		if [[ "${_vmstatus}" == "running" ]]; then
			if [[ "${_cpu_pct}" -ge "${crit_guest_cpu}" ]] 2>/dev/null; then
				[[ "${_vm_state}" != "${status_crit}" ]] && { _vm_state="${status_crit}"; (( _vm_any_crit++ )); }
				pve_problem_output+="${status_crit} - VM ${_vmid}/${_vmname} (${_vmnode}): CPU ${_cpu_pct}% >= ${crit_guest_cpu}%\n"
			elif [[ "${_cpu_pct}" -ge "${warn_guest_cpu}" ]] 2>/dev/null; then
				[[ "${_vm_state}" == "${status_ok}" ]] && { _vm_state="${status_warn}"; (( _vm_any_warn++ )); }
				pve_problem_output+="${status_warn} - VM ${_vmid}/${_vmname} (${_vmnode}): CPU ${_cpu_pct}% >= ${warn_guest_cpu}%\n"
			fi
			if [[ "${_mem_pct}" -ge "${crit_guest_mem}" ]] 2>/dev/null; then
				[[ "${_vm_state}" != "${status_crit}" ]] && { _vm_state="${status_crit}"; (( _vm_any_crit++ )); }
				pve_problem_output+="${status_crit} - VM ${_vmid}/${_vmname} (${_vmnode}): Mem ${_mem_pct}% >= ${crit_guest_mem}%\n"
			elif [[ "${_mem_pct}" -ge "${warn_guest_mem}" ]] 2>/dev/null; then
				[[ "${_vm_state}" == "${status_ok}" ]] && { _vm_state="${status_warn}"; (( _vm_any_warn++ )); }
				pve_problem_output+="${status_warn} - VM ${_vmid}/${_vmname} (${_vmnode}): Mem ${_mem_pct}% >= ${warn_guest_mem}%\n"
			fi
			# QEMU guest agent check (--warn-agent) — result stored for verbose output below
			_vagent_state=""
			if [[ -n "${warn_agent}" ]]; then
				_vagent_buf=$(pve_api_get "${PVE_API}/nodes/${_vmnode}/qemu/${_vmid}/agent/info" 2>/dev/null)
				if echo "${_vagent_buf}" | "${JQ}" -e '.data' >/dev/null 2>&1; then
					_vagent_state="ok"
				else
					_vagent_state="warn"
					[[ "${_vm_state}" == "${status_ok}" ]] && { _vm_state="${status_warn}"; (( _vm_any_warn++ )); }
					pve_problem_output+="${status_warn} - VM ${_vmid}/${_vmname} (${_vmnode}): QEMU guest agent not running\n"
				fi
			fi
		fi

		if [[ -n "${verbose}" ]]; then
			_vm_detail=""
			[[ "${_vmstatus}" == "running" && "${_vmcpumax}" -gt 0 ]] && \
				_vm_detail=" | CPU: ${_cpu_pct}% | Mem: ${_mem_pct}%"
			[[ "${_vmuptime}" =~ ^[0-9]+$ && "${_vmuptime}" -gt 0 ]] && {
				_vud=$(( _vmuptime / 86400 )); _vuh=$(( (_vmuptime % 86400) / 3600 ))
				_vm_detail+=" | Up: ${_vud}d ${_vuh}h"
			}
			pve_output+="${_vm_state} -   VM ${_vmid} ${_vmname} (${_vmnode}): ${_vmstatus}${_vm_detail}\n"
			[[ "${_vagent_state}" == "ok"   ]] && pve_output+="${status_ok}   -   VM ${_vmid} Guest agent: running\n"
			[[ "${_vagent_state}" == "warn" ]] && pve_output+="${status_warn} -   VM ${_vmid} Guest agent: not running\n"
			_repl_line=$(_fmt_repl_summary "${_vmid}" "VM ${_vmid}")
			[[ -n "${_repl_line}" ]] && pve_output+="${_repl_line}\n"
		fi

		_vm_lbl="${_vmid}_${_vmname//[^a-zA-Z0-9]/_}"
		[[ "${_vmstatus}" == "running" ]] && {
			pve_perf+=" vm_${_vm_lbl}_cpu=${_cpu_pct};${warn_cpu};${crit_cpu};0;100"
			pve_perf+=" vm_${_vm_lbl}_mem=${_mem_pct}%;${warn_mem};${crit_mem};0;100"
		}

	done < <(echo "${_res_buf}" | "${JQ}" --unbuffered -r '
		.data[]? | select(.type=="qemu") | [
			((.vmid // 0) | tostring),
			(.name // ""),
			(.status // ""),
			(.node // ""),
			((.cpu // 0) | tostring),
			((.maxcpu // 1) | tostring),
			((.mem // 0) | tostring),
			((.maxmem // 0) | tostring),
			((.template // 0) | tostring),
			((.disk // 0) | tostring),
			((.maxdisk // 0) | tostring),
			((.uptime // 0) | tostring)
		] | join("\t")' 2>/dev/null)

	# Detailed metrics for single selected VM (--vm)
	if [[ -n "${vm_filter}" && -n "${_vm_sel_id}" ]]; then
		_vm_lbl="${_vm_sel_id}_${vm_filter//[^a-zA-Z0-9]/_}"
		# rrddata: last non-null sample — cpu (0-1), mem, maxmem, disk, maxdisk, swap, maxswap, rates
		_vr_buf=$(pve_api_get "${PVE_API}/nodes/${_vm_sel_node}/qemu/${_vm_sel_id}/rrddata?timeframe=hour&cf=AVERAGE" 2>/dev/null)
		_vr_vals=$(echo "${_vr_buf}" | "${JQ}" -r \
			'.data | map(select(.cpu != null)) | last |
			[(.cpu // 0), (.mem // 0), (.maxmem // 0), (.disk // 0), (.maxdisk // 0),
			 (.swap // 0), (.maxswap // 0),
			 (.netin // 0), (.netout // 0), (.diskread // 0), (.diskwrite // 0)] | join("\t")' 2>/dev/null)
		if [[ -n "${_vr_vals}" ]]; then
			IFS=$'\t' read -r _vd_cpu _vd_mem _vd_maxmem _vd_disk _vd_maxdisk \
				_vd_swap _vd_maxswap \
				_vd_netin_r _vd_netout_r _vd_diskrd_r _vd_diskwr_r <<< "${_vr_vals}"
		else
			_vd_cpu=0; _vd_mem=0; _vd_maxmem=0; _vd_disk=0; _vd_maxdisk=0
			_vd_swap=0; _vd_maxswap=0
			_vd_netin_r=0; _vd_netout_r=0; _vd_diskrd_r=0; _vd_diskwr_r=0
		fi
		# Cumulative totals from status/current
		_vd_buf=$(pve_api_get "${PVE_API}/nodes/${_vm_sel_node}/qemu/${_vm_sel_id}/status/current" 2>/dev/null)
		_vd_netin=$(echo "${_vd_buf}"  | "${JQ}" -r '.data.netin    // 0' 2>/dev/null)
		_vd_netout=$(echo "${_vd_buf}" | "${JQ}" -r '.data.netout   // 0' 2>/dev/null)
		_vd_diskrd=$(echo "${_vd_buf}" | "${JQ}" -r '.data.diskread  // 0' 2>/dev/null)
		_vd_diskwr=$(echo "${_vd_buf}" | "${JQ}" -r '.data.diskwrite // 0' 2>/dev/null)
		# Compute derived integer values
		_vd_cpu_pct=$(echo "${_vd_cpu}"     | "${AWK}" '{printf "%.1f", $1*100}')
		_vd_cpu_pct_i=$(echo "${_vd_cpu_pct}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_mem_i=$(echo "${_vd_mem}"       | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_maxmem_i=$(echo "${_vd_maxmem}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_disk_i=$(echo "${_vd_disk}"     | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_maxdisk_i=$(echo "${_vd_maxdisk}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_swap_i=$(echo "${_vd_swap}"     | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_maxswap_i=$(echo "${_vd_maxswap}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_mem_pct=$(echo  "${_vd_mem} ${_vd_maxmem}"   | "${AWK}" '{if($2>0) printf "%.1f", $1*100/$2; else print "0"}')
		_vd_disk_pct=$(echo "${_vd_disk} ${_vd_maxdisk}" | "${AWK}" '{if($2>0) printf "%.1f", $1*100/$2; else print "0"}')
		_vd_swap_pct=$(echo "${_vd_swap} ${_vd_maxswap}" | "${AWK}" '{if($2>0) printf "%.1f", $1*100/$2; else print "0"}')
		_vd_mem_pct_i=$(echo  "${_vd_mem_pct}"  | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_disk_pct_i=$(echo "${_vd_disk_pct}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_swap_pct_i=$(echo "${_vd_swap_pct}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_netin_ri=$(echo  "${_vd_netin_r}"  | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_netout_ri=$(echo "${_vd_netout_r}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_diskrd_ri=$(echo "${_vd_diskrd_r}" | "${AWK}" '{printf "%d", $1+0.5}')
		_vd_diskwr_ri=$(echo "${_vd_diskwr_r}" | "${AWK}" '{printf "%d", $1+0.5}')
		# Compute per-metric states (CPU/mem already checked in loop; compute for verbose display)
		_vds_cpu="${status_ok}"; _vds_mem="${status_ok}"; _vds_disk="${status_ok}"
		_vds_swap="${status_ok}"; _vds_netin="${status_ok}"; _vds_netout="${status_ok}"
		if [[ "${_vd_cpu_pct_i}" -ge "${crit_guest_cpu}" ]] 2>/dev/null;   then _vds_cpu="${status_crit}"
		elif [[ "${_vd_cpu_pct_i}" -ge "${warn_guest_cpu}" ]] 2>/dev/null; then _vds_cpu="${status_warn}"; fi
		if [[ "${_vd_mem_pct_i}" -ge "${crit_guest_mem}" ]] 2>/dev/null;   then _vds_mem="${status_crit}"
		elif [[ "${_vd_mem_pct_i}" -ge "${warn_guest_mem}" ]] 2>/dev/null; then _vds_mem="${status_warn}"; fi
		# Disk/swap/net thresholds not in loop — check here with counter+problem_output
		if [[ "${_vd_maxdisk_i}" -gt 0 ]]; then
			if [[ "${_vd_disk_pct_i}" -ge "${crit_guest_disk}" ]] 2>/dev/null; then
				_vds_disk="${status_crit}"; (( _vm_any_crit++ ))
				pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): Disk ${_vd_disk_pct}% >= ${crit_guest_disk}%\n"
			elif [[ "${_vd_disk_pct_i}" -ge "${warn_guest_disk}" ]] 2>/dev/null; then
				_vds_disk="${status_warn}"; (( _vm_any_warn++ ))
				pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): Disk ${_vd_disk_pct}% >= ${warn_guest_disk}%\n"
			fi
		fi
		if [[ "${_vd_maxswap_i}" -gt 0 ]]; then
			if [[ "${_vd_swap_pct_i}" -ge "${crit_swap}" ]] 2>/dev/null; then
				_vds_swap="${status_crit}"; (( _vm_any_crit++ ))
				pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): Swap ${_vd_swap_pct}% >= ${crit_swap}%\n"
			elif [[ "${_vd_swap_pct_i}" -ge "${warn_swap}" ]] 2>/dev/null; then
				_vds_swap="${status_warn}"; (( _vm_any_warn++ ))
				pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): Swap ${_vd_swap_pct}% >= ${warn_swap}%\n"
			fi
		fi
		if [[ -n "${crit_net_in}" && "${_vd_netin_ri}" -ge "${crit_net_in}" ]] 2>/dev/null; then
			_vds_netin="${status_crit}"; (( _vm_any_crit++ ))
			pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): net in $(_fmt_bytes "${_vd_netin_ri}")/s >= $(_fmt_bytes "${crit_net_in}")/s\n"
		elif [[ -n "${warn_net_in}" && "${_vd_netin_ri}" -ge "${warn_net_in}" ]] 2>/dev/null; then
			_vds_netin="${status_warn}"; (( _vm_any_warn++ ))
			pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): net in $(_fmt_bytes "${_vd_netin_ri}")/s >= $(_fmt_bytes "${warn_net_in}")/s\n"
		fi
		if [[ -n "${crit_net_out}" && "${_vd_netout_ri}" -ge "${crit_net_out}" ]] 2>/dev/null; then
			_vds_netout="${status_crit}"; (( _vm_any_crit++ ))
			pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): net out $(_fmt_bytes "${_vd_netout_ri}")/s >= $(_fmt_bytes "${crit_net_out}")/s\n"
		elif [[ -n "${warn_net_out}" && "${_vd_netout_ri}" -ge "${warn_net_out}" ]] 2>/dev/null; then
			_vds_netout="${status_warn}"; (( _vm_any_warn++ ))
			pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): net out $(_fmt_bytes "${_vd_netout_ri}")/s >= $(_fmt_bytes "${warn_net_out}")/s\n"
		fi
		if [[ -n "${verbose}" ]]; then
			pve_output+="${_vds_cpu} -   VM ${_vm_sel_id} CPU: ${_vd_cpu_pct}%\n"
			pve_output+="${_vds_mem} -   VM ${_vm_sel_id} Memory: $(_fmt_bytes "${_vd_mem_i}") / $(_fmt_bytes "${_vd_maxmem_i}") (${_vd_mem_pct}%)\n"
			[[ "${_vd_maxswap_i}" -gt 0 ]] && \
				pve_output+="${_vds_swap} -   VM ${_vm_sel_id} Swap: $(_fmt_bytes "${_vd_swap_i}") / $(_fmt_bytes "${_vd_maxswap_i}") (${_vd_swap_pct}%)\n"
			[[ "${_vd_maxdisk_i}" -gt 0 ]] && \
				pve_output+="${_vds_disk} -   VM ${_vm_sel_id} Disk: $(_fmt_bytes "${_vd_disk_i}") / $(_fmt_bytes "${_vd_maxdisk_i}") (${_vd_disk_pct}%)\n"
			pve_output+="${_vds_netin} -   VM ${_vm_sel_id} I/O rates (1-min avg): disk read $(_fmt_bytes "${_vd_diskrd_ri}")/s | disk write $(_fmt_bytes "${_vd_diskwr_ri}")/s | net in $(_fmt_bytes "${_vd_netin_ri}")/s | net out $(_fmt_bytes "${_vd_netout_ri}")/s\n"
			pve_output+="${status_ok} -   VM ${_vm_sel_id} I/O total (since boot): disk read $(_fmt_bytes "${_vd_diskrd}") | disk write $(_fmt_bytes "${_vd_diskwr}") | net in $(_fmt_bytes "${_vd_netin}") | net out $(_fmt_bytes "${_vd_netout}")\n"
		fi
		# Snapshots
		_vsnap_buf=$(pve_api_get "${PVE_API}/nodes/${_vm_sel_node}/qemu/${_vm_sel_id}/snapshot" 2>/dev/null)
		_vsnap_count=0; _vsnap_newest=0
		while IFS='	' read -r _vsname _vstime; do
			[[ "${_vsname}" == "current" || -z "${_vsname}" ]] && continue
			(( _vsnap_count++ ))
			[[ "${_vstime}" =~ ^[0-9]+$ && "${_vstime}" -gt "${_vsnap_newest}" ]] && _vsnap_newest="${_vstime}"
		done < <(echo "${_vsnap_buf}" | "${JQ}" -r '.data[]? | [(.name // ""), ((.snaptime // 0) | tostring)] | join("\t")' 2>/dev/null)
		_vsnap_state="${status_ok}"; _vsage_d=0
		if [[ "${_vsnap_count}" -gt 0 ]]; then
			_vsage_d=$(( ($(date +%s) - _vsnap_newest) / 86400 ))
			if [[ -n "${crit_snap_count}" && "${_vsnap_count}" -ge "${crit_snap_count}" ]] 2>/dev/null; then
				_vsnap_state="${status_crit}"; (( _vm_any_crit++ ))
				pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): ${_vsnap_count} snapshot(s) >= ${crit_snap_count}\n"
			elif [[ -n "${warn_snap_count}" && "${_vsnap_count}" -ge "${warn_snap_count}" ]] 2>/dev/null; then
				_vsnap_state="${status_warn}"; (( _vm_any_warn++ ))
				pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): ${_vsnap_count} snapshot(s) >= ${warn_snap_count}\n"
			fi
			if [[ "${_vsage_d}" -ge "${crit_snap_age}" ]] 2>/dev/null; then
				[[ "${_vsnap_state}" != "${status_crit}" ]] && { _vsnap_state="${status_crit}"; (( _vm_any_crit++ )); }
				pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): newest snapshot ${_vsage_d}d old (>= ${crit_snap_age}d)\n"
			elif [[ "${_vsage_d}" -ge "${warn_snap_age}" ]] 2>/dev/null; then
				[[ "${_vsnap_state}" == "${status_ok}" ]] && { _vsnap_state="${status_warn}"; (( _vm_any_warn++ )); }
				pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): newest snapshot ${_vsage_d}d old (>= ${warn_snap_age}d)\n"
			fi
		fi
		if [[ -n "${verbose}" ]]; then
			if [[ "${_vsnap_count}" -gt 0 ]]; then
				pve_output+="${_vsnap_state} -   VM ${_vm_sel_id} Snapshots: ${_vsnap_count} snapshot(s), newest: ${_vsage_d}d ago\n"
			else
				pve_output+="${status_ok} -   VM ${_vm_sel_id} Snapshots: none\n"
			fi
		fi
		pve_perf+=" vm_${_vm_lbl}_snaps=${_vsnap_count}"
		# Replication detail with age threshold
		if [[ "${_vrepl_cnt[${_vm_sel_id}]:-0}" -gt 0 ]]; then
			_vrepl_age_min=0; _vrepl_age_s="never synced"
			_vrepl_state="${status_ok}"
			[[ "${_vrepl_ok[${_vm_sel_id}]:-ok}" == "warn" ]] && _vrepl_state="${status_warn}"
			[[ "${_vrepl_ok[${_vm_sel_id}]:-ok}" == "crit" ]] && _vrepl_state="${status_crit}"
			if [[ "${_vrepl_last[${_vm_sel_id}]:-0}" -gt 0 ]]; then
				_vrepl_age_min=$(( (_repl_now - _vrepl_last[${_vm_sel_id}]) / 60 ))
				if [[ "${_vrepl_age_min}" -ge 60 ]]; then
					_vrepl_age_s="$(( _vrepl_age_min / 60 ))h $(( _vrepl_age_min % 60 ))m ago"
				else
					_vrepl_age_s="${_vrepl_age_min}m ago"
				fi
				if [[ "${_vrepl_age_min}" -ge "${crit_repl_age}" ]] 2>/dev/null; then
					[[ "${_vrepl_state}" != "${status_crit}" ]] && { _vrepl_state="${status_crit}"; (( _vm_any_crit++ )); }
					pve_problem_output+="${status_crit} - VM ${_vm_sel_id} (${_vm_sel_node}): last replication ${_vrepl_age_s} (>= ${crit_repl_age}m)\n"
				elif [[ "${_vrepl_age_min}" -ge "${warn_repl_age}" ]] 2>/dev/null; then
					[[ "${_vrepl_state}" == "${status_ok}" ]] && { _vrepl_state="${status_warn}"; (( _vm_any_warn++ )); }
					pve_problem_output+="${status_warn} - VM ${_vm_sel_id} (${_vm_sel_node}): last replication ${_vrepl_age_s} (>= ${warn_repl_age}m)\n"
				fi
			fi
			[[ -n "${verbose}" ]] && pve_output+="${_vrepl_state} -   VM ${_vm_sel_id} Replication: ${_vrepl_cnt[${_vm_sel_id}]} job(s), last sync: ${_vrepl_age_s}\n"
			pve_perf+=" vm_${_vm_lbl}_repl_age=${_vrepl_age_min};${warn_repl_age};${crit_repl_age};0"
		elif [[ -n "${verbose}" ]]; then
			pve_output+="${status_ok} -   VM ${_vm_sel_id} Replication: none\n"
		fi
		pve_perf+=" vm_${_vm_lbl}_cpu=${_vd_cpu_pct}%;${warn_guest_cpu};${crit_guest_cpu};0;100"
		pve_perf+=" vm_${_vm_lbl}_mem=${_vd_mem_i} vm_${_vm_lbl}_mem_pct=${_vd_mem_pct}%;${warn_guest_mem};${crit_guest_mem};0;100"
		[[ "${_vd_maxdisk_i}" -gt 0 ]] && \
			pve_perf+=" vm_${_vm_lbl}_disk=${_vd_disk_i} vm_${_vm_lbl}_disk_pct=${_vd_disk_pct}%;${warn_guest_disk};${crit_guest_disk};0;100"
		[[ "${_vd_maxswap_i}" -gt 0 ]] && \
			pve_perf+=" vm_${_vm_lbl}_swap=${_vd_swap_i} vm_${_vm_lbl}_swap_pct=${_vd_swap_pct}%;${warn_swap};${crit_swap};0;100"
		pve_perf+=" vm_${_vm_lbl}_netin_rate=${_vd_netin_ri} vm_${_vm_lbl}_netout_rate=${_vd_netout_ri}"
		pve_perf+=" vm_${_vm_lbl}_diskread_rate=${_vd_diskrd_ri} vm_${_vm_lbl}_diskwrite_rate=${_vd_diskwr_ri}"
		pve_perf+=" vm_${_vm_lbl}_netin=${_vd_netin} vm_${_vm_lbl}_netout=${_vd_netout}"
		pve_perf+=" vm_${_vm_lbl}_diskread=${_vd_diskrd} vm_${_vm_lbl}_diskwrite=${_vd_diskwr}"
	elif [[ -n "${vm_filter}" && -z "${_vm_sel_id}" ]]; then
		pve_output+="${status_unknown} - VM '${vm_filter}' not found\n"
		pve_problem_output+="${status_unknown} - VM '${vm_filter}' not found\n"
	fi

	if [[ "${_vm_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Virtual Machines: ${_vm_total} total | ${_vm_running} running, ${_vm_stopped} stopped, ${_vm_paused} paused | ${_vm_any_crit} critical\n"
	elif [[ "${_vm_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Virtual Machines: ${_vm_total} total | ${_vm_running} running, ${_vm_stopped} stopped, ${_vm_paused} paused | ${_vm_any_warn} warning\n"
	else
		pve_output+="${status_ok} - Virtual Machines: ${_vm_total} total | ${_vm_running} running, ${_vm_stopped} stopped\n"
	fi

	pve_perf+=" vm_total=${_vm_total} vm_running=${_vm_running} vm_stopped=${_vm_stopped}"
	[[ "${_vm_paused}" -gt 0 ]] && pve_perf+=" vm_paused=${_vm_paused}"

	unset _vm_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Container Status Check (-eCT)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_ct}" || -n "${enable_all}" ) && -z "${disable_ct}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="Containers (LXC):\n---------------------------------------\n"
	fi

	declare -A _ct_bl_map=()
	if [[ -n "${ct_blacklist}" ]]; then
		IFS=',' read -ra _ct_bl_arr <<< "${ct_blacklist}"
		for _e in "${_ct_bl_arr[@]}"; do _ct_bl_map["${_e// /}"]=1; done
	fi

	_ct_total=0; _ct_running=0; _ct_stopped=0; _ct_paused=0; _ct_other=0
	_ct_any_crit=0; _ct_any_warn=0
	_ct_sel_id=""; _ct_sel_node=""  # track matched CT for --ct detail fetch

	while IFS=$'\t' read -r _ctid _ctname _ctstatus _ctnode _ctcpu _ctcpumax \
	                          _ctmem _ctmmem _ctdisk _ctmdisk _ctuptime; do
		[[ -z "${_ctid}" ]] && continue
		[[ -n "${_ct_bl_map[${_ctid}]:-}" || -n "${_ct_bl_map[${_ctname}]:-}" ]] && continue
		[[ -n "${pve_node}" && "${_ctnode}" != "${pve_node}" ]] && continue
		# Single-CT filter (--ct)
		if [[ -n "${ct_filter}" ]]; then
			[[ "${_ctid}" != "${ct_filter}" && "${_ctname}" != "${ct_filter}" ]] && continue
			_ct_sel_id="${_ctid}"; _ct_sel_node="${_ctnode}"
		fi

		(( _ct_total++ ))

		_ct_cpu_pct=$(echo "${_ctcpu}" | "${AWK}" '{printf "%d", $1*100+0.5}')
		_ct_mem_pct=0
		[[ "${_ctmmem}" -gt 0 ]] 2>/dev/null && _ct_mem_pct=$(( _ctmem * 100 / _ctmmem ))

		_ct_state="${status_ok}"
		case "${_ctstatus}" in
			running)
				(( _ct_running++ ))
				;;
			stopped)
				(( _ct_stopped++ ))
				if [[ -n "${crit_stopped_ct}" ]]; then
					_ct_state="${status_crit}"; (( _ct_any_crit++ ))
				elif [[ -n "${warn_stopped_ct}" ]]; then
					_ct_state="${status_warn}"; (( _ct_any_warn++ ))
				fi
				;;
			paused|suspended)
				(( _ct_paused++ ))
				_ct_state="${status_warn}"; (( _ct_any_warn++ ))
				;;
			*)
				(( _ct_other++ ))
				_ct_state="${status_crit}"; (( _ct_any_crit++ ))
				;;
		esac

		[[ "${_ct_state}" != "${status_ok}" ]] && \
			pve_problem_output+="${_ct_state} - CT ${_ctid}/${_ctname} on ${_ctnode}: ${_ctstatus}\n"

		# Guest resource thresholds for running CTs (-eCT)
		if [[ "${_ctstatus}" == "running" ]]; then
			if [[ "${_ct_cpu_pct}" -ge "${crit_guest_cpu}" ]] 2>/dev/null; then
				[[ "${_ct_state}" != "${status_crit}" ]] && { _ct_state="${status_crit}"; (( _ct_any_crit++ )); }
				pve_problem_output+="${status_crit} - CT ${_ctid}/${_ctname} (${_ctnode}): CPU ${_ct_cpu_pct}% >= ${crit_guest_cpu}%\n"
			elif [[ "${_ct_cpu_pct}" -ge "${warn_guest_cpu}" ]] 2>/dev/null; then
				[[ "${_ct_state}" == "${status_ok}" ]] && { _ct_state="${status_warn}"; (( _ct_any_warn++ )); }
				pve_problem_output+="${status_warn} - CT ${_ctid}/${_ctname} (${_ctnode}): CPU ${_ct_cpu_pct}% >= ${warn_guest_cpu}%\n"
			fi
			if [[ "${_ct_mem_pct}" -ge "${crit_guest_mem}" ]] 2>/dev/null; then
				[[ "${_ct_state}" != "${status_crit}" ]] && { _ct_state="${status_crit}"; (( _ct_any_crit++ )); }
				pve_problem_output+="${status_crit} - CT ${_ctid}/${_ctname} (${_ctnode}): Mem ${_ct_mem_pct}% >= ${crit_guest_mem}%\n"
			elif [[ "${_ct_mem_pct}" -ge "${warn_guest_mem}" ]] 2>/dev/null; then
				[[ "${_ct_state}" == "${status_ok}" ]] && { _ct_state="${status_warn}"; (( _ct_any_warn++ )); }
				pve_problem_output+="${status_warn} - CT ${_ctid}/${_ctname} (${_ctnode}): Mem ${_ct_mem_pct}% >= ${warn_guest_mem}%\n"
			fi
		fi

		if [[ -n "${verbose}" ]]; then
			_ct_detail=""
			[[ "${_ctstatus}" == "running" && "${_ctcpumax}" -gt 0 ]] && \
				_ct_detail=" | CPU: ${_ct_cpu_pct}% | Mem: ${_ct_mem_pct}%"
			[[ "${_ctuptime}" =~ ^[0-9]+$ && "${_ctuptime}" -gt 0 ]] && {
				_cud=$(( _ctuptime / 86400 )); _cuh=$(( (_ctuptime % 86400) / 3600 ))
				_ct_detail+=" | Up: ${_cud}d ${_cuh}h"
			}
			pve_output+="${_ct_state} -   CT ${_ctid} ${_ctname} (${_ctnode}): ${_ctstatus}${_ct_detail}\n"
			_repl_line=$(_fmt_repl_summary "${_ctid}" "CT ${_ctid}")
			[[ -n "${_repl_line}" ]] && pve_output+="${_repl_line}\n"
		fi

		_ct_lbl="${_ctid}_${_ctname//[^a-zA-Z0-9]/_}"
		[[ "${_ctstatus}" == "running" ]] && {
			pve_perf+=" ct_${_ct_lbl}_cpu=${_ct_cpu_pct};${warn_cpu};${crit_cpu};0;100"
			pve_perf+=" ct_${_ct_lbl}_mem=${_ct_mem_pct}%;${warn_mem};${crit_mem};0;100"
		}

	done < <(echo "${_res_buf}" | "${JQ}" --unbuffered -r '
		.data[]? | select(.type=="lxc") | [
			((.vmid // 0) | tostring),
			(.name // ""),
			(.status // ""),
			(.node // ""),
			((.cpu // 0) | tostring),
			((.maxcpu // 1) | tostring),
			((.mem // 0) | tostring),
			((.maxmem // 0) | tostring),
			((.disk // 0) | tostring),
			((.maxdisk // 0) | tostring),
			((.uptime // 0) | tostring)
		] | join("\t")' 2>/dev/null)

	# Detailed metrics for single selected CT (--ct)
	if [[ -n "${ct_filter}" && -n "${_ct_sel_id}" ]]; then
		_ct_lbl="${_ct_sel_id}_${ct_filter//[^a-zA-Z0-9]/_}"
		# rrddata: last non-null sample — cpu (0-1), mem, maxmem, disk, maxdisk, swap, maxswap, rates
		_cr_buf=$(pve_api_get "${PVE_API}/nodes/${_ct_sel_node}/lxc/${_ct_sel_id}/rrddata?timeframe=hour&cf=AVERAGE" 2>/dev/null)
		_cr_vals=$(echo "${_cr_buf}" | "${JQ}" -r \
			'.data | map(select(.cpu != null)) | last |
			[(.cpu // 0), (.mem // 0), (.maxmem // 0), (.disk // 0), (.maxdisk // 0),
			 (.swap // 0), (.maxswap // 0),
			 (.netin // 0), (.netout // 0), (.diskread // 0), (.diskwrite // 0)] | join("\t")' 2>/dev/null)
		if [[ -n "${_cr_vals}" ]]; then
			IFS=$'\t' read -r _cd_cpu _cd_mem _cd_maxmem _cd_disk _cd_maxdisk \
				_cd_swap _cd_maxswap \
				_cd_netin_r _cd_netout_r _cd_diskrd_r _cd_diskwr_r <<< "${_cr_vals}"
		else
			_cd_cpu=0; _cd_mem=0; _cd_maxmem=0; _cd_disk=0; _cd_maxdisk=0
			_cd_swap=0; _cd_maxswap=0
			_cd_netin_r=0; _cd_netout_r=0; _cd_diskrd_r=0; _cd_diskwr_r=0
		fi
		# Cumulative totals from status/current
		_cd_buf=$(pve_api_get "${PVE_API}/nodes/${_ct_sel_node}/lxc/${_ct_sel_id}/status/current" 2>/dev/null)
		_cd_netin=$(echo "${_cd_buf}"  | "${JQ}" -r '.data.netin    // 0' 2>/dev/null)
		_cd_netout=$(echo "${_cd_buf}" | "${JQ}" -r '.data.netout   // 0' 2>/dev/null)
		_cd_diskrd=$(echo "${_cd_buf}" | "${JQ}" -r '.data.diskread  // 0' 2>/dev/null)
		_cd_diskwr=$(echo "${_cd_buf}" | "${JQ}" -r '.data.diskwrite // 0' 2>/dev/null)
		# Compute derived integer values
		_cd_cpu_pct=$(echo "${_cd_cpu}"     | "${AWK}" '{printf "%.1f", $1*100}')
		_cd_cpu_pct_i=$(echo "${_cd_cpu_pct}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_mem_i=$(echo "${_cd_mem}"       | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_maxmem_i=$(echo "${_cd_maxmem}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_disk_i=$(echo "${_cd_disk}"     | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_maxdisk_i=$(echo "${_cd_maxdisk}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_swap_i=$(echo "${_cd_swap}"     | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_maxswap_i=$(echo "${_cd_maxswap}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_mem_pct=$(echo  "${_cd_mem} ${_cd_maxmem}"   | "${AWK}" '{if($2>0) printf "%.1f", $1*100/$2; else print "0"}')
		_cd_disk_pct=$(echo "${_cd_disk} ${_cd_maxdisk}" | "${AWK}" '{if($2>0) printf "%.1f", $1*100/$2; else print "0"}')
		_cd_swap_pct=$(echo "${_cd_swap} ${_cd_maxswap}" | "${AWK}" '{if($2>0) printf "%.1f", $1*100/$2; else print "0"}')
		_cd_mem_pct_i=$(echo  "${_cd_mem_pct}"  | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_disk_pct_i=$(echo "${_cd_disk_pct}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_swap_pct_i=$(echo "${_cd_swap_pct}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_netin_ri=$(echo  "${_cd_netin_r}"  | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_netout_ri=$(echo "${_cd_netout_r}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_diskrd_ri=$(echo "${_cd_diskrd_r}" | "${AWK}" '{printf "%d", $1+0.5}')
		_cd_diskwr_ri=$(echo "${_cd_diskwr_r}" | "${AWK}" '{printf "%d", $1+0.5}')
		# Compute per-metric states (CPU/mem already in loop; compute for verbose display)
		_cds_cpu="${status_ok}"; _cds_mem="${status_ok}"; _cds_disk="${status_ok}"
		_cds_swap="${status_ok}"; _cds_netin="${status_ok}"; _cds_netout="${status_ok}"
		if [[ "${_cd_cpu_pct_i}" -ge "${crit_guest_cpu}" ]] 2>/dev/null;   then _cds_cpu="${status_crit}"
		elif [[ "${_cd_cpu_pct_i}" -ge "${warn_guest_cpu}" ]] 2>/dev/null; then _cds_cpu="${status_warn}"; fi
		if [[ "${_cd_mem_pct_i}" -ge "${crit_guest_mem}" ]] 2>/dev/null;   then _cds_mem="${status_crit}"
		elif [[ "${_cd_mem_pct_i}" -ge "${warn_guest_mem}" ]] 2>/dev/null; then _cds_mem="${status_warn}"; fi
		# Disk/swap/net thresholds not in loop
		if [[ "${_cd_maxdisk_i}" -gt 0 ]]; then
			if [[ "${_cd_disk_pct_i}" -ge "${crit_guest_disk}" ]] 2>/dev/null; then
				_cds_disk="${status_crit}"; (( _ct_any_crit++ ))
				pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): Disk ${_cd_disk_pct}% >= ${crit_guest_disk}%\n"
			elif [[ "${_cd_disk_pct_i}" -ge "${warn_guest_disk}" ]] 2>/dev/null; then
				_cds_disk="${status_warn}"; (( _ct_any_warn++ ))
				pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): Disk ${_cd_disk_pct}% >= ${warn_guest_disk}%\n"
			fi
		fi
		if [[ "${_cd_maxswap_i}" -gt 0 ]]; then
			if [[ "${_cd_swap_pct_i}" -ge "${crit_swap}" ]] 2>/dev/null; then
				_cds_swap="${status_crit}"; (( _ct_any_crit++ ))
				pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): Swap ${_cd_swap_pct}% >= ${crit_swap}%\n"
			elif [[ "${_cd_swap_pct_i}" -ge "${warn_swap}" ]] 2>/dev/null; then
				_cds_swap="${status_warn}"; (( _ct_any_warn++ ))
				pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): Swap ${_cd_swap_pct}% >= ${warn_swap}%\n"
			fi
		fi
		if [[ -n "${crit_net_in}" && "${_cd_netin_ri}" -ge "${crit_net_in}" ]] 2>/dev/null; then
			_cds_netin="${status_crit}"; (( _ct_any_crit++ ))
			pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): net in $(_fmt_bytes "${_cd_netin_ri}")/s >= $(_fmt_bytes "${crit_net_in}")/s\n"
		elif [[ -n "${warn_net_in}" && "${_cd_netin_ri}" -ge "${warn_net_in}" ]] 2>/dev/null; then
			_cds_netin="${status_warn}"; (( _ct_any_warn++ ))
			pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): net in $(_fmt_bytes "${_cd_netin_ri}")/s >= $(_fmt_bytes "${warn_net_in}")/s\n"
		fi
		if [[ -n "${crit_net_out}" && "${_cd_netout_ri}" -ge "${crit_net_out}" ]] 2>/dev/null; then
			_cds_netout="${status_crit}"; (( _ct_any_crit++ ))
			pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): net out $(_fmt_bytes "${_cd_netout_ri}")/s >= $(_fmt_bytes "${crit_net_out}")/s\n"
		elif [[ -n "${warn_net_out}" && "${_cd_netout_ri}" -ge "${warn_net_out}" ]] 2>/dev/null; then
			_cds_netout="${status_warn}"; (( _ct_any_warn++ ))
			pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): net out $(_fmt_bytes "${_cd_netout_ri}")/s >= $(_fmt_bytes "${warn_net_out}")/s\n"
		fi
		if [[ -n "${verbose}" ]]; then
			pve_output+="${_cds_cpu} -   CT ${_ct_sel_id} CPU: ${_cd_cpu_pct}%\n"
			pve_output+="${_cds_mem} -   CT ${_ct_sel_id} Memory: $(_fmt_bytes "${_cd_mem_i}") / $(_fmt_bytes "${_cd_maxmem_i}") (${_cd_mem_pct}%)\n"
			[[ "${_cd_maxswap_i}" -gt 0 ]] && \
				pve_output+="${_cds_swap} -   CT ${_ct_sel_id} Swap: $(_fmt_bytes "${_cd_swap_i}") / $(_fmt_bytes "${_cd_maxswap_i}") (${_cd_swap_pct}%)\n"
			[[ "${_cd_maxdisk_i}" -gt 0 ]] && \
				pve_output+="${_cds_disk} -   CT ${_ct_sel_id} Disk: $(_fmt_bytes "${_cd_disk_i}") / $(_fmt_bytes "${_cd_maxdisk_i}") (${_cd_disk_pct}%)\n"
			pve_output+="${_cds_netin} -   CT ${_ct_sel_id} I/O rates (1-min avg): disk read $(_fmt_bytes "${_cd_diskrd_ri}")/s | disk write $(_fmt_bytes "${_cd_diskwr_ri}")/s | net in $(_fmt_bytes "${_cd_netin_ri}")/s | net out $(_fmt_bytes "${_cd_netout_ri}")/s\n"
			pve_output+="${status_ok} -   CT ${_ct_sel_id} I/O total (since boot): disk read $(_fmt_bytes "${_cd_diskrd}") | disk write $(_fmt_bytes "${_cd_diskwr}") | net in $(_fmt_bytes "${_cd_netin}") | net out $(_fmt_bytes "${_cd_netout}")\n"
		fi
		# Snapshots
		_csnap_buf=$(pve_api_get "${PVE_API}/nodes/${_ct_sel_node}/lxc/${_ct_sel_id}/snapshot" 2>/dev/null)
		_csnap_count=0; _csnap_newest=0
		while IFS='	' read -r _csname _cstime; do
			[[ "${_csname}" == "current" || -z "${_csname}" ]] && continue
			(( _csnap_count++ ))
			[[ "${_cstime}" =~ ^[0-9]+$ && "${_cstime}" -gt "${_csnap_newest}" ]] && _csnap_newest="${_cstime}"
		done < <(echo "${_csnap_buf}" | "${JQ}" -r '.data[]? | [(.name // ""), ((.snaptime // 0) | tostring)] | join("\t")' 2>/dev/null)
		_csnap_state="${status_ok}"; _csage_d=0
		if [[ "${_csnap_count}" -gt 0 ]]; then
			_csage_d=$(( ($(date +%s) - _csnap_newest) / 86400 ))
			if [[ -n "${crit_snap_count}" && "${_csnap_count}" -ge "${crit_snap_count}" ]] 2>/dev/null; then
				_csnap_state="${status_crit}"; (( _ct_any_crit++ ))
				pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): ${_csnap_count} snapshot(s) >= ${crit_snap_count}\n"
			elif [[ -n "${warn_snap_count}" && "${_csnap_count}" -ge "${warn_snap_count}" ]] 2>/dev/null; then
				_csnap_state="${status_warn}"; (( _ct_any_warn++ ))
				pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): ${_csnap_count} snapshot(s) >= ${warn_snap_count}\n"
			fi
			if [[ "${_csage_d}" -ge "${crit_snap_age}" ]] 2>/dev/null; then
				[[ "${_csnap_state}" != "${status_crit}" ]] && { _csnap_state="${status_crit}"; (( _ct_any_crit++ )); }
				pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): newest snapshot ${_csage_d}d old (>= ${crit_snap_age}d)\n"
			elif [[ "${_csage_d}" -ge "${warn_snap_age}" ]] 2>/dev/null; then
				[[ "${_csnap_state}" == "${status_ok}" ]] && { _csnap_state="${status_warn}"; (( _ct_any_warn++ )); }
				pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): newest snapshot ${_csage_d}d old (>= ${warn_snap_age}d)\n"
			fi
		fi
		if [[ -n "${verbose}" ]]; then
			if [[ "${_csnap_count}" -gt 0 ]]; then
				pve_output+="${_csnap_state} -   CT ${_ct_sel_id} Snapshots: ${_csnap_count} snapshot(s), newest: ${_csage_d}d ago\n"
			else
				pve_output+="${status_ok} -   CT ${_ct_sel_id} Snapshots: none\n"
			fi
		fi
		pve_perf+=" ct_${_ct_lbl}_snaps=${_csnap_count}"
		# Replication detail with age threshold
		if [[ "${_vrepl_cnt[${_ct_sel_id}]:-0}" -gt 0 ]]; then
			_crepl_age_min=0; _crepl_age_s="never synced"
			_crepl_state="${status_ok}"
			[[ "${_vrepl_ok[${_ct_sel_id}]:-ok}" == "warn" ]] && _crepl_state="${status_warn}"
			[[ "${_vrepl_ok[${_ct_sel_id}]:-ok}" == "crit" ]] && _crepl_state="${status_crit}"
			if [[ "${_vrepl_last[${_ct_sel_id}]:-0}" -gt 0 ]]; then
				_crepl_age_min=$(( (_repl_now - _vrepl_last[${_ct_sel_id}]) / 60 ))
				if [[ "${_crepl_age_min}" -ge 60 ]]; then
					_crepl_age_s="$(( _crepl_age_min / 60 ))h $(( _crepl_age_min % 60 ))m ago"
				else
					_crepl_age_s="${_crepl_age_min}m ago"
				fi
				if [[ "${_crepl_age_min}" -ge "${crit_repl_age}" ]] 2>/dev/null; then
					[[ "${_crepl_state}" != "${status_crit}" ]] && { _crepl_state="${status_crit}"; (( _ct_any_crit++ )); }
					pve_problem_output+="${status_crit} - CT ${_ct_sel_id} (${_ct_sel_node}): last replication ${_crepl_age_s} (>= ${crit_repl_age}m)\n"
				elif [[ "${_crepl_age_min}" -ge "${warn_repl_age}" ]] 2>/dev/null; then
					[[ "${_crepl_state}" == "${status_ok}" ]] && { _crepl_state="${status_warn}"; (( _ct_any_warn++ )); }
					pve_problem_output+="${status_warn} - CT ${_ct_sel_id} (${_ct_sel_node}): last replication ${_crepl_age_s} (>= ${warn_repl_age}m)\n"
				fi
			fi
			[[ -n "${verbose}" ]] && pve_output+="${_crepl_state} -   CT ${_ct_sel_id} Replication: ${_vrepl_cnt[${_ct_sel_id}]} job(s), last sync: ${_crepl_age_s}\n"
			pve_perf+=" ct_${_ct_lbl}_repl_age=${_crepl_age_min};${warn_repl_age};${crit_repl_age};0"
		elif [[ -n "${verbose}" ]]; then
			pve_output+="${status_ok} -   CT ${_ct_sel_id} Replication: none\n"
		fi
		pve_perf+=" ct_${_ct_lbl}_cpu=${_cd_cpu_pct}%;${warn_guest_cpu};${crit_guest_cpu};0;100"
		pve_perf+=" ct_${_ct_lbl}_mem=${_cd_mem_i} ct_${_ct_lbl}_mem_pct=${_cd_mem_pct}%;${warn_guest_mem};${crit_guest_mem};0;100"
		[[ "${_cd_maxdisk_i}" -gt 0 ]] && \
			pve_perf+=" ct_${_ct_lbl}_disk=${_cd_disk_i} ct_${_ct_lbl}_disk_pct=${_cd_disk_pct}%;${warn_guest_disk};${crit_guest_disk};0;100"
		[[ "${_cd_maxswap_i}" -gt 0 ]] && \
			pve_perf+=" ct_${_ct_lbl}_swap=${_cd_swap_i} ct_${_ct_lbl}_swap_pct=${_cd_swap_pct}%;${warn_swap};${crit_swap};0;100"
		pve_perf+=" ct_${_ct_lbl}_netin_rate=${_cd_netin_ri} ct_${_ct_lbl}_netout_rate=${_cd_netout_ri}"
		pve_perf+=" ct_${_ct_lbl}_diskread_rate=${_cd_diskrd_ri} ct_${_ct_lbl}_diskwrite_rate=${_cd_diskwr_ri}"
		pve_perf+=" ct_${_ct_lbl}_netin=${_cd_netin} ct_${_ct_lbl}_netout=${_cd_netout}"
		pve_perf+=" ct_${_ct_lbl}_diskread=${_cd_diskrd} ct_${_ct_lbl}_diskwrite=${_cd_diskwr}"
	elif [[ -n "${ct_filter}" && -z "${_ct_sel_id}" ]]; then
		pve_output+="${status_unknown} - CT '${ct_filter}' not found\n"
		pve_problem_output+="${status_unknown} - CT '${ct_filter}' not found\n"
	fi

	if [[ "${_ct_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Containers: ${_ct_total} total | ${_ct_running} running, ${_ct_stopped} stopped, ${_ct_paused} paused | ${_ct_any_crit} critical\n"
	elif [[ "${_ct_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Containers: ${_ct_total} total | ${_ct_running} running, ${_ct_stopped} stopped, ${_ct_paused} paused | ${_ct_any_warn} warning\n"
	else
		pve_output+="${status_ok} - Containers: ${_ct_total} total | ${_ct_running} running, ${_ct_stopped} stopped\n"
	fi

	pve_perf+=" ct_total=${_ct_total} ct_running=${_ct_running} ct_stopped=${_ct_stopped}"
	[[ "${_ct_paused}" -gt 0 ]] && pve_perf+=" ct_paused=${_ct_paused}"

	unset _ct_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Storage Usage Check (-eStorage)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_storage}" || -n "${enable_all}" ) && -z "${disable_storage}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="Storage:\n---------------------------------------\n"
	fi

	declare -A _st_bl_map=()
	if [[ -n "${storage_blacklist}" ]]; then
		IFS=',' read -ra _st_bl_arr <<< "${storage_blacklist}"
		for _e in "${_st_bl_arr[@]}"; do _st_bl_map["${_e// /}"]=1; done
	fi

	# Parse threshold mode: N% = percentage used; plain N = free bytes remaining
	_st_warn_pct="" ; _st_warn_abs=""
	_st_crit_pct="" ; _st_crit_abs=""
	if [[ "${warn_storage}" == *% ]]; then
		_st_warn_pct="${warn_storage%\%}"
	else
		_st_warn_abs="${warn_storage}"
	fi
	if [[ "${crit_storage}" == *% ]]; then
		_st_crit_pct="${crit_storage%\%}"
	else
		_st_crit_abs="${crit_storage}"
	fi
	_st_thr_warn="${warn_storage}"; _st_thr_crit="${crit_storage}"
	[[ -n "${_st_warn_abs}" ]] && _st_thr_warn="${_st_warn_abs} free"
	[[ -n "${_st_crit_abs}" ]] && _st_thr_crit="${_st_crit_abs} free"

	_st_total_pools=0; _st_any_crit=0; _st_any_warn=0

	while IFS=$'\t' read -r _stname _stnode _ststatus _stused _stavail _sttotal _sttype; do
		[[ -z "${_stname}" ]] && continue
		[[ -n "${_st_bl_map[${_stname}]:-}" ]] && continue
		[[ -n "${pve_node}" && "${_stnode}" != "${pve_node}" ]] && continue
		[[ -n "${storage_node}" && "${_stnode}" != "${storage_node}" ]] && continue
		[[ "${_ststatus}" != "available" ]] && continue
		[[ "${_sttotal}" -le 0 ]] 2>/dev/null && continue

		(( _st_total_pools++ ))
		_stfree=$(( _sttotal - _stused ))
		_st_pct=$(( _stused * 100 / _sttotal ))

		_st_state="${status_ok}"
		if { [[ -n "${_st_crit_pct}" && "${_st_pct}" -ge "${_st_crit_pct}" ]] || \
		     [[ -n "${_st_crit_abs}" && "${_stfree}" -lt "${_st_crit_abs}" ]]; }; then
			_st_state="${status_crit}"; (( _st_any_crit++ ))
			pve_problem_output+="${status_crit} - Storage ${_stname} (${_stnode}): ${_st_pct}% used ($(_fmt_bytes "${_stfree}") free) (crit: ${_st_thr_crit})\n"
		elif { [[ -n "${_st_warn_pct}" && "${_st_pct}" -ge "${_st_warn_pct}" ]] || \
		       [[ -n "${_st_warn_abs}" && "${_stfree}" -lt "${_st_warn_abs}" ]]; }; then
			_st_state="${status_warn}"; (( _st_any_warn++ ))
			pve_problem_output+="${status_warn} - Storage ${_stname} (${_stnode}): ${_st_pct}% used ($(_fmt_bytes "${_stfree}") free) (warn: ${_st_thr_warn})\n"
		fi

		if [[ -n "${verbose}" ]]; then
			_free_s=""; [[ -n "${_st_warn_abs}" || -n "${_st_crit_abs}" ]] && \
				_free_s=", $(_fmt_bytes "${_stfree}") free"
			pve_output+="${_st_state} - Storage ${_stname} (${_stnode}, ${_sttype}): ${_st_pct}% used ($(_fmt_bytes "${_stused}")/$(_fmt_bytes "${_sttotal}")${_free_s}) (warn: ${_st_thr_warn}, crit: ${_st_thr_crit})\n"
		fi

		_st_lbl="${_stnode//-/_}_${_stname//[^a-zA-Z0-9]/_}"
		if [[ -n "${_st_warn_abs}" || -n "${_st_crit_abs}" ]]; then
			pve_perf+=" storage_${_st_lbl}_free=${_stfree};${_st_warn_abs:-}:;${_st_crit_abs:-}:;0;${_sttotal}"
			pve_perf+=" storage_${_st_lbl}_pct=${_st_pct}%"
		else
			pve_perf+=" storage_${_st_lbl}_pct=${_st_pct}%;${_st_warn_pct:-};${_st_crit_pct:-};0;100"
			pve_perf+=" storage_${_st_lbl}_used=${_stused}"
		fi

	done < <(echo "${_res_buf}" | "${JQ}" --unbuffered -r '
		.data[]? | select(.type=="storage") | [
			(.storage // ""),
			(.node // ""),
			(.status // ""),
			((.disk    // 0) | tostring),
			((.maxdisk // 0) | tostring),
			((.maxdisk // 0) | tostring),
			(.plugintype // "")
		] | join("\t")' 2>/dev/null)

	if [[ "${_st_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Storage: ${_st_total_pools} pool(s) | ${_st_any_crit} critical\n"
	elif [[ "${_st_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Storage: ${_st_total_pools} pool(s) | ${_st_any_warn} warning\n"
	else
		pve_output+="${status_ok} - Storage: ${_st_total_pools} pool(s), all within thresholds\n"
	fi

	unset _st_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Subscription Check (-eSub)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_sub}" || -n "${enable_all}" ) && -z "${disable_sub}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="Subscription:\n---------------------------------------\n"
	fi

	_sub_any_crit=0; _sub_any_warn=0
	_today_epoch=$(date +%s)

	for _subnode in "${_all_nodes[@]}"; do
		_sub_buf=$(pve_api_get "${PVE_API}/nodes/${_subnode}/subscription" 2>/dev/null)
		[[ -z "${_sub_buf}" ]] && continue

		_sub_status=$(echo "${_sub_buf}"  | "${JQ}" -r '.data.status // "NotFound"' 2>/dev/null)
		_sub_level=$(echo "${_sub_buf}"   | "${JQ}" -r '.data.level  // ""'         2>/dev/null)
		_sub_product=$(echo "${_sub_buf}" | "${JQ}" -r '.data.productname // ""'    2>/dev/null)
		_sub_key=$(echo "${_sub_buf}"     | "${JQ}" -r '.data.key // ""'            2>/dev/null)
		_sub_due=$(echo "${_sub_buf}"     | "${JQ}" -r '.data.nextduedate // ""'    2>/dev/null)

		_sub_state="${status_ok}"
		_sub_detail=""
		_sub_days_left=""

		case "${_sub_status}" in
			Active)
				if [[ -n "${_sub_due}" && "${_sub_due}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
					_due_epoch=$(date -d "${_sub_due}" +%s 2>/dev/null)
					if [[ -n "${_due_epoch}" ]]; then
						_sub_days_left=$(( (_due_epoch - _today_epoch) / 86400 ))
						if [[ "${_sub_days_left}" -le "${crit_sub_days}" ]]; then
							_sub_state="${status_crit}"; (( _sub_any_crit++ ))
							_sub_detail=" (expires in ${_sub_days_left} days)"
						elif [[ "${_sub_days_left}" -le "${warn_sub_days}" ]]; then
							_sub_state="${status_warn}"; (( _sub_any_warn++ ))
							_sub_detail=" (expires in ${_sub_days_left} days)"
						else
							_sub_detail=" (expires in ${_sub_days_left} days)"
						fi
					fi
				fi
				;;
			NotFound|notfound|None|none)
				if [[ -z "${ignore_no_sub}" ]]; then
					_sub_state="${status_warn}"; (( _sub_any_warn++ ))
					_sub_detail=" (no subscription)"
				else
					_sub_detail=" (no subscription)"
				fi
				;;
			Expired|expired)
				_sub_state="${status_crit}"; (( _sub_any_crit++ ))
				_sub_detail=" (EXPIRED)"
				;;
			Invalid|invalid|*)
				_sub_state="${status_crit}"; (( _sub_any_crit++ ))
				_sub_detail=" (${_sub_status})"
				;;
		esac

		[[ "${_sub_state}" != "${status_ok}" ]] && \
			pve_problem_output+="${_sub_state} - Subscription ${_subnode}: ${_sub_status}${_sub_detail}\n"

		if [[ -n "${verbose}" ]]; then
			_sub_prod_s=""
			[[ -n "${_sub_product}" ]] && _sub_prod_s=" (${_sub_product})"
			[[ -n "${_sub_key}" ]]     && _sub_prod_s+=" [${_sub_key}]"
			[[ -n "${_sub_due}" ]]     && _sub_prod_s+=", due: ${_sub_due}"
			pve_output+="${_sub_state} - Subscription ${_subnode}: ${_sub_status}${_sub_detail}${_sub_prod_s}\n"
		fi

		_sub_lbl="${_subnode//-/_}"
		[[ "${_sub_days_left}" =~ ^-?[0-9]+$ ]] && \
			pve_perf+=" sub_${_sub_lbl}_days_left=${_sub_days_left};${warn_sub_days};${crit_sub_days};0"

	done

	if [[ "${_sub_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Subscription: ${_sub_any_crit} node(s) critical\n"
	elif [[ "${_sub_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Subscription: ${_sub_any_warn} node(s) warning\n"
	else
		pve_output+="${status_ok} - Subscription: all nodes OK\n"
	fi

	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Replication Job Check (-eRepl)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_repl}" || -n "${enable_all}" ) && -z "${disable_repl}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pve_output+="Replication:\n---------------------------------------\n"
	fi

	declare -A _repl_bl_map=()
	if [[ -n "${repl_blacklist}" ]]; then
		IFS=',' read -ra _repl_bl_arr <<< "${repl_blacklist}"
		for _e in "${_repl_bl_arr[@]}"; do _repl_bl_map["${_e// /}"]=1; done
	fi

	_repl_total=0; _repl_any_crit=0; _repl_any_warn=0
	_now_epoch=$(date +%s)

	if [[ -z "${_repl_buf}" || ! "${_repl_buf}" =~ '"data"' ]]; then
		pve_output+="${status_ok} - Replication: no replication jobs configured\n"
	else
		_repl_count=$("${JQ}" -r '.data | length' <<< "${_repl_buf}" 2>/dev/null)
		if [[ "${_repl_count}" -eq 0 ]]; then
			pve_output+="${status_ok} - Replication: no replication jobs configured\n"
		else
			while IFS=$'\t' read -r _rid _rvmid _rtarget _rsource _rdisable \
			                          _rlast_sync _rduration _rerror _rfail_count; do
				[[ -z "${_rid}" ]] && continue
				[[ -n "${_repl_bl_map[${_rid}]:-}" ]] && continue
				[[ "${_rdisable}" == "1" ]] && continue

				(( _repl_total++ ))
				_repl_state="${status_ok}"
				_repl_detail=""

				# Check for errors
				if [[ -n "${_rerror}" && "${_rerror}" != "null" && "${_rerror}" != "" ]]; then
					_repl_state="${status_crit}"; (( _repl_any_crit++ ))
					_repl_detail=" (error: ${_rerror})"
				elif [[ "${_rfail_count}" =~ ^[0-9]+$ && "${_rfail_count}" -gt 0 ]]; then
					_repl_state="${status_warn}"; (( _repl_any_warn++ ))
					_repl_detail=" (${_rfail_count} failures)"
				fi

				# Check sync age
				_repl_age_s=""
				if [[ "${_rlast_sync}" =~ ^[0-9]+$ && "${_rlast_sync}" -gt 0 ]]; then
					_age_sec=$(( _now_epoch - _rlast_sync ))
					_age_min=$(( _age_sec / 60 ))
					_age_h=$(( _age_min / 60 )); _age_m=$(( _age_min % 60 ))
					_repl_age_s=", last sync: ${_age_h}h ${_age_m}m ago"
					if [[ "${_age_min}" -ge "${crit_repl_age}" ]]; then
						_repl_state="${status_crit}"; (( _repl_any_crit++ ))
						_repl_detail+=" (sync ${_age_min}m ago, crit: ${crit_repl_age}m)"
					elif [[ "${_age_min}" -ge "${warn_repl_age}" ]]; then
						[[ "${_repl_state}" == "${status_ok}" ]] && \
							{ _repl_state="${status_warn}"; (( _repl_any_warn++ )); }
						_repl_detail+=" (sync ${_age_min}m ago, warn: ${warn_repl_age}m)"
					fi
					_dur_s=""
					[[ "${_rduration}" =~ ^[0-9]+$ && "${_rduration}" -gt 0 ]] && \
						_dur_s=", duration: ${_rduration}s"
					_repl_age_s+=", duration: ${_rduration}s"
				else
					_repl_age_s=", never synced"
					_repl_state="${status_warn}"; (( _repl_any_warn++ ))
					_repl_detail+=" (never synced)"
				fi

				[[ "${_repl_state}" != "${status_ok}" ]] && \
					pve_problem_output+="${_repl_state} - Replication ${_rid} (VM ${_rvmid}, ${_rsource}→${_rtarget})${_repl_detail}\n"

				[[ -n "${verbose}" ]] && \
					pve_output+="${_repl_state} -   Repl ${_rid} VM ${_rvmid} (${_rsource}→${_rtarget})${_repl_age_s}${_repl_detail}\n"

				_repl_lbl="${_rid//-/_}"
				[[ "${_rlast_sync}" =~ ^[0-9]+$ && "${_rlast_sync}" -gt 0 ]] && \
					pve_perf+=" repl_${_repl_lbl}_age_min=$(( _age_sec / 60 ));${warn_repl_age};${crit_repl_age};0"
				[[ "${_rfail_count}" =~ ^[0-9]+$ ]] && \
					pve_perf+=" repl_${_repl_lbl}_fails=${_rfail_count}"

			done < <("${JQ}" --unbuffered -r '
				.data[]? | [
					(.id // ""),
					((.vmid // 0) | tostring),
					(.target // ""),
					(.source // ""),
					((.disable // 0) | tostring),
					((.last_sync // 0) | tostring),
					((.duration // 0) | tostring),
					(.error // ""),
					((.fail_count // 0) | tostring)
				] | join("\t")' <<< "${_repl_buf}" 2>/dev/null)

			if [[ "${_repl_any_crit}" -gt 0 ]]; then
				pve_output+="${status_crit} - Replication: ${_repl_total} job(s) | ${_repl_any_crit} critical\n"
			elif [[ "${_repl_any_warn}" -gt 0 ]]; then
				pve_output+="${status_warn} - Replication: ${_repl_total} job(s) | ${_repl_any_warn} warning\n"
			else
				pve_output+="${status_ok} - Replication: ${_repl_total} job(s), all OK\n"
			fi

			pve_perf+=" repl_total=${_repl_total}"
		fi
	fi

	unset _repl_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# System Time Check (-eTime)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_time}" || -n "${enable_all}" ) && -z "${disable_time}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="System Time:\n---------------------------------------\n"

	_time_any_crit=0; _time_any_warn=0
	_now_host=$(date +%s)

	for _tnode in "${_all_nodes[@]}"; do
		_tbuf=$(cat "${_pf}/node_time_${_tnode}.json" 2>/dev/null)
		[[ -z "${_tbuf}" ]] && continue

		_ttime=$(echo "${_tbuf}"    | "${JQ}" -r '.data.time // 0'     2>/dev/null)
		_ttz=$(echo "${_tbuf}"      | "${JQ}" -r '.data.timezone // ""' 2>/dev/null)

		_tstate="${status_ok}"; _tdetail=""

		# Time drift
		if [[ "${_ttime}" =~ ^[0-9]+$ && "${_ttime}" -gt 0 ]]; then
			_drift=$(( _ttime - _now_host ))
			[[ "${_drift}" -lt 0 ]] && _drift=$(( -_drift ))
			if [[ "${_drift}" -ge "${crit_time_drift}" ]]; then
				_tstate="${status_crit}"; (( _time_any_crit++ ))
				_tdetail+=" drift:${_drift}s"
			elif [[ "${_drift}" -ge "${warn_time_drift}" ]]; then
				[[ "${_tstate}" == "${status_ok}" ]] && _tstate="${status_warn}"
				(( _time_any_warn++ ))
				_tdetail+=" drift:${_drift}s"
			fi
			pve_perf+=" time_${_tnode//-/_}_drift=${_drift};${warn_time_drift};${crit_time_drift};0"
		fi

		# Timezone match
		if [[ -n "${expected_tz}" && -n "${_ttz}" && "${_ttz}" != "${expected_tz}" ]]; then
			[[ "${_tstate}" == "${status_ok}" ]] && _tstate="${status_warn}"
			(( _time_any_warn++ ))
			_tdetail+=" TZ:${_ttz}!=${expected_tz}"
		fi

		[[ "${_tstate}" != "${status_ok}" ]] && \
			pve_problem_output+="${_tstate} - Time ${_tnode}:${_tdetail}\n"
		if [[ -n "${verbose}" ]]; then
			_ttime_s=""
			[[ "${_ttime}" =~ ^[0-9]+$ && "${_ttime}" -gt 0 ]] && \
				_ttime_s=" | $(date -d "@${_ttime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${_ttime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
			_tdrift_s=""
			[[ "${_drift:-0}" -gt 0 ]] && _tdrift_s=" | drift: ${_drift}s"
			pve_output+="${_tstate} - Node ${_tnode}: TZ: ${_ttz:-unknown}${_ttime_s}${_tdrift_s}${_tdetail:+ | ALERT:${_tdetail}}\n"
		fi
	done

	if [[ "${_time_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Time: ${_time_any_crit} node(s) critical\n"
	elif [[ "${_time_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Time: ${_time_any_warn} node(s) warning\n"
	else
		pve_output+="${status_ok} - Time: all nodes OK\n"
	fi
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# DNS Check (-eDNS)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_dns}" || -n "${enable_all}" ) && -z "${disable_dns}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="DNS Configuration:\n---------------------------------------\n"

	_dns_any_warn=0; _dns_any_crit=0

	for _dnode in "${_all_nodes[@]}"; do
		_dbuf=$(cat "${_pf}/node_dns_${_dnode}.json" 2>/dev/null)
		[[ -z "${_dbuf}" ]] && continue

		_ddns1=$(echo "${_dbuf}"   | "${JQ}" -r '.data.dns1   // ""' 2>/dev/null)
		_ddns2=$(echo "${_dbuf}"   | "${JQ}" -r '.data.dns2   // ""' 2>/dev/null)
		_ddns3=$(echo "${_dbuf}"   | "${JQ}" -r '.data.dns3   // ""' 2>/dev/null)
		_dsearch=$(echo "${_dbuf}" | "${JQ}" -r '.data.search // ""' 2>/dev/null)

		_dstate="${status_ok}"; _ddetail=""
		[[ -z "${_ddns1}" ]] && {
			_dstate="${status_warn}"; (( _dns_any_warn++ ))
			_ddetail=" (no DNS server configured)"
		}

		_dservers="${_ddns1:-none}"
		[[ -n "${_ddns2}" ]] && _dservers+=", ${_ddns2}"
		[[ -n "${_ddns3}" ]] && _dservers+=", ${_ddns3}"

		[[ "${_dstate}" != "${status_ok}" ]] && \
			pve_problem_output+="${_dstate} - DNS ${_dnode}:${_ddetail}\n"
		[[ -n "${verbose}" ]] && \
			pve_output+="${_dstate} - Node ${_dnode}: DNS: ${_dservers}${_dsearch:+, search: ${_dsearch}}${_ddetail}\n"
	done

	if [[ "${_dns_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - DNS: ${_dns_any_crit} node(s) critical\n"
	elif [[ "${_dns_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - DNS: ${_dns_any_warn} node(s) warning\n"
	else
		pve_output+="${status_ok} - DNS: all nodes configured\n"
	fi
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Network Interface Check (-eNet)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_net}" || -n "${enable_all}" ) && -z "${disable_net}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="Network Interfaces:\n---------------------------------------\n"

	declare -A _net_bl_map=()
	if [[ -n "${net_blacklist}" ]]; then
		IFS=',' read -ra _net_bl_arr <<< "${net_blacklist}"
		for _e in "${_net_bl_arr[@]}"; do _net_bl_map["${_e// /}"]=1; done
	fi

	_net_any_warn=0; _net_any_crit=0

	for _nnode in "${_all_nodes[@]}"; do
		_nbuf=$(cat "${_pf}/node_net_${_nnode}.json" 2>/dev/null)
		[[ -z "${_nbuf}" ]] && continue
		_nperf_lbl="${_nnode//-/_}"

		while IFS=$'\t' read -r _niface _ntype _nactive _naddr _nmac; do
			[[ -z "${_niface}" ]] && continue
			[[ -n "${_net_bl_map[${_niface}]:-}" ]] && continue
			# Skip loopback and bridge members
			[[ "${_niface}" == "lo" ]] && continue

			_nstate="${status_ok}"
			if [[ "${_nactive}" == "0" || "${_nactive}" == "false" ]]; then
				_nstate="${status_warn}"; (( _net_any_warn++ ))
				pve_problem_output+="${status_warn} - Net ${_nnode}/${_niface}: link down\n"
			fi

			[[ -n "${verbose}" ]] && {
				_ndet="${_ntype}"
				[[ -n "${_naddr}" ]] && _ndet+=", ${_naddr}"
				pve_output+="${_nstate} -   ${_nnode}/${_niface}: ${_ndet} $([ "${_nactive}" == "1" ] && echo "UP" || echo "DOWN")\n"
			}
		done < <(echo "${_nbuf}" | "${JQ}" --unbuffered -r '
			.data[]? | select(.type != null) | [
				(.iface // ""),
				(.type // ""),
				((.active // 0) | tostring),
				(.address // ""),
				(.hwaddr // "")
			] | join("\t")' 2>/dev/null)

		# netin/netout cumulative totals from cluster/resources
		_nnetin=$(echo "${_res_buf}"  | "${JQ}" -r \
			".data[]? | select(.type==\"node\" and .node==\"${_nnode}\") | .netin  // 0" 2>/dev/null)
		_nnetout=$(echo "${_res_buf}" | "${JQ}" -r \
			".data[]? | select(.type==\"node\" and .node==\"${_nnode}\") | .netout // 0" 2>/dev/null)
		[[ "${_nnetin}"  =~ ^[0-9]+$ ]] && pve_perf+=" net_${_nperf_lbl}_in=${_nnetin}"
		[[ "${_nnetout}" =~ ^[0-9]+$ ]] && pve_perf+=" net_${_nperf_lbl}_out=${_nnetout}"
		if [[ -n "${verbose}" && "${_nnetin}" =~ ^[0-9]+$ ]]; then
			pve_output+="${status_ok} -   ${_nnode} traffic: in $(_fmt_bytes "${_nnetin}") | out $(_fmt_bytes "${_nnetout}") (cumulative)\n"
		fi

		# Net rate thresholds from rrddata (only if any net rate threshold is set)
		if [[ -n "${warn_net_in}" || -n "${crit_net_in}" || -n "${warn_net_out}" || -n "${crit_net_out}" ]]; then
			_nrrd_buf=$(cat "${_pf}/node_rrd_${_nnode}.json" 2>/dev/null)
			if [[ -n "${_nrrd_buf}" ]]; then
				_nrrd_vals=$(echo "${_nrrd_buf}" | "${JQ}" -r \
					'.data | map(select(.netin != null)) | last | [(.netin // 0), (.netout // 0)] | join("\t")' 2>/dev/null)
				if [[ -n "${_nrrd_vals}" ]]; then
					IFS=$'\t' read -r _nrrd_in _nrrd_out <<< "${_nrrd_vals}"
					_nrrd_in_i=$(echo  "${_nrrd_in}"  | "${AWK}" '{printf "%d", $1+0.5}')
					_nrrd_out_i=$(echo "${_nrrd_out}" | "${AWK}" '{printf "%d", $1+0.5}')
					_nrrd_state="${status_ok}"
					if [[ -n "${crit_net_in}" && "${_nrrd_in_i}" -ge "${crit_net_in}" ]] 2>/dev/null; then
						_nrrd_state="${status_crit}"; (( _net_any_crit++ ))
						pve_problem_output+="${status_crit} - Net ${_nnode}: ingress $(_fmt_bytes "${_nrrd_in_i}")/s >= $(_fmt_bytes "${crit_net_in}")/s\n"
					elif [[ -n "${warn_net_in}" && "${_nrrd_in_i}" -ge "${warn_net_in}" ]] 2>/dev/null; then
						_nrrd_state="${status_warn}"; (( _net_any_warn++ ))
						pve_problem_output+="${status_warn} - Net ${_nnode}: ingress $(_fmt_bytes "${_nrrd_in_i}")/s >= $(_fmt_bytes "${warn_net_in}")/s\n"
					fi
					if [[ -n "${crit_net_out}" && "${_nrrd_out_i}" -ge "${crit_net_out}" ]] 2>/dev/null; then
						_nrrd_state="${status_crit}"; (( _net_any_crit++ ))
						pve_problem_output+="${status_crit} - Net ${_nnode}: egress $(_fmt_bytes "${_nrrd_out_i}")/s >= $(_fmt_bytes "${crit_net_out}")/s\n"
					elif [[ -n "${warn_net_out}" && "${_nrrd_out_i}" -ge "${warn_net_out}" ]] 2>/dev/null; then
						[[ "${_nrrd_state}" == "${status_ok}" ]] && _nrrd_state="${status_warn}"; (( _net_any_warn++ ))
						pve_problem_output+="${status_warn} - Net ${_nnode}: egress $(_fmt_bytes "${_nrrd_out_i}")/s >= $(_fmt_bytes "${warn_net_out}")/s\n"
					fi
					pve_perf+=" net_${_nperf_lbl}_in_rate=${_nrrd_in_i} net_${_nperf_lbl}_out_rate=${_nrrd_out_i}"
					[[ -n "${verbose}" ]] && \
						pve_output+="${_nrrd_state} -   ${_nnode} net rates (1-min avg): in $(_fmt_bytes "${_nrrd_in_i}")/s | out $(_fmt_bytes "${_nrrd_out_i}")/s\n"
				fi
			fi
		fi
	done

	if [[ "${_net_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Network: ${_net_any_crit} interface(s) critical\n"
	elif [[ "${_net_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Network: ${_net_any_warn} interface(s) down\n"
	else
		pve_output+="${status_ok} - Network: all interfaces up\n"
	fi
	unset _net_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Disk Health Check (-eDisk)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_disk}" || -n "${enable_all}" ) && -z "${disable_disk}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="Disk Health:\n---------------------------------------\n"

	declare -A _disk_bl_map=()
	if [[ -n "${disk_blacklist}" ]]; then
		IFS=',' read -ra _disk_bl_arr <<< "${disk_blacklist}"
		for _e in "${_disk_bl_arr[@]}"; do _disk_bl_map["${_e// /}"]=1; done
	fi

	_disk_any_warn=0; _disk_any_crit=0; _disk_total=0

	for _dknode in "${_all_nodes[@]}"; do
		_dkbuf=$(cat "${_pf}/node_disks_${_dknode}.json" 2>/dev/null)
		[[ -z "${_dkbuf}" ]] && continue

		while IFS=$'\t' read -r _dkdev _dkmodel _dktype _dkhealth _dkwear _dksize; do
			[[ -z "${_dkdev}" ]] && continue
			[[ -n "${_disk_bl_map[${_dkdev##*/}]:-}" || -n "${_disk_bl_map[${_dkmodel}]:-}" ]] && continue
			(( _disk_total++ ))

			_dkstate="${status_ok}"; _dkdetail=""

			if [[ "${_dkhealth}" == "FAILED" ]]; then
				_dkstate="${status_crit}"; (( _disk_any_crit++ ))
				_dkdetail=" SMART: FAILED"
			elif [[ "${_dkhealth}" != "PASSED" && "${_dkhealth}" != "UNKNOWN" && -n "${_dkhealth}" ]]; then
				_dkstate="${status_warn}"; (( _disk_any_warn++ ))
				_dkdetail=" SMART: ${_dkhealth}"
			fi

			# SSD wearout (value is remaining life %; -1 = N/A)
			if [[ "${_dkwear}" =~ ^[0-9]+$ && "${_dktype}" == "ssd" ]]; then
				if [[ "${_dkwear}" -le "${crit_wearout}" ]]; then
					[[ "${_dkstate}" != "${status_crit}" ]] && _dkstate="${status_crit}"
					(( _disk_any_crit++ ))
					_dkdetail+=" wearout:${_dkwear}%"
				elif [[ "${_dkwear}" -le "${warn_wearout}" ]]; then
					[[ "${_dkstate}" == "${status_ok}" ]] && _dkstate="${status_warn}"
					(( _disk_any_warn++ ))
					_dkdetail+=" wearout:${_dkwear}%"
				fi
				_dklbl="${_dknode//-/_}_${_dkdev##*/}"
				pve_perf+=" disk_${_dklbl}_wearout=${_dkwear};${warn_wearout};${crit_wearout};0;100"
			fi

			[[ "${_dkstate}" != "${status_ok}" ]] && \
				pve_problem_output+="${_dkstate} - Disk ${_dknode}/${_dkdev##*/} (${_dkmodel}):${_dkdetail}\n"
			[[ -n "${verbose}" ]] && {
				_dksize_s=$(_fmt_bytes "${_dksize}")
				_dkwear_s=""; [[ "${_dkwear}" =~ ^[0-9]+$ ]] && _dkwear_s=", wear: ${_dkwear}%"
				pve_output+="${_dkstate} -   ${_dknode}/${_dkdev##*/} (${_dkmodel}, ${_dktype}, ${_dksize_s}): ${_dkhealth:-UNKNOWN}${_dkwear_s}${_dkdetail}\n"
			}
		done < <(echo "${_dkbuf}" | "${JQ}" --unbuffered -r '
			.data[]? | [
				(.devpath // ""),
				(.model // ""),
				(.type // ""),
				(.health // ""),
				((.wearout // -1) | tostring),
				((.size // 0) | tostring)
			] | join("\t")' 2>/dev/null)
	done

	if [[ "${_disk_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Disk Health: ${_disk_total} disk(s) | ${_disk_any_crit} critical\n"
	elif [[ "${_disk_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Disk Health: ${_disk_total} disk(s) | ${_disk_any_warn} warning\n"
	else
		pve_output+="${status_ok} - Disk Health: ${_disk_total} disk(s), all OK\n"
	fi
	unset _disk_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# PSI Pressure Stall Check (-ePSI)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_psi}" || -n "${enable_all}" ) && -z "${disable_psi}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="PSI Pressure:\n---------------------------------------\n"

	_psi_any_warn=0; _psi_any_crit=0

	for _pnode in "${_all_nodes[@]}"; do
		_pstbuf=$(cat "${_pf}/node_status_${_pnode}.json" 2>/dev/null)
		[[ -z "${_pstbuf}" ]] && continue

		_pstate="${status_ok}"; _pdetail=""
		_plbl="${_pnode//-/_}"

		while IFS=$'\t' read -r _prestype _pavg10 _pavg60 _pavg300; do
			[[ -z "${_prestype}" || "${_pavg10}" == "null" ]] && continue
			_pavg10_int=$(echo "${_pavg10}" | "${AWK}" '{printf "%d", $1+0.5}')

			if [[ "${_pavg10_int}" -ge "${crit_psi}" ]]; then
				[[ "${_pstate}" != "${status_crit}" ]] && _pstate="${status_crit}"
				(( _psi_any_crit++ ))
				_pdetail+=" ${_prestype}:${_pavg10}%"
			elif [[ "${_pavg10_int}" -ge "${warn_psi}" ]]; then
				[[ "${_pstate}" == "${status_ok}" ]] && _pstate="${status_warn}"
				(( _psi_any_warn++ ))
				_pdetail+=" ${_prestype}:${_pavg10}%"
			fi

			pve_perf+=" psi_${_plbl}_${_prestype}_avg10=${_pavg10};${warn_psi};${crit_psi};0;100"
			pve_perf+=" psi_${_plbl}_${_prestype}_avg60=${_pavg60}"
		done < <(echo "${_pstbuf}" | "${JQ}" --unbuffered -r '
			.data.pressure // {} | to_entries[]? | [
				.key,
				((.value.avg10  // "null") | tostring),
				((.value.avg60  // "null") | tostring),
				((.value.avg300 // "null") | tostring)
			] | join("\t")' 2>/dev/null)

		if [[ -z "${_pdetail}" ]] && ! echo "${_pstbuf}" | "${JQ}" -e '.data.pressure' >/dev/null 2>&1; then
			[[ -n "${verbose}" ]] && \
				pve_output+="${status_ok} - Node ${_pnode}: PSI not available (PVE < 8.1 or kernel < 4.20)\n"
			continue
		fi

		[[ "${_pstate}" != "${status_ok}" ]] && \
			pve_problem_output+="${_pstate} - PSI ${_pnode}:${_pdetail}\n"
		[[ -n "${verbose}" ]] && \
			pve_output+="${_pstate} - Node ${_pnode}: pressure avg10 —${_pdetail:- all OK}\n"
	done

	if [[ "${_psi_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - PSI: ${_psi_any_crit} node(s) critical\n"
	elif [[ "${_psi_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - PSI: ${_psi_any_warn} node(s) warning\n"
	else
		pve_output+="${status_ok} - PSI: all nodes within thresholds\n"
	fi
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Snapshot Age Check (-eSnap)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_snap}" || -n "${enable_all}" ) && -z "${disable_snap}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="Snapshots:\n---------------------------------------\n"

	declare -A _snap_bl_map=()
	if [[ -n "${snap_blacklist}" ]]; then
		IFS=',' read -ra _snap_bl_arr <<< "${snap_blacklist}"
		for _e in "${_snap_bl_arr[@]}"; do _snap_bl_map["${_e// /}"]=1; done
	fi

	_snap_any_warn=0; _snap_any_crit=0; _snap_total=0
	_now_snap=$(date +%s)
	_warn_snap_sec=$(( warn_snap_age * 86400 ))
	_crit_snap_sec=$(( crit_snap_age * 86400 ))

	# Iterate VMs and CTs from cluster/resources
	while IFS=$'\t' read -r _svmid _svmname _svtype _svnode; do
		[[ -z "${_svmid}" ]] && continue
		[[ -n "${_snap_bl_map[${_svmid}]:-}" || -n "${_snap_bl_map[${_svmname}]:-}" ]] && continue
		[[ -n "${pve_node}" && "${_svnode}" != "${pve_node}" ]] && continue

		# Serial per-VM call — parallelising hundreds of VMs is excessive
		case "${_svtype}" in
			qemu) _ssnap_url="${PVE_API}/nodes/${_svnode}/qemu/${_svmid}/snapshot" ;;
			lxc)  _ssnap_url="${PVE_API}/nodes/${_svnode}/lxc/${_svmid}/snapshot"  ;;
			*)    continue ;;
		esac

		_ssbuf=$(pve_api_get "${_ssnap_url}" 2>/dev/null)
		[[ -z "${_ssbuf}" ]] && continue

		while IFS=$'\t' read -r _ssname _sstime; do
			[[ -z "${_ssname}" || "${_ssname}" == "current" ]] && continue
			[[ ! "${_sstime}" =~ ^[0-9]+$ || "${_sstime}" -eq 0 ]] && continue
			(( _snap_total++ ))

			_ssage=$(( _now_snap - _sstime ))
			_ssage_days=$(( _ssage / 86400 ))

			_ssstate="${status_ok}"
			if [[ "${_ssage}" -ge "${_crit_snap_sec}" ]]; then
				_ssstate="${status_crit}"; (( _snap_any_crit++ ))
			elif [[ "${_ssage}" -ge "${_warn_snap_sec}" ]]; then
				_ssstate="${status_warn}"; (( _snap_any_warn++ ))
			fi

			[[ "${_ssstate}" != "${status_ok}" ]] && \
				pve_problem_output+="${_ssstate} - Snapshot ${_svmid}/${_svmname} → ${_ssname}: ${_ssage_days}d old\n"
			[[ -n "${verbose}" ]] && \
				pve_output+="${_ssstate} -   VM/CT ${_svmid} ${_svmname} (${_svnode}) snap ${_ssname}: ${_ssage_days}d old\n"

		done < <(echo "${_ssbuf}" | "${JQ}" --unbuffered -r '
			.data[]? | [
				(.name // ""),
				((.snaptime // 0) | tostring)
			] | join("\t")' 2>/dev/null)

	done < <(echo "${_res_buf}" | "${JQ}" --unbuffered -r '
		.data[]? | select(.type=="qemu" or .type=="lxc") | [
			((.vmid // 0) | tostring),
			(.name // ""),
			(.type // ""),
			(.node // "")
		] | join("\t")' 2>/dev/null)

	if [[ "${_snap_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Snapshots: ${_snap_total} total | ${_snap_any_crit} too old (crit: >${crit_snap_age}d)\n"
	elif [[ "${_snap_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Snapshots: ${_snap_total} total | ${_snap_any_warn} old (warn: >${warn_snap_age}d)\n"
	elif [[ "${_snap_total}" -eq 0 ]]; then
		pve_output+="${status_ok} - Snapshots: none found\n"
	else
		pve_output+="${status_ok} - Snapshots: ${_snap_total} total, all within age thresholds\n"
	fi
	pve_perf+=" snap_total=${_snap_total}"
	unset _snap_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Backup Status Check (-eBackup)  — NOT included in -eAll
# ---------------------------------------------------------------------------
if [[ -n "${enable_backup}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="Backup Status:\n---------------------------------------\n"

	declare -A _bak_bl_map=()
	if [[ -n "${backup_blacklist}" ]]; then
		IFS=',' read -ra _bak_bl_arr <<< "${backup_blacklist}"
		for _e in "${_bak_bl_arr[@]}"; do _bak_bl_map["${_e// /}"]=1; done
	fi

	_bak_any_warn=0; _bak_any_crit=0
	_now_bak=$(date +%s)
	_warn_bak_sec=$(( warn_backup_age * 3600 ))
	_crit_bak_sec=$(( crit_backup_age * 3600 ))

	# VMs not covered by any backup job
	_notcov_buf=$(cat "${_pf}/cluster_backup_notcovered.json" 2>/dev/null)
	if [[ -n "${_notcov_buf}" ]]; then
		while IFS=$'\t' read -r _bvmid _bvname _bvtype; do
			[[ -z "${_bvmid}" ]] && continue
			[[ -n "${_bak_bl_map[${_bvmid}]:-}" || -n "${_bak_bl_map[${_bvname}]:-}" ]] && continue
			(( _bak_any_warn++ ))
			pve_problem_output+="${status_warn} - Backup ${_bvmid}/${_bvname}: not included in any backup job\n"
			[[ -n "${verbose}" ]] && \
				pve_output+="${status_warn} -   ${_bvtype} ${_bvmid} ${_bvname}: no backup job\n"
		done < <(echo "${_notcov_buf}" | "${JQ}" --unbuffered -r '
			.data[]? | [
				((.vmid // 0) | tostring),
				(.name // ""),
				(.type // "")
			] | join("\t")' 2>/dev/null)
	fi

	# Recent backup task results per node
	for _bnode in "${_all_nodes[@]}"; do
		_btbuf=$(cat "${_pf}/node_tasks_backup_${_bnode}.json" 2>/dev/null)
		[[ -z "${_btbuf}" ]] && continue

		# Track most recent backup per vmid
		declare -A _bak_last_ok=() _bak_last_fail=()

		while IFS=$'\t' read -r _btvmid _btstatus _btstarttime _btendtime; do
			[[ -z "${_btvmid}" ]] && continue
			[[ -n "${_bak_bl_map[${_btvmid}]:-}" ]] && continue
			[[ ! "${_btstarttime}" =~ ^[0-9]+$ ]] && continue

			if [[ "${_btstatus}" == "OK" ]]; then
				# Keep most recent successful backup per vmid
				if [[ -z "${_bak_last_ok[${_btvmid}]:-}" || \
				      "${_btstarttime}" -gt "${_bak_last_ok[${_btvmid}]}" ]]; then
					_bak_last_ok["${_btvmid}"]="${_btstarttime}"
				fi
			else
				if [[ -z "${_bak_last_fail[${_btvmid}]:-}" || \
				      "${_btstarttime}" -gt "${_bak_last_fail[${_btvmid}]}" ]]; then
					_bak_last_fail["${_btvmid}"]="${_btstarttime}"
				fi
			fi
		done < <(echo "${_btbuf}" | "${JQ}" --unbuffered -r '
			.data[]? | [
				((.id // "") | ltrimstr("vzdump-") | split("-")[0:2] | join("-") | ltrimstr("qemu-") | ltrimstr("lxc-")),
				(.status // ""),
				((.starttime // 0) | tostring),
				((.endtime   // 0) | tostring)
			] | join("\t")' 2>/dev/null)

		for _bkvmid in "${!_bak_last_ok[@]}"; do
			_blastok="${_bak_last_ok[${_bkvmid}]}"
			_bage=$(( _now_bak - _blastok ))
			_bage_h=$(( _bage / 3600 ))

			_bkstate="${status_ok}"
			# Also flag if there's a more recent failure than the last success
			_blastfail="${_bak_last_fail[${_bkvmid}]:-0}"
			if [[ "${_blastfail}" -gt "${_blastok}" ]]; then
				_bkstate="${status_warn}"; (( _bak_any_warn++ ))
				pve_problem_output+="${status_warn} - Backup ${_bnode}/${_bkvmid}: last task failed (after OK at ${_bage_h}h ago)\n"
			elif [[ "${_bage}" -ge "${_crit_bak_sec}" ]]; then
				_bkstate="${status_crit}"; (( _bak_any_crit++ ))
				pve_problem_output+="${status_crit} - Backup ${_bnode}/${_bkvmid}: last OK backup ${_bage_h}h ago (crit: ${crit_backup_age}h)\n"
			elif [[ "${_bage}" -ge "${_warn_bak_sec}" ]]; then
				_bkstate="${status_warn}"; (( _bak_any_warn++ ))
				pve_problem_output+="${status_warn} - Backup ${_bnode}/${_bkvmid}: last OK backup ${_bage_h}h ago (warn: ${warn_backup_age}h)\n"
			fi

			[[ -n "${verbose}" ]] && \
				pve_output+="${_bkstate} -   ${_bnode}/VM ${_bkvmid}: last OK backup ${_bage_h}h ago\n"
			pve_perf+=" backup_${_bnode//-/_}_${_bkvmid}_age_h=${_bage_h};${warn_backup_age};${crit_backup_age};0"
		done

		unset _bak_last_ok _bak_last_fail
	done

	if [[ "${_bak_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Backup: ${_bak_any_crit} VM(s) critical\n"
	elif [[ "${_bak_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Backup: ${_bak_any_warn} VM(s) warning\n"
	else
		pve_output+="${status_ok} - Backup: all VMs covered and recent\n"
	fi
	unset _bak_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Package Updates Check (-eUpdates)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_updates}" || -n "${enable_all}" ) && -z "${disable_updates}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="Package Updates:\n---------------------------------------\n"

	_upd_any_warn=0; _upd_any_crit=0

	for _unode in "${_all_nodes[@]}"; do
		_ubuf=$(cat "${_pf}/node_updates_${_unode}.json" 2>/dev/null)
		[[ -z "${_ubuf}" ]] && continue

		_utotal=$(echo "${_ubuf}" | "${JQ}" -r '.data | length' 2>/dev/null)
		[[ ! "${_utotal}" =~ ^[0-9]+$ ]] && _utotal=0

		# Security updates: section=security or priority matches important/required
		_usec=$(echo "${_ubuf}" | "${JQ}" -r \
			'[.data[]? | select((.Section // "" | ascii_downcase | contains("security")) or
			 (.Priority // "" | ascii_downcase | test("important|required")))] | length' 2>/dev/null)
		[[ ! "${_usec}" =~ ^[0-9]+$ ]] && _usec=0

		_ustate="${status_ok}"; _udetail=""
		if [[ "${_usec}" -ge "${crit_updates}" && "${_usec}" -gt 0 ]]; then
			_ustate="${status_crit}"; (( _upd_any_crit++ ))
			_udetail=" (${_usec} security)"
			pve_problem_output+="${status_crit} - Updates ${_unode}: ${_utotal} updates available${_udetail}\n"
		elif [[ "${_utotal}" -ge "${warn_updates}" && "${_utotal}" -gt 0 ]]; then
			_ustate="${status_warn}"; (( _upd_any_warn++ ))
			[[ "${_usec}" -gt 0 ]] && _udetail=" (${_usec} security)"
			pve_problem_output+="${status_warn} - Updates ${_unode}: ${_utotal} updates available${_udetail}\n"
		fi

		[[ -n "${verbose}" ]] && \
			pve_output+="${_ustate} - Node ${_unode}: ${_utotal} update(s) available${_udetail}\n"

		_ulbl="${_unode//-/_}"
		pve_perf+=" updates_${_ulbl}_total=${_utotal};${warn_updates};;0"
		[[ "${_usec}" -gt 0 ]] && \
			pve_perf+=" updates_${_ulbl}_security=${_usec};;${crit_updates};0"
	done

	if [[ "${_upd_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Updates: ${_upd_any_crit} node(s) with security updates\n"
	elif [[ "${_upd_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Updates: ${_upd_any_warn} node(s) with pending updates\n"
	else
		pve_output+="${status_ok} - Updates: all nodes up to date\n"
	fi
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Service State Check (-eServices)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_services}" || -n "${enable_all}" ) && -z "${disable_services}" ]]; then
	[[ -n "${verbose}" ]] && pve_output+="Services:\n---------------------------------------\n"

	declare -A _svc_bl_map=()
	# Default: skip services that are inactive when their alternatives run (chrony→timesyncd, journald→syslog)
	for _e in syslog systemd-timesyncd; do _svc_bl_map["${_e}"]=1; done
	if [[ -n "${service_blacklist}" ]]; then
		IFS=',' read -ra _svc_bl_arr <<< "${service_blacklist}"
		for _e in "${_svc_bl_arr[@]}"; do _svc_bl_map["${_e// /}"]=1; done
	fi

	_svc_any_crit=0; _svc_any_warn=0; _svc_ok=0

	for _svcnode in "${_all_nodes[@]}"; do
		_svbuf=$(cat "${_pf}/node_services_${_svcnode}.json" 2>/dev/null)
		[[ -z "${_svbuf}" ]] && continue

		while IFS=$'\t' read -r _svname _svstate _svactive _svunit _svdesc; do
			[[ -z "${_svname}" ]] && continue
			[[ -n "${_svc_bl_map[${_svname}]:-}" ]] && continue
			# Skip services that are not expected to run
			case "${_svunit}" in
				disabled|masked|static|indirect|generated) continue ;;
			esac

			_sv_state="${status_ok}"
			if [[ "${_svactive}" == "failed" ]]; then
				if [[ -n "${warn_failed_service}" ]]; then
					_sv_state="${status_warn}"; (( _svc_any_warn++ ))
				else
					_sv_state="${status_crit}"; (( _svc_any_crit++ ))
				fi
				pve_problem_output+="${_sv_state} - Service ${_svcnode}/${_svname}: ${_svactive}\n"
			elif [[ "${_svunit}" == "enabled" && "${_svactive}" != "active" && "${_svactive}" != "activating" ]]; then
				if [[ -z "${ok_inactive_service}" ]]; then
					_sv_state="${status_warn}"; (( _svc_any_warn++ ))
					pve_problem_output+="${status_warn} - Service ${_svcnode}/${_svname}: enabled but ${_svactive}\n"
				fi
			else
				(( _svc_ok++ ))
			fi

			[[ -n "${verbose}" ]] && \
				pve_output+="${_sv_state} -   ${_svcnode}/${_svname} (${_svunit}): ${_svactive} [${_svstate}]\n"
		done < <(echo "${_svbuf}" | "${JQ}" --unbuffered -r '
			.data[]? | [
				(.name // ""),
				(.state // ""),
				(.["active-state"] // ""),
				(.["unit-file-state"] // ""),
				(.desc // "")
			] | join("\t")' 2>/dev/null)
	done

	if [[ "${_svc_any_crit}" -gt 0 ]]; then
		pve_output+="${status_crit} - Services: ${_svc_any_crit} failed\n"
	elif [[ "${_svc_any_warn}" -gt 0 ]]; then
		pve_output+="${status_warn} - Services: ${_svc_any_warn} service(s) with issues\n"
	else
		pve_output+="${status_ok} - Services: all OK (${_svc_ok} checked)\n"
	fi
	unset _svc_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Task Log Check (-eLog)  — NOT included in -eAll
# ---------------------------------------------------------------------------
if [[ -n "${enable_log}" ]]; then
	# When a specific VM or CT is selected, restrict log to that VMID
	_log_vmid_filter=""
	_log_scope_label="Task Log (last ${logcheck_time})"
	if [[ -n "${_vm_sel_id}" ]]; then
		_log_vmid_filter="${_vm_sel_id}"
		_log_scope_label="Task Log VM ${_vm_sel_id} (last ${logcheck_time})"
	elif [[ -n "${_ct_sel_id}" ]]; then
		_log_vmid_filter="${_ct_sel_id}"
		_log_scope_label="Task Log CT ${_ct_sel_id} (last ${logcheck_time})"
	fi

	[[ -n "${verbose}" ]] && pve_output+="${_log_scope_label}:\n---------------------------------------\n"

	declare -A _log_bl_map=()
	if [[ -n "${log_blacklist_type}" ]]; then
		IFS=',' read -ra _log_bl_arr <<< "${log_blacklist_type}"
		for _e in "${_log_bl_arr[@]}"; do _log_bl_map["${_e// /}"]=1; done
	fi

	_log_warn_count=0; _log_crit_count=0; _log_ok_count=0

	for _lnode in "${_all_nodes[@]}"; do
		_lbuf=$(cat "${_pf}/node_tasks_log_${_lnode}.json" 2>/dev/null)
		[[ -z "${_lbuf}" ]] && continue

		while IFS=$'\t' read -r _lttype _ltstatus _ltstart _ltend _ltupid _ltuser _ltid; do
			[[ -z "${_lttype}" ]] && continue
			[[ -n "${_log_bl_map[${_lttype}]:-}" ]] && continue
			# Skip still-running tasks (no endtime yet)
			[[ "${_ltend}" == "0" || -z "${_ltend}" ]] && continue
			# Filter to specific VM/CT when requested
			[[ -n "${_log_vmid_filter}" && "${_ltid}" != "${_log_vmid_filter}" ]] && continue

			_lt_state="${status_ok}"
			case "${_ltstatus}" in
				OK|ok)
					(( _log_ok_count++ ))
					;;
				WARNING|warning|WARNINGS|warnings|*WARN*|*warn*)
					_lt_state="${status_warn}"; (( _log_warn_count++ ))
					if [[ -n "${verbose}" ]]; then
						pve_output+="${status_warn} -   ${_lnode} task ${_lttype} ($(date -d "@${_ltstart}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "${_ltstart}" '+%Y-%m-%d %H:%M' 2>/dev/null)): ${_ltstatus}\n"
					fi
					;;
				*)
					_lt_state="${status_crit}"; (( _log_crit_count++ ))
					if [[ -n "${verbose}" ]]; then
						pve_output+="${status_crit} -   ${_lnode} task ${_lttype} ($(date -d "@${_ltstart}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "${_ltstart}" '+%Y-%m-%d %H:%M' 2>/dev/null)): ${_ltstatus}\n"
					fi
					;;
			esac
		done < <(echo "${_lbuf}" | "${JQ}" --unbuffered -r '
			.data[]? | [
				(.type // ""),
				(.status // ""),
				((.starttime // 0) | tostring),
				((.endtime // 0) | tostring),
				(.upid // ""),
				(.user // ""),
				((.id // "") | tostring)
			] | join("\t")' 2>/dev/null)
	done

	_log_total=$(( _log_ok_count + _log_warn_count + _log_crit_count ))
	if [[ "${_log_crit_count}" -ge "${crit_log}" ]] 2>/dev/null && [[ "${_log_crit_count}" -gt 0 ]]; then
		pve_output+="${status_crit} - ${_log_scope_label}: ${_log_crit_count} failed task(s) (${_log_total} checked)\n"
		pve_problem_output+="${status_crit} - ${_log_crit_count} failed task(s) in last ${logcheck_time}\n"
	elif [[ "${_log_warn_count}" -ge "${warn_log}" ]] 2>/dev/null && [[ "${_log_warn_count}" -gt 0 ]]; then
		pve_output+="${status_warn} - ${_log_scope_label}: ${_log_warn_count} warning task(s) (${_log_total} checked)\n"
		pve_problem_output+="${status_warn} - ${_log_warn_count} warning task(s) in last ${logcheck_time}\n"
	else
		pve_output+="${status_ok} - ${_log_scope_label}: no errors/warnings (${_log_total} tasks checked)\n"
	fi
	pve_perf+=" log_tasks_ok=${_log_ok_count} log_tasks_warn=${_log_warn_count} log_tasks_crit=${_log_crit_count}"
	unset _log_bl_map
	[[ -n "${verbose}" ]] && pve_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Determine exit state and print result
# ---------------------------------------------------------------------------
if [[ ${pve_output} =~ "[UNKNOWN]" ]]; then
	state=3
	if [[ -z "${silent}" ]]; then
		pve_problems="One or more Problems detected:\n---------------------------------------------------------------------\n"
		pve_problem_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
	fi
elif [[ ${pve_output} =~ "[CRITICAL]" ]]; then
	state=2
	if [[ -z "${silent}" ]]; then
		pve_problems="One or more Problems detected:\n---------------------------------------------------------------------\n"
		pve_problem_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
	fi
elif [[ ${pve_output} =~ "[WARNING]" ]]; then
	state=1
	if [[ -z "${silent}" ]]; then
		pve_problems="One or more Problems detected:\n---------------------------------------------------------------------\n"
		pve_problem_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
	fi
else
	state=0
	pve_problems="All Services OK"
fi

_pp="${pve_problem_output//|/,}"
_po="${pve_output//|/,}"
_perf_sep="${no_perfdata:+}" ; [[ -z "${no_perfdata}" ]] && _perf_sep="|${pve_perf}"

if [[ -z "${silent}" && -n "${pve_problem_output}" ]]; then
	echo -e "${pve_problems}${_pp}${_po}${_perf_sep}"
elif [[ -n "${silent}" && -n "${pve_problem_output}" ]]; then
	echo -e "${_pp}${_perf_sep}"
elif [[ -n "${silent}" && -z "${pve_problem_output}" ]]; then
	echo -e "${status_ok} - All Services are fine${_perf_sep}"
elif [[ -z "${silent}" && -z "${pve_problem_output}" ]]; then
	echo -e "${_po}${_perf_sep}"
else
	echo -e "${_po}${_perf_sep}"
fi

rm -rf "${_pf}" 2>/dev/null
exit ${state}
