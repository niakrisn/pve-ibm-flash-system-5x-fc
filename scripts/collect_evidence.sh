#!/bin/bash
# Evidence collection script for IBM FlashSystem integration tests
# Captures host, Proxmox, and storage state for post-mortem analysis.

set +e

TAG_RAW="${EVIDENCE_TAG:-}"
TAG=""
if [ -n "$TAG_RAW" ]; then
    TAG=$(echo "$TAG_RAW" | tr -c '[:alnum:]._-' '_' | tr -s '_' | sed 's/^_//;s/_$//')
fi

if [ -n "$TAG" ]; then
    TAG="-$TAG"
fi

EVIDENCE_DIR="${1:-/var/log/pve-ibm-fs5x-evidence${TAG}-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$EVIDENCE_DIR"

log_cmd() {
    local name="$1"
    shift
    local cmd="$*"
    {
        echo "## COMMAND: $cmd"
        bash -lc "$cmd"
        echo
    } > "${EVIDENCE_DIR}/${name}.log" 2>&1
}

echo "Collecting evidence to ${EVIDENCE_DIR}..."

# Metadata
{
    echo "timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "hostname=$(hostname)"
    [ -n "$TAG_RAW" ] && echo "test=${TAG_RAW}"
} > "${EVIDENCE_DIR}/meta.txt"

# Basic system context
log_cmd "system" "date; hostname; uname -a; uptime; pveversion -v 2>/dev/null"

# Host device state
log_cmd "multipath" "multipath -ll"
log_cmd "lsblk" "lsblk -o NAME,SERIAL,HCTL,SIZE,TYPE,FSTYPE,MOUNTPOINT,VENDOR,MODEL"
log_cmd "lsblk_scsi" "lsblk -S"
log_cmd "disk_by_id_scsi" "ls -l /dev/disk/by-id/scsi-*"
log_cmd "dmsetup" "dmsetup ls --tree"
log_cmd "dmesg_tail" "dmesg | tail -n 200"

# Proxmox state
log_cmd "qm_list" "qm list"
log_cmd "qm_configs" "ls -l /etc/pve/qemu-server"
log_cmd "storage_cfg" "cat /etc/pve/storage.cfg"
log_cmd "pvesm_status" "pvesm status"
STOREID="fs-01"
if [ -f "/etc/pve/ibm-fs5x-tests.conf" ] && command -v jq >/dev/null 2>&1; then
    STOREID=$(jq -r '.flashsystem_storage // "fs-01"' /etc/pve/ibm-fs5x-tests.conf 2>/dev/null)
fi
log_cmd "pvesm_list_${STOREID}" "pvesm list $STOREID"

# Proxmox logs
log_cmd "pve_storage_ibm_log" "tail -n 200 /var/log/pve-storage-ibm.log"
log_cmd "journal_pvedaemon" "journalctl -u pvedaemon -n 200 --no-pager"
log_cmd "journal_pvestatd" "journalctl -u pvestatd -n 200 --no-pager"
log_cmd "journal_pvecluster" "journalctl -u pve-cluster -n 200 --no-pager"
log_cmd "journal_pveha" "journalctl -u pve-ha-lrm -n 200 --no-pager"

# Proxmox tasks (raw JSON)
pvesh get /nodes/localhost/tasks --output-format json > "${EVIDENCE_DIR}/pve_tasks.json" 2>&1

# Extract recent tasks and fetch logs (last 20)
if [ -s "${EVIDENCE_DIR}/pve_tasks.json" ]; then
    perl -MJSON -e '
        my $file = shift;
        open my $fh, "<", $file or exit 0;
        local $/ = undef;
        my $raw = <$fh>;
        my $data = eval { decode_json($raw) };
        exit 0 if $@ || ref($data) ne "ARRAY";
        my $count = 0;
        for my $t (@$data) {
            next unless $t->{upid};
            print $t->{upid}, "\n";
            last if ++$count >= 20;
        }
    ' "${EVIDENCE_DIR}/pve_tasks.json" > "${EVIDENCE_DIR}/pve_recent_tasks.txt"

    if [ -s "${EVIDENCE_DIR}/pve_recent_tasks.txt" ]; then
        while IFS= read -r upid; do
            [ -z "$upid" ] && continue
            safe_name=$(echo "$upid" | tr ':/ ' '___')
            log_cmd "task_${safe_name}_status" "pvesh get /nodes/localhost/tasks/$upid/status --output-format json"
            log_cmd "task_${safe_name}_log" "pvesh get /nodes/localhost/tasks/$upid/log --output-format json"
        done < "${EVIDENCE_DIR}/pve_recent_tasks.txt"
    fi
fi

# Extract failed tasks and fetch logs
if [ -s "${EVIDENCE_DIR}/pve_tasks.json" ]; then
    perl -MJSON -e '
        my $file = shift;
        open my $fh, "<", $file or exit 0;
        local $/ = undef;
        my $raw = <$fh>;
        my $data = eval { decode_json($raw) };
        exit 0 if $@ || ref($data) ne "ARRAY";
        my @failed;
        for my $t (@$data) {
            my $status = $t->{status} // "";
            next if $status eq "OK" || $status eq "running";
            next unless $t->{upid};
            push @failed, $t->{upid};
        }
        print join("\n", @failed), "\n" if @failed;
    ' "${EVIDENCE_DIR}/pve_tasks.json" > "${EVIDENCE_DIR}/pve_failed_tasks.txt"

    if [ -s "${EVIDENCE_DIR}/pve_failed_tasks.txt" ]; then
        while IFS= read -r upid; do
            [ -z "$upid" ] && continue
            safe_name=$(echo "$upid" | tr ':/ ' '___')
            log_cmd "failed_task_${safe_name}_status" "pvesh get /nodes/localhost/tasks/$upid/status --output-format json"
            log_cmd "failed_task_${safe_name}_log" "pvesh get /nodes/localhost/tasks/$upid/log --output-format json"
        done < "${EVIDENCE_DIR}/pve_failed_tasks.txt"
    fi
fi

# Storage state (IBM FlashSystem)
export EVIDENCE_DIR
export IBMFS_EVIDENCE_MODE=1
perl -I. -I/usr/share/pve-ibm-fs5x-fc-plugin-tests/lib -MTestEnv -MJSON \
     -MPVE::Storage::Custom::IBMFlashSystem::Client -e '
    my $env = TestEnv->setup();
    my $scfg = $env->{scfg};
    my $storeid = $env->{storeid};
    my $json = JSON->new->utf8->pretty;
    my $client = "PVE::Storage::Custom::IBMFlashSystem";
    sub dump_call {
        my ($path, $outfile, $params) = @_;
        my $res = eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
                $client, $scfg, $storeid, "POST", $path, $params,
            );
        };
        open my $fh, ">", $outfile or die "open($outfile): $!";
        if ($@) {
            print $fh "ERROR $path: $@\n";
        } else {
            print $fh $json->encode($res);
        }
        close $fh;
    }
    my $dir = $ENV{EVIDENCE_DIR} || ".";
    dump_call("/lssystem", "$dir/flashsystem_lssystem.json", {});
    dump_call("/lsvdisk", "$dir/flashsystem_vdisks.json", { bytes => JSON::true });
    dump_call("/lsvdiskhostmap", "$dir/flashsystem_hostmaps.json", {});
    dump_call("/lsfcmap", "$dir/flashsystem_fcmaps.json", {});
'

echo "Evidence collection complete: ${EVIDENCE_DIR}"
