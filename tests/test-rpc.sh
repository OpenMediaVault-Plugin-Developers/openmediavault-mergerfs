#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-mergerfs RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises CRUD operations for mergerfs pools, then runs a full
# mount/unmount/restart cycle using real local temporary directories.
# No network access required.
#
# WARNING: The integration test runs omv-salt deploy run mergerfs, which
# regenerates service files and restarts ALL configured mergerfs pools.
# Run on a test system or during a maintenance window.

set -uo pipefail

# ---------------------------------------------------------------------------
# Colours / counters  (display goes to stderr; $() captures only JSON)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1" >&2
    ((PASS++)) || true
}
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------
rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    echo "$out"
    return 0
}

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Return 0 if the pool's stored branch list includes the given path.
# Parses the RPC JSON with python so escaped slashes (\/) don't break matching.
pool_has_path() {
    local uuid=$1 path=$2 out
    out=$(rpc "Mergerfs" "get" "{\"uuid\":\"$uuid\"}" 2>/dev/null || echo "{}")
    echo "$out" | BRANCH_PATH="$path" python3 -c "
import sys, json, os
paths = json.load(sys.stdin).get('paths', '').splitlines()
sys.exit(0 if os.environ['BRANCH_PATH'] in paths else 1)
"
}

# Echo the pathcount field that getList reports for the named pool. Used by the
# UI to disable the "Remove path" action when a pool has a single branch.
pool_pathcount() {
    local name=$1
    rpc "Mergerfs" "getList" "$LIST_PARAMS" 2>/dev/null | POOL_NAME_ENV="$name" python3 -c "
import sys, json, os
data = json.load(sys.stdin).get('data', [])
for p in data:
    if p.get('name') == os.environ['POOL_NAME_ENV']:
        print(p.get('pathcount', ''))
        break
" 2>/dev/null
}

# Print a background job's final status/output (or the exception it failed
# with) for diagnostics. $1 is the raw JSON string returned by an execBgProc
# RPC (e.g. removePath) — a quoted bgStatusFilename.
dump_bgproc() {
    local raw=$1 filename
    filename=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null || echo "")
    if [ -z "$filename" ]; then
        info "dump_bgproc — could not parse bg status filename from: ${raw:0:200}"
        return 1
    fi
    info "Background job output ($filename):"
    rpc "Exec" "getOutput" "{\"filename\":\"$filename\",\"pos\":0}" 2>&1 | head -80 >&2
}

# Wait until a background job finished, then echo its output. $1 is the raw
# JSON string returned by an execBgProc RPC, $2 the timeout in seconds.
# Only Exec.getOutput is polled: Exec.isRunning deletes the status file of a
# finished job. A failed job makes getOutput throw instead of returning its
# output, so the error message is echoed as "ERROR: <message>".
# Returns 1 if the job is still running after the timeout.
wait_bgproc() {
    local raw=$1 timeout=${2:-60} filename pos=0 i resp state
    filename=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null || echo "")
    [ -n "$filename" ] || return 1
    for i in $(seq 1 "$timeout"); do
        resp=$(omv-rpc -u admin "Exec" "getOutput" \
            "{\"filename\":\"$filename\",\"pos\":$pos}" 2>&1 || true)
        # Prints the new output, then a last line "<state> <pos>".
        state=$(echo "$resp" | POS_ENV=$pos python3 -c "
import sys, json, os
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    d = {'error': {'message': raw.strip()}}
if isinstance(d, dict) and d.get('error'):
    print('ERROR: ' + str(d['error'].get('message', '')))
    print('done ' + os.environ['POS_ENV'])
else:
    d = d.get('response', d) if isinstance(d, dict) else {}
    out = d.get('output', '')
    sys.stdout.write(out if not out or out.endswith(chr(10)) else out + chr(10))
    print(('running ' if d.get('running') else 'done ') + str(d.get('pos', 0)))
" 2>/dev/null || echo "done $pos")
        echo "$state" | sed '$d'
        pos=$(echo "$state" | tail -1 | cut -d' ' -f2)
        [ "$(echo "$state" | tail -1 | cut -d' ' -f1)" = "done" ] && return 0
        sleep 1
    done
    return 1
}

# Build Mergerfs.set params for a new pool. $1 name, $2 newline-separated
# paths, $3 optional JSON object merged on top (a null value drops the key).
# Values are passed via the environment so paths may contain any character.
pool_params() {
    POOL_NAME_ENV=$1 POOL_PATHS_ENV=$2 POOL_EXTRA_ENV=${3:-'{}'} \
    NEW_UUID_ENV=$OMV_NEW_UUID python3 -c "
import json, os
d = {
    'uuid': os.environ['NEW_UUID_ENV'], 'mntentref': os.environ['NEW_UUID_ENV'],
    'name': os.environ['POOL_NAME_ENV'], 'paths': os.environ['POOL_PATHS_ENV'],
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'defaults,cache.files=off',
}
d.update(json.loads(os.environ['POOL_EXTRA_ENV']))
print(json.dumps({k: v for k, v in d.items() if v is not None}))"
}

# Echo the "uuid" field of an RPC JSON result.
json_uuid() {
    python3 -c "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo ""
}

# Deploy mergerfs and (re)start the given pool mount; return 0 once mounted.
deploy_and_mount() {
    local mnt=$1 unit i
    omv-salt deploy run mergerfs &>/dev/null || true
    unit=$(systemd-escape --path --suffix=mount "$mnt" 2>/dev/null || echo "")
    if [ -n "$unit" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "$unit" 2>/dev/null || true
    fi
    for i in $(seq 1 15); do
        mountpoint -q "$mnt" 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
POOL1_UUID=""
BRANCH1=""
BRANCH2=""
SALT_LOG=""

# Second pool used by the bulk-files removePath stress test.
POOL2_UUID=""
B2A=""
B2B=""
B2C=""

# Third pool used to confirm a dash/dot pool name mounts correctly despite
# systemd's \x2d-escaping of literal dashes in generated unit names.
POOL3_UUID=""
B3A=""
B3B=""

# Fourth pool used by the removePath free-space and rollback tests.
POOL4_UUID=""
B4A=""
B4B=""

LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

OMV_MOUNT_DIR=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_MOUNT_DIR:-/srv}")

# Pool name avoids hyphens so the systemd unit name has no \x2d escaping.
POOL_NAME="mgtestpool1"
MNT1="${OMV_MOUNT_DIR}/mergerfs/${POOL_NAME}"

POOL2_NAME="mgtestpool2"
MNT2="${OMV_MOUNT_DIR}/mergerfs/${POOL2_NAME}"

# Deliberately contains dashes and a dot to exercise systemd's \x2d escaping.
POOL3_NAME="mg-test-dash.pool"
MNT3="${OMV_MOUNT_DIR}/mergerfs/${POOL3_NAME}"

POOL4_NAME="mgtestpool4"
MNT4="${OMV_MOUNT_DIR}/mergerfs/${POOL4_NAME}"

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
# Stop a pool's systemd mount unit (if active) and force-unmount as a fallback.
stop_pool_mount() {
    local mnt=$1
    mountpoint -q "$mnt" 2>/dev/null || return 0
    info "Stopping pool mount at $mnt"
    local unit
    unit=$(systemd-escape --path --suffix=mount "$mnt" 2>/dev/null || echo "")
    if [ -n "$unit" ]; then
        systemctl stop "$unit" 2>/dev/null || true
        sleep 1
    fi
    mountpoint -q "$mnt" 2>/dev/null && fusermount -uz "$mnt" 2>/dev/null || true
}

cleanup() {
    section "Cleanup"

    # Stop pool mounts if still active
    stop_pool_mount "$MNT1"
    stop_pool_mount "$MNT2"
    stop_pool_mount "$MNT3"
    stop_pool_mount "$MNT4"

    # Delete integration-test pools from DB
    if [ -n "$POOL1_UUID" ]; then
        info "Deleting pool $POOL1_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL1_UUID\"}" &>/dev/null || true
    fi
    if [ -n "$POOL2_UUID" ]; then
        info "Deleting pool $POOL2_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL2_UUID\"}" &>/dev/null || true
    fi
    if [ -n "$POOL3_UUID" ]; then
        info "Deleting pool $POOL3_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL3_UUID\"}" &>/dev/null || true
    fi
    if [ -n "$POOL4_UUID" ]; then
        info "Deleting pool $POOL4_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL4_UUID\"}" &>/dev/null || true
    fi

    # Redeploy to remove generated systemd unit files
    info "Running omv-salt deploy run mergerfs (cleanup)"
    omv-salt deploy run mergerfs &>/dev/null || true

    # Remove temp branch directories and salt log
    [ -n "$BRANCH1" ] && rm -rf "$BRANCH1" 2>/dev/null || true
    [ -n "$BRANCH2" ] && rm -rf "$BRANCH2" 2>/dev/null || true
    [ -n "$B2A" ] && rm -rf "$B2A" 2>/dev/null || true
    [ -n "$B2B" ] && rm -rf "$B2B" 2>/dev/null || true
    [ -n "$B2C" ] && rm -rf "$B2C" 2>/dev/null || true
    [ -n "$B3A" ] && rm -rf "$B3A" 2>/dev/null || true
    [ -n "$B3B" ] && rm -rf "$B3B" 2>/dev/null || true
    [ -n "$B4A" ] && rm -rf "$B4A" 2>/dev/null || true
    [ -n "$B4B" ] && rm -rf "$B4B" 2>/dev/null || true
    [ -n "$SALT_LOG" ] && rm -f "$SALT_LOG" 2>/dev/null || true

    info "Done."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# CRUD helper — create, read, delete; no mounting
# ---------------------------------------------------------------------------
crud_test() {
    local label=$1 params=$2
    local result uuid
    result=$(assert_rpc "set ($label)" "Mergerfs" "set" "$params") || return 1
    uuid=$(echo "$result" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
    if [ -z "$uuid" ] || [ "$uuid" = "$OMV_NEW_UUID" ]; then
        _fail "set ($label) — no real UUID returned"
        return 1
    fi
    assert_rpc "get ($label)" "Mergerfs" "get" \
        "{\"uuid\":\"$uuid\"}" "\"uuid\":\"$uuid\"" >/dev/null
    assert_rpc "getList includes $label" "Mergerfs" "getList" \
        "$LIST_PARAMS" "\"name\":\"$label\"" >/dev/null
    assert_rpc "delete ($label)" "Mergerfs" "delete" \
        "{\"uuid\":\"$uuid\"}" >/dev/null
    assert_rpc_fails "get ($label) after delete" "Mergerfs" "get" \
        "{\"uuid\":\"$uuid\"}"
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
section "Pre-flight"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Must be run as root.${NC}" >&2
    exit 1
fi

for cmd in omv-rpc python3 omv-salt mountpoint fusermount systemd-escape mergerfs; do
    if command -v "$cmd" &>/dev/null; then
        _pass "command available: $cmd"
    else
        _fail "command available: $cmd" "$cmd not found in PATH"
    fi
done

if ! omv-rpc -u admin "Config" "isDirty" '{}' &>/dev/null; then
    echo -e "\n${RED}omv-rpc not functional — aborting.${NC}" >&2
    exit 1
fi
_pass "omv-rpc functional"

# ---------------------------------------------------------------------------
# Informational RPCs (empty state check)
# ---------------------------------------------------------------------------
section "Informational RPCs"

assert_rpc "getList" "Mergerfs" "getList" "$LIST_PARAMS" >/dev/null

# ---------------------------------------------------------------------------
# CRUD — create/get/delete for several policy/unit combinations
# ---------------------------------------------------------------------------
section "CRUD — pool with pfrd policy, G unit"
crud_test "mgtestcrud1" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestcrud1',
    'paths': '/tmp/mgtestcrud1b1\n/tmp/mgtestcrud1b2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'defaults,cache.files=off',
}))")"

section "CRUD — pool with mfs policy, M unit"
crud_test "mgtestcrud2" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestcrud2',
    'paths': '/tmp/mgtestcrud2b1\n/tmp/mgtestcrud2b2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'mfs', 'minfreespace': 512, 'minfreespaceunit': 'M',
    'options': 'defaults,cache.files=off',
}))")"

section "CRUD — pool with epff policy, K unit, no options"
crud_test "mgtestcrud3" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestcrud3',
    'paths': '/tmp/mgtestcrud3b1\n/tmp/mgtestcrud3b2\n/tmp/mgtestcrud3b3',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'epff', 'minfreespace': 100, 'minfreespaceunit': 'K',
    'options': '',
}))")"

section "CRUD — pool with lup policy (added in current changes)"
crud_test "mgtestcrud4" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestcrud4',
    'paths': '/tmp/mgtestcrud4b1\n/tmp/mgtestcrud4b2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'lup', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'cache.files=auto-full',
}))")"

section "CRUD — pool with epmfs policy"
crud_test "mgtestcrud5" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestcrud5',
    'paths': '/tmp/mgtestcrud5b1\n/tmp/mgtestcrud5b2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'epmfs', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'cache.files=auto-full',
}))")"

# ---------------------------------------------------------------------------
# Validation — negative tests
# ---------------------------------------------------------------------------
section "Validation — negative tests"

# Create a pool so we can test duplicate-name rejection
TMP_RESULT=$(rpc "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestdupcheck',
    'paths': '/tmp/mgtestdupb1\n/tmp/mgtestdupb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'defaults,cache.files=off',
}))")" 2>/dev/null || echo "{}")
TMP_UUID=$(echo "$TMP_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$TMP_UUID" ] && [ "$TMP_UUID" != "$OMV_NEW_UUID" ]; then
    assert_rpc_fails "set — duplicate name rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestdupcheck',
    'paths': '/tmp/mgtestdupb3\n/tmp/mgtestdupb4',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'mfs', 'minfreespace': 1, 'minfreespaceunit': 'G',
    'options': '',
}))")"
    rpc "Mergerfs" "delete" "{\"uuid\":\"$TMP_UUID\"}" &>/dev/null || true
else
    _fail "duplicate name test — could not create base pool"
fi

assert_rpc_fails "set — invalid createpolicy rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestbadpolicy',
    'paths': '/tmp/mgtestbadb1\n/tmp/mgtestbadb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'roundrobin', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': '',
}))")"

assert_rpc_fails "set — invalid minfreespaceunit rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mgtestbadunit',
    'paths': '/tmp/mgtestbadub1\n/tmp/mgtestbadub2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'T',
    'options': '',
}))")"

section "Validation — pool name pattern (dashes/dots allowed, unsafe chars rejected)"

# Dashes and dots are allowed anywhere except as the first character.
crud_test "mg-test.pattern-ok" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'mg-test.pattern-ok',
    'paths': '/tmp/mgtestpatternb1\n/tmp/mgtestpatternb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': '',
}))")"

assert_rpc_fails "set — name starting with dash rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '-badname',
    'paths': '/tmp/mgtestbadnameb1\n/tmp/mgtestbadnameb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': '',
}))")"

assert_rpc_fails "set — name starting with dot rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '.badname',
    'paths': '/tmp/mgtestbadnameb1\n/tmp/mgtestbadnameb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': '',
}))")"

assert_rpc_fails "set — name containing slash rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'bad/name',
    'paths': '/tmp/mgtestbadnameb1\n/tmp/mgtestbadnameb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': '',
}))")"

assert_rpc_fails "set — name containing space rejected" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'bad name',
    'paths': '/tmp/mgtestbadnameb1\n/tmp/mgtestbadnameb2',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'pfrd', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': '',
}))")"

section "Validation — branch paths (shell/systemd-unsafe characters rejected)"

# These paths end up in a root shell command and the systemd unit.
for bad in '/tmp/mgtest$(id)' '/tmp/mgtest"q' "/tmp/mgtest'q" '/tmp/mgtest;q' \
    '/tmp/mgtest`q' '/tmp/mgtest|q' '/tmp/mgtest&q' '/tmp/mgtest\q' 'tmp/mgtestrelative'; do
    assert_rpc_fails "set — unsafe path rejected: $bad" "Mergerfs" "set" \
        "$(pool_params "mgtestbadpath" "/tmp/mgtestgoodb1"$'\n'"$bad")"
    # Remove the pool again if the bad path was wrongly accepted.
    LEAKED_UUID=$(rpc "Mergerfs" "getList" "$LIST_PARAMS" 2>/dev/null | python3 -c "
import sys, json
for p in json.load(sys.stdin).get('data', []):
    if p.get('name') == 'mgtestbadpath':
        print(p.get('uuid', ''))
" 2>/dev/null || echo "")
    [ -n "$LEAKED_UUID" ] && rpc "Mergerfs" "delete" "{\"uuid\":\"$LEAKED_UUID\"}" &>/dev/null
done

section "Validation — accepted edge cases"

# The UI allows a minimum free space of 0; the RPC schema must agree.
crud_test "mgtestminfree0" "$(pool_params "mgtestminfree0" \
    "/tmp/mgtestminfree0b1"$'\n'"/tmp/mgtestminfree0b2" '{"minfreespace": 0}')"

# Optional array/string params may be omitted by API callers.
crud_test "mgtestnoarrays" "$(pool_params "mgtestnoarrays" \
    "/tmp/mgtestnoarraysb1"$'\n'"/tmp/mgtestnoarraysb2" \
    '{"sharedfolderrefs": null, "filesystems": null, "options": null}')"

# Globs and spaces are legitimate in branch paths.
crud_test "mgtestglobspace" "$(pool_params "mgtestglobspace" \
    "/tmp/mgtest glob*"$'\n'"/tmp/mgtest space dir")"

# Whitespace and CR around each path are trimmed, blank lines are dropped.
TRIM_RESULT=$(rpc "Mergerfs" "set" "$(pool_params "mgtesttrim" \
    $'  /tmp/mgtesttrimb1  \r\n/tmp/mgtesttrimb2\t\n\n')" 2>/dev/null || echo "{}")
TRIM_UUID=$(echo "$TRIM_RESULT" | json_uuid)
if [ -n "$TRIM_UUID" ] && [ "$TRIM_UUID" != "$OMV_NEW_UUID" ]; then
    TRIM_PATHS=$(rpc "Mergerfs" "get" "{\"uuid\":\"$TRIM_UUID\"}" 2>/dev/null | python3 -c \
        "import sys,json; print(repr(json.load(sys.stdin).get('paths','').splitlines()))" 2>/dev/null)
    if [ "$TRIM_PATHS" = "['/tmp/mgtesttrimb1', '/tmp/mgtesttrimb2']" ]; then
        _pass "set — paths trimmed and blank lines dropped"
    else
        _fail "set — paths not trimmed" "got: $TRIM_PATHS"
    fi
    rpc "Mergerfs" "delete" "{\"uuid\":\"$TRIM_UUID\"}" &>/dev/null || true
else
    _fail "set — trim test pool could not be created" "${TRIM_RESULT:0:200}"
fi

assert_rpc_fails "restartPool — malformed UUID rejected" "Mergerfs" "restartPool" \
    '{"uuid":"not-a-uuid"}'

assert_rpc_fails "get — unknown UUID" "Mergerfs" "get" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

assert_rpc_fails "delete — unknown UUID" "Mergerfs" "delete" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# Integration — create pool, check FileSystemMgmt before mount (regression),
# then deploy via omv-salt and verify full mount lifecycle
# ---------------------------------------------------------------------------
section "Integration — pool setup"

BRANCH1=$(mktemp -d)
BRANCH2=$(mktemp -d)
echo "mergerfs rpc test branch1 file" > "$BRANCH1/testb1.txt"
echo "mergerfs rpc test branch2 file" > "$BRANCH2/testb2.txt"
_pass "branch directories created: $BRANCH1, $BRANCH2"

RESULT1=$(assert_rpc "set ($POOL_NAME)" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '$POOL_NAME',
    'paths': '${BRANCH1}\n${BRANCH2}',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'mfs', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'defaults,cache.files=off',
}))")") || exit 1

POOL1_UUID=$(echo "$RESULT1" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$POOL1_UUID" ] || [ "$POOL1_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "integration — failed to create $POOL_NAME; cannot continue"
    exit 1
fi

# Verify set returns a real mntentref (FsTab entry was created)
MNTENTREF1=$(echo "$RESULT1" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" 2>/dev/null || echo "")
if [ -n "$MNTENTREF1" ] && [ "$MNTENTREF1" != "$OMV_NEW_UUID" ]; then
    _pass "set — mntentref assigned ($MNTENTREF1)"
else
    _fail "set — mntentref not properly assigned (FsTab entry may be missing)"
fi

# A new pool must always get its own mount point entry, even if the caller
# passes the mntentref of an existing one (which would otherwise be overwritten).
if [ -n "$MNTENTREF1" ] && [ "$MNTENTREF1" != "$OMV_NEW_UUID" ]; then
    HIJACK_RESULT=$(rpc "Mergerfs" "set" "$(pool_params "mgtesthijack" \
        "/tmp/mgtesthijackb1"$'\n'"/tmp/mgtesthijackb2" \
        "{\"mntentref\": \"$MNTENTREF1\"}")" 2>/dev/null || echo "{}")
    HIJACK_UUID=$(echo "$HIJACK_RESULT" | json_uuid)
    HIJACK_MNTENT=$(echo "$HIJACK_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" 2>/dev/null || echo "")
    if [ -n "$HIJACK_MNTENT" ] && [ "$HIJACK_MNTENT" != "$MNTENTREF1" ]; then
        _pass "set — new pool gets its own mntentref (caller value ignored)"
    else
        _fail "set — new pool reused caller-supplied mntentref" "got: ${HIJACK_MNTENT:-empty}"
    fi
    MNT1_DIR=$(rpc "FsTab" "get" "{\"uuid\":\"$MNTENTREF1\"}" 2>/dev/null | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('dir',''))" 2>/dev/null || echo "")
    if [ "$MNT1_DIR" = "$MNT1" ]; then
        _pass "set — existing mount point entry of $POOL_NAME left untouched"
    else
        _fail "set — mount point entry of $POOL_NAME was modified" "dir: ${MNT1_DIR:-empty}"
    fi
    # Deleting the pool would also delete a shared mount point entry.
    if [ -n "$HIJACK_UUID" ] && [ "$HIJACK_UUID" != "$OMV_NEW_UUID" ] \
        && [ "$HIJACK_MNTENT" != "$MNTENTREF1" ]; then
        rpc "Mergerfs" "delete" "{\"uuid\":\"$HIJACK_UUID\"}" &>/dev/null || true
    fi
fi

# Verify get returns the pool with correct paths
GET_RESULT=$(rpc "Mergerfs" "get" "{\"uuid\":\"$POOL1_UUID\"}" 2>/dev/null || echo "{}")
STORED_PATHS=$(echo "$GET_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('paths',''))" 2>/dev/null || echo "")
if [ "$STORED_PATHS" = "${BRANCH1}"$'\n'"${BRANCH2}" ]; then
    _pass "get — stored paths are exactly branch1, branch2 (in order)"
else
    _fail "get — stored paths wrong" "got: ${STORED_PATHS:0:200}"
fi

# Three paths with a duplicate and padding: every path must survive intact
# and in order (guards against the last entry being overwritten).
ORDER_RESULT=$(rpc "Mergerfs" "set" "$(pool_params "mgtestorder" \
    $'/tmp/mgtestorderb1\n/tmp/mgtestorderb2\n/tmp/mgtestorderb1\n /tmp/mgtestorderb3 ')" \
    2>/dev/null || echo "{}")
ORDER_UUID=$(echo "$ORDER_RESULT" | json_uuid)
if [ -n "$ORDER_UUID" ] && [ "$ORDER_UUID" != "$OMV_NEW_UUID" ]; then
    ORDER_PATHS=$(rpc "Mergerfs" "get" "{\"uuid\":\"$ORDER_UUID\"}" 2>/dev/null | python3 -c \
        "import sys,json; print(':'.join(json.load(sys.stdin).get('paths','').splitlines()))" 2>/dev/null)
    if [ "$ORDER_PATHS" = "/tmp/mgtestorderb1:/tmp/mgtestorderb2:/tmp/mgtestorderb3" ]; then
        _pass "set — three paths stored intact, deduplicated, in order"
    else
        _fail "set — paths altered on save" "got: $ORDER_PATHS"
    fi
    rpc "Mergerfs" "delete" "{\"uuid\":\"$ORDER_UUID\"}" &>/dev/null || true
else
    _fail "set — order test pool could not be created" "${ORDER_RESULT:0:200}"
fi

# ---------------------------------------------------------------------------
# Regression — FileSystemMgmt::getList must not throw when pool is in DB
# but its mount point directory does not yet exist (unmounted pool).
# Fixed by checking isMounted() before calling df in getDescription().
# ---------------------------------------------------------------------------
section "Regression — FileSystemMgmt::getList with unmounted pool in DB"

assert_rpc "FileSystemMgmt getList — no exception with unmounted pool" \
    "FileSystemMgmt" "getList" \
    '{"start":0,"limit":25,"sortfield":null,"sortdir":null}' >/dev/null

# ---------------------------------------------------------------------------
# Deploy via omv-salt
# ---------------------------------------------------------------------------
section "Integration — omv-salt deploy"

SALT_LOG=$(mktemp)
info "Running omv-salt deploy run mergerfs ..."
if omv-salt deploy run mergerfs > "$SALT_LOG" 2>&1; then
    _pass "omv-salt deploy"
else
    _fail "omv-salt deploy"
    info "Salt output:"
    cat "$SALT_LOG" >&2
fi

# Determine unit name for fallback and diagnostics
UNIT_NAME=$(systemd-escape --path --suffix=mount "$MNT1" 2>/dev/null || echo "")
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"

if [ -f "$UNIT_FILE" ]; then
    _pass "unit file created: $UNIT_FILE"
    # Each required mount is quoted so paths with spaces stay intact.
    REQ_LINE=$(grep '^RequiresMountsFor=' "$UNIT_FILE" || echo "")
    if [ "$REQ_LINE" = "RequiresMountsFor=" ] || [[ "$REQ_LINE" =~ ^RequiresMountsFor=\".+\"$ ]]; then
        _pass "unit file — RequiresMountsFor paths quoted ($REQ_LINE)"
    else
        _fail "unit file — RequiresMountsFor not quoted" "$REQ_LINE"
    fi
    if grep -q 'network-fs.target' "$UNIT_FILE"; then
        _fail "unit file — still references non-existent network-fs.target"
    else
        _pass "unit file — no reference to non-existent network-fs.target"
    fi
    VERIFY_OUT=$(systemd-analyze verify --man=no "$UNIT_FILE" 2>&1 | grep -F "$UNIT_NAME" || true)
    if echo "$VERIFY_OUT" | grep -qiE 'invalid|failed|ignoring'; then
        _fail "unit file — systemd-analyze verify reports problems" "$(echo "$VERIFY_OUT" | head -3)"
    else
        _pass "unit file — systemd-analyze verify clean"
    fi
else
    _fail "unit file missing: $UNIT_FILE"
    info "Salt may have failed before creating the unit. Check the output above."
fi

# If salt didn't start the mount, try once manually via systemctl
if ! mountpoint -q "$MNT1" 2>/dev/null && [ -f "$UNIT_FILE" ]; then
    info "Mount not active after salt — attempting manual systemctl start ..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl start "$UNIT_NAME" 2>/dev/null || true
    sleep 3
fi

# Wait up to 30 s for the mount to become active
info "Waiting for pool mount to become active (up to 30 s) ..."
for i in $(seq 1 15); do
    mountpoint -q "$MNT1" 2>/dev/null && break
    sleep 2
done

if mountpoint -q "$MNT1" 2>/dev/null; then
    _pass "$POOL_NAME mounted at $MNT1"
else
    _fail "$POOL_NAME not mounted at $MNT1 after 30 s"
    if [ -n "$UNIT_NAME" ]; then
        info "Journal for $UNIT_NAME (last 20 lines):"
        journalctl -u "$UNIT_NAME" -n 20 --no-pager 2>/dev/null >&2 || true
    fi
fi

# ---------------------------------------------------------------------------
# Verify merged view of branches
# ---------------------------------------------------------------------------
section "Integration — merged filesystem access"

if [ -f "$MNT1/testb1.txt" ]; then
    _pass "testb1.txt accessible through mergerfs mount"
else
    _fail "testb1.txt not found through mergerfs mount (branch1 may not be merged)"
fi

if [ -f "$MNT1/testb2.txt" ]; then
    _pass "testb2.txt accessible through mergerfs mount"
else
    _fail "testb2.txt not found through mergerfs mount (branch2 may not be merged)"
fi

# Write a file through the merged mount and verify it lands in a branch
if mountpoint -q "$MNT1" 2>/dev/null; then
    echo "written through pool" > "$MNT1/testwrite.txt"
    if [ -f "$BRANCH1/testwrite.txt" ] || [ -f "$BRANCH2/testwrite.txt" ]; then
        _pass "write through pool lands in a branch (create policy working)"
    else
        _fail "write through pool — file not found in either branch"
    fi
fi

# ---------------------------------------------------------------------------
# getList, getCandidates, FileSystemMgmt (with active pool)
# ---------------------------------------------------------------------------
section "Integration — RPCs with active pool"

# FileSystemMgmt::getList must include the pool (with size info when mounted)
assert_rpc "FileSystemMgmt getList — pool present when mounted" \
    "FileSystemMgmt" "getList" \
    '{"start":0,"limit":25,"sortfield":null,"sortdir":null}' \
    "mergerfs" >/dev/null

# Pool must appear exactly once in getCandidates
CANDIDATES=$(rpc "ShareMgmt" "getCandidates" '{}' 2>/dev/null || echo "[]")
CAND_COUNT=$(echo "$CANDIDATES" | python3 -c "
import sys, json
cands = json.load(sys.stdin)
print(sum(1 for c in cands if '${POOL_NAME}' in c.get('description', '')))
" 2>/dev/null || echo 0)
if [ "$CAND_COUNT" = "1" ]; then
    _pass "ShareMgmt getCandidates — $POOL_NAME appears exactly once"
elif [ "$CAND_COUNT" = "0" ]; then
    _fail "ShareMgmt getCandidates — $POOL_NAME not found"
else
    _fail "ShareMgmt getCandidates — $POOL_NAME appears $CAND_COUNT times (expected 1)"
fi

# getList inuse flag (no shared folders yet)
LIST_RESULT=$(rpc "Mergerfs" "getList" "$LIST_PARAMS" 2>/dev/null || echo '{"data":[]}')
POOL_INUSE=$(echo "$LIST_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for p in data:
    if p.get('name') == '${POOL_NAME}':
        print(str(p.get('inuse', '')).lower())
        break
else:
    print('not_found')
" 2>/dev/null || echo "error")
if [ "$POOL_INUSE" = "false" ]; then
    _pass "getList — $POOL_NAME inuse=false (no shared folders)"
elif [ "$POOL_INUSE" = "not_found" ]; then
    _fail "getList — $POOL_NAME not found in list"
else
    # inuse might be True if the system already has shared folders on this path
    info "getList — $POOL_NAME inuse=$POOL_INUSE (expected false for new pool)"
    _pass "getList — $POOL_NAME found in list"
fi

# ---------------------------------------------------------------------------
# Shared folder on the pool — inuse flag
# ---------------------------------------------------------------------------
section "Shared folder — inuse flag in getList"

SF_UUID=""
if [ -n "$MNTENTREF1" ] && mountpoint -q "$MNT1" 2>/dev/null; then
    mkdir -p "$BRANCH1/mgtestsfdir"

    SF_RESULT=$(rpc "ShareMgmt" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'name': 'mgtestsf1',
    'mntentref': '$MNTENTREF1', 'reldirpath': 'mgtestsfdir',
    'comment': 'mergerfs rpc test shared folder', 'mode': '775',
}))")" 2>/dev/null || echo "{}")
    SF_UUID=$(echo "$SF_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

    if [ -n "$SF_UUID" ] && [ "$SF_UUID" != "$OMV_NEW_UUID" ]; then
        _pass "created shared folder on pool ($SF_UUID)"

        LIST_RESULT2=$(rpc "Mergerfs" "getList" "$LIST_PARAMS" 2>/dev/null || echo '{"data":[]}')
        POOL_INUSE2=$(echo "$LIST_RESULT2" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for p in data:
    if p.get('name') == '${POOL_NAME}':
        print(str(p.get('inuse', '')).lower())
        break
" 2>/dev/null || echo "not_found")
        if [ "$POOL_INUSE2" = "true" ]; then
            _pass "getList — $POOL_NAME inuse=true after shared folder created"
        else
            _fail "getList — expected inuse=true after shared folder, got: $POOL_INUSE2"
        fi

        # The RPC itself must refuse, not only the UI's disabled button.
        assert_rpc_fails "delete — pool in use by a shared folder rejected" \
            "Mergerfs" "delete" "{\"uuid\":\"$POOL1_UUID\"}"
        assert_rpc "get — in-use pool still present after rejected delete" \
            "Mergerfs" "get" "{\"uuid\":\"$POOL1_UUID\"}" "\"uuid\":\"$POOL1_UUID\"" >/dev/null
        if mountpoint -q "$MNT1" 2>/dev/null; then
            _pass "in-use pool still mounted after rejected delete"
        else
            _fail "in-use pool unmounted after rejected delete"
        fi

        rpc "ShareMgmt" "delete" \
            "{\"uuid\":\"$SF_UUID\",\"recursive\":false}" &>/dev/null || true
    else
        _fail "shared folder — could not create test shared folder (SF_UUID=${SF_UUID:-empty})"
    fi
    rm -rf "$BRANCH1/mgtestsfdir" 2>/dev/null || true
else
    _fail "shared folder test — skipped (pool not active or mntentref missing)"
fi

# ---------------------------------------------------------------------------
# restartPool RPC
# ---------------------------------------------------------------------------
section "restartPool RPC"

assert_rpc "restartPool — no exception" "Mergerfs" "restartPool" \
    "{\"uuid\":\"$POOL1_UUID\"}" >/dev/null

info "Waiting for pool to remount after restart (up to 20 s) ..."
for i in $(seq 1 10); do
    mountpoint -q "$MNT1" 2>/dev/null && break
    sleep 2
done

if mountpoint -q "$MNT1" 2>/dev/null; then
    _pass "pool remounted after restartPool"
else
    _fail "pool not remounted after restartPool"
fi

# ---------------------------------------------------------------------------
# toolsCommand — balance and dedup (practice)
# ---------------------------------------------------------------------------
section "toolsCommand — balance"

if mountpoint -q "$MNT1" 2>/dev/null; then
    assert_rpc "toolsCommand balance — background job dispatched" \
        "Mergerfs" "toolsCommand" \
        "{\"uuid\":\"$POOL1_UUID\",\"command\":\"balance\",\"practice\":false,\"dedup\":\"none\"}" >/dev/null
else
    _fail "toolsCommand balance — skipped (pool not mounted)"
fi

section "toolsCommand — invalid arguments rejected before dispatch"

assert_rpc_fails "toolsCommand — unknown command rejected" "Mergerfs" "toolsCommand" \
    "{\"uuid\":\"$POOL1_UUID\",\"command\":\"rm\",\"practice\":true,\"dedup\":\"oldest\"}"
assert_rpc_fails "toolsCommand — unknown dedup policy rejected" "Mergerfs" "toolsCommand" \
    "{\"uuid\":\"$POOL1_UUID\",\"command\":\"dedup\",\"practice\":true,\"dedup\":\"bogus\"}"
assert_rpc_fails "toolsCommand — shell metacharacters in dedup rejected" "Mergerfs" "toolsCommand" \
    "{\"uuid\":\"$POOL1_UUID\",\"command\":\"dedup\",\"practice\":true,\"dedup\":\"oldest; touch /tmp/mgtestpwned\"}"
sleep 2  # give a wrongly dispatched background job time to run
if [ -e /tmp/mgtestpwned ]; then
    _fail "toolsCommand — injected command was executed"
    rm -f /tmp/mgtestpwned
else
    _pass "toolsCommand — injected command not executed"
fi

section "toolsCommand — dedup (practice mode, no files deleted)"

if mountpoint -q "$MNT1" 2>/dev/null; then
    assert_rpc "toolsCommand dedup oldest (practice) — background job dispatched" \
        "Mergerfs" "toolsCommand" \
        "{\"uuid\":\"$POOL1_UUID\",\"command\":\"dedup\",\"practice\":true,\"dedup\":\"oldest\"}" >/dev/null
    assert_rpc "toolsCommand dedup newest (practice) — background job dispatched" \
        "Mergerfs" "toolsCommand" \
        "{\"uuid\":\"$POOL1_UUID\",\"command\":\"dedup\",\"practice\":true,\"dedup\":\"newest\"}" >/dev/null
else
    _fail "toolsCommand dedup — skipped (pool not mounted)"
fi

# ---------------------------------------------------------------------------
# getPoolPaths / removePath — list branches, remove one, migrate its data
# ---------------------------------------------------------------------------
section "getPoolPaths — lists pool branches"

GPP_RESULT=$(rpc "Mergerfs" "getPoolPaths" "{\"uuid\":\"$POOL1_UUID\"}" 2>/dev/null || echo "[]")
GPP_COUNT=$(echo "$GPP_RESULT" | B1="$BRANCH1" B2="$BRANCH2" python3 -c "
import sys, json, os
paths = [p.get('path', '') for p in json.load(sys.stdin)]
print(sum(1 for x in (os.environ['B1'], os.environ['B2']) if x in paths))
" 2>/dev/null || echo 0)
if [ "$GPP_COUNT" = "2" ]; then
    _pass "getPoolPaths — returns both branches"
else
    _fail "getPoolPaths — missing a branch (got: ${GPP_RESULT:0:200})"
fi

PC_BEFORE=$(pool_pathcount "$POOL_NAME")
if [ "$PC_BEFORE" = "2" ]; then
    _pass "getList — pathcount=2 for $POOL_NAME"
else
    _fail "getList — expected pathcount=2, got '${PC_BEFORE:-empty}'"
fi

section "removePath — negative tests"

assert_rpc_fails "removePath — path not in pool rejected" "Mergerfs" "removePath" \
    "{\"uuid\":\"$POOL1_UUID\",\"path\":\"/tmp/mgtest-nonexistent-branch\",\"deletesource\":false}"

section "removePath — remove BRANCH2 and migrate its data"

if mountpoint -q "$MNT1" 2>/dev/null; then
    # Ensure BRANCH2 has a uniquely named file to track migration.
    echo "migrate me" > "$BRANCH2/mgtestmigrate.txt"

    RP1_JOB=$(assert_rpc "removePath — background job dispatched" "Mergerfs" "removePath" \
        "{\"uuid\":\"$POOL1_UUID\",\"path\":\"$BRANCH2\",\"deletesource\":false}") || true

    # The branch removal + salt deploy + restart + rsync run in the background.
    info "Waiting for removePath background job to migrate data (up to 60 s) ..."
    MIGRATED=false
    for i in $(seq 1 30); do
        if [ -f "$BRANCH1/mgtestmigrate.txt" ]; then
            MIGRATED=true
            break
        fi
        sleep 2
    done

    if [ "$MIGRATED" = true ]; then
        _pass "removePath — BRANCH2 data migrated onto remaining branch (BRANCH1)"
    else
        _fail "removePath — migrated file not found on BRANCH1 after 60 s"
        dump_bgproc "$RP1_JOB"
    fi

    # Config must no longer list BRANCH2 as a branch.
    if pool_has_path "$POOL1_UUID" "$BRANCH2"; then
        _fail "removePath — BRANCH2 still present in pool config"
    else
        _pass "removePath — BRANCH2 removed from pool config"
    fi

    # getList pathcount must now report a single branch (UI disables the action).
    PC_AFTER=$(pool_pathcount "$POOL_NAME")
    if [ "$PC_AFTER" = "1" ]; then
        _pass "getList — pathcount=1 after branch removal"
    else
        _fail "getList — expected pathcount=1 after removal, got '${PC_AFTER:-empty}'"
    fi

    # Removing the last remaining branch must be refused.
    assert_rpc_fails "removePath — last remaining branch rejected" "Mergerfs" "removePath" \
        "{\"uuid\":\"$POOL1_UUID\",\"path\":\"$BRANCH1\",\"deletesource\":false}"
else
    _fail "removePath — skipped (pool not mounted)"
fi

# ---------------------------------------------------------------------------
# Stress — multi-branch pool, hundreds of files, removePath data integrity
#
# Build a fresh 3-branch pool, write hundreds of files through the merged
# mount (mergerfs spreads them across the branches per the create policy),
# then remove one branch with the new removePath feature and verify every
# file is still readable through the pool with identical content (no loss).
# ---------------------------------------------------------------------------
section "Stress — multi-branch pool + bulk files + removePath integrity"

FILE_COUNT=300

# Relative-path + content-hash manifest for a directory tree. Reading content
# via stdin keeps the hash independent of the absolute path.
manifest() {
    find "$1" -type f -printf '%P\n' 2>/dev/null | sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(md5sum < "$1/$f" | cut -d' ' -f1)"
    done
}

# Tear down any stale mount left at this path by a previous aborted run.
# (mergerfs would otherwise stay mounted on now-deleted branches, and salt's
# restart is guarded by "if not is_mounted", so the new branches never apply.)
stop_pool_mount "$MNT2"

B2A=$(mktemp -d); B2B=$(mktemp -d); B2C=$(mktemp -d)
# Seed marker on a branch that survives removal so we can health-check the mount.
echo "seed" > "$B2A/.mgseed"
_pass "pool2 branch directories created: $B2A, $B2B, $B2C"

RESULT2=$(assert_rpc "set ($POOL2_NAME)" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '$POOL2_NAME',
    'paths': '${B2A}\n${B2B}\n${B2C}',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'rand', 'minfreespace': 1, 'minfreespaceunit': 'M',
    'options': 'defaults,cache.files=off',
}))")") || true

POOL2_UUID=$(echo "$RESULT2" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$POOL2_UUID" ] || [ "$POOL2_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "stress — failed to create $POOL2_NAME; skipping stress test"
else
    info "Deploying and mounting $POOL2_NAME ..."
    omv-salt deploy run mergerfs &>/dev/null || true
    UNIT2=$(systemd-escape --path --suffix=mount "$MNT2" 2>/dev/null || echo "")
    # Force a clean (re)mount with the current branch set rather than relying on
    # salt's is_mounted guard or a possibly stale mount.
    if [ -n "$UNIT2" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "$UNIT2" 2>/dev/null || true
    fi
    for i in $(seq 1 15); do
        mountpoint -q "$MNT2" 2>/dev/null && break
        sleep 2
    done

    if ! mountpoint -q "$MNT2" 2>/dev/null; then
        _fail "stress — $POOL2_NAME not mounted; skipping"
    elif [ ! -f "$MNT2/.mgseed" ]; then
        # Mounted, but mergerfs sees no valid branch (seed not visible). Fail
        # loudly with diagnostics instead of spewing hundreds of write errors.
        _fail "stress — $POOL2_NAME mounted but branches invalid; skipping" \
            "$(ls -la "$MNT2" 2>&1 | head -5)"
    else
        _pass "$POOL2_NAME mounted at $MNT2 (branches healthy)"

        # Write hundreds of files (plus a nested subdir) through the merged mount.
        mkdir -p "$MNT2/sub"
        for i in $(seq 1 $FILE_COUNT); do
            echo "mergerfs stress file $i $(date +%s%N)" > "$MNT2/file_${i}.txt"
        done
        for i in $(seq 1 20); do
            echo "nested $i" > "$MNT2/sub/nested_${i}.txt"
        done
        EXPECTED=$(find "$MNT2" -type f | wc -l)
        _pass "wrote $EXPECTED files through $POOL2_NAME"

        # Capture the pre-removal manifest (path + content hash).
        PRE_MANIFEST=$(manifest "$MNT2")

        # Confirm files actually spread onto the branch we are about to remove.
        CNT_A=$(find "$B2A" -type f | wc -l)
        CNT_B=$(find "$B2B" -type f | wc -l)
        CNT_C=$(find "$B2C" -type f | wc -l)
        info "Branch distribution: A=$CNT_A B=$CNT_B C=$CNT_C"
        if [ "$CNT_C" -gt 0 ]; then
            _pass "files distributed onto branch C ($CNT_C files to migrate)"
        else
            _fail "no files landed on branch C — cannot exercise migration"
        fi

        # Remove branch C; its files must migrate onto branches A/B.
        assert_rpc "removePath ($POOL2_NAME, branch C) — job dispatched" \
            "Mergerfs" "removePath" \
            "{\"uuid\":\"$POOL2_UUID\",\"path\":\"$B2C\",\"deletesource\":false}" >/dev/null

        # The merged view dips while C is detached and recovers as rsync copies
        # its files back in. Wait for the full count to return (and config to
        # drop branch C) before checking integrity.
        info "Waiting for removePath migration to complete (up to 180 s) ..."
        RECOVERED=false
        CURRENT=0
        for i in $(seq 1 90); do
            CURRENT=$(find "$MNT2" -type f 2>/dev/null | wc -l)
            if [ "$CURRENT" -eq "$EXPECTED" ] && ! pool_has_path "$POOL2_UUID" "$B2C"; then
                RECOVERED=true
                break
            fi
            sleep 2
        done

        if [ "$RECOVERED" = true ]; then
            _pass "all $EXPECTED files visible through pool after branch removal"
        else
            _fail "file count did not recover to $EXPECTED after 180 s (got $CURRENT)"
        fi

        # Branch C must be gone from the pool configuration.
        if pool_has_path "$POOL2_UUID" "$B2C"; then
            _fail "branch C still listed in pool config"
        else
            _pass "branch C removed from pool config"
        fi

        # Strongest check: the content manifest through the mount is unchanged.
        POST_MANIFEST=$(manifest "$MNT2")
        if [ "$PRE_MANIFEST" = "$POST_MANIFEST" ]; then
            _pass "data integrity — every file present with identical content"
        else
            DIFFC=$(diff <(echo "$PRE_MANIFEST") <(echo "$POST_MANIFEST") \
                | grep -c '^[<>]' || true)
            _fail "data integrity — manifest changed after migration ($DIFFC differing lines)"
        fi

        # The migrated files must physically reside on the remaining branches.
        if find "$B2A" "$B2B" -type f -name 'file_*.txt' 2>/dev/null | grep -q .; then
            _pass "migrated files present on remaining branches"
        else
            _fail "no migrated files found on branches A/B"
        fi

        # --- removePath while the pool is unmounted must be refused ---
        # The data is migrated through the pool mount, so removePath rejects
        # an unmounted pool up front, before the configuration is touched.
        if pool_has_path "$POOL2_UUID" "$B2B" && mountpoint -q "$MNT2" 2>/dev/null; then
            echo "unmounted marker" > "$B2B/.mgunmounted"
            stop_pool_mount "$MNT2"
            if mountpoint -q "$MNT2" 2>/dev/null; then
                _fail "unmounted — could not unmount $POOL2_NAME; skipping"
            else
                _pass "unmounted — $POOL2_NAME unmounted before removePath"
                assert_rpc_fails "removePath — unmounted pool rejected" \
                    "Mergerfs" "removePath" \
                    "{\"uuid\":\"$POOL2_UUID\",\"path\":\"$B2B\",\"deletesource\":false}"
                if pool_has_path "$POOL2_UUID" "$B2B"; then
                    _pass "unmounted — branch B still in pool config"
                else
                    _fail "unmounted — branch B removed from config although the call was rejected"
                fi
                if [ -f "$B2B/.mgunmounted" ] && [ ! -f "$B2A/.mgunmounted" ]; then
                    _pass "unmounted — no data was moved"
                else
                    _fail "unmounted — data was moved although the call was rejected"
                fi
            fi
        else
            _fail "unmounted — preconditions not met (branch B missing or pool unmounted)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# removePath — free-space pre-check and rollback on a failed migration
# ---------------------------------------------------------------------------
section "removePath — free-space pre-check and rollback"

stop_pool_mount "$MNT4"
B4A=$(mktemp -d); B4B=$(mktemp -d)
# "clash" is a directory on A and a regular file on B. Through the pool it is
# A's directory, so rsync cannot copy B's file over it and the migration fails.
mkdir -p "$B4A/clash"
echo "dir content" > "$B4A/clash/inner.txt"
echo "file content" > "$B4B/clash"
echo "rollback marker" > "$B4B/rbmarker.txt"
_pass "pool4 branch directories created: $B4A, $B4B"

RESULT4=$(assert_rpc "set ($POOL4_NAME)" "Mergerfs" "set" \
    "$(pool_params "$POOL4_NAME" "${B4A}"$'\n'"${B4B}" \
        '{"createpolicy": "ff", "minfreespace": 1, "minfreespaceunit": "M"}')") || true
POOL4_UUID=$(echo "$RESULT4" | json_uuid)
MNTENTREF4=$(echo "$RESULT4" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" 2>/dev/null || echo "")

# Re-save pool4 with a different minimum free space (an edit, not a create).
set_pool4_minfree() {
    rpc "Mergerfs" "set" "$(pool_params "$POOL4_NAME" "${B4A}"$'\n'"${B4B}" \
        "{\"uuid\": \"$POOL4_UUID\", \"mntentref\": \"$MNTENTREF4\", \"createpolicy\": \"ff\",
          \"minfreespace\": $1, \"minfreespaceunit\": \"$2\"}")" &>/dev/null
}

if [ -z "$POOL4_UUID" ] || [ "$POOL4_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "pool4 — failed to create $POOL4_NAME; skipping"
elif ! deploy_and_mount "$MNT4"; then
    _fail "pool4 — $POOL4_NAME not mounted; skipping"
elif [ ! -f "$MNT4/rbmarker.txt" ]; then
    _fail "pool4 — $POOL4_NAME mounted but branches invalid; skipping" \
        "$(ls -la "$MNT4" 2>&1 | head -5)"
else
    _pass "$POOL4_NAME mounted at $MNT4"

    # --- Free-space pre-check: with a huge minimum free space nothing fits,
    # so the job must fail before the configuration is changed.
    if set_pool4_minfree 99999 G; then
        FS_JOB=$(assert_rpc "removePath (min free space unreachable) — job dispatched" \
            "Mergerfs" "removePath" \
            "{\"uuid\":\"$POOL4_UUID\",\"path\":\"$B4B\",\"deletesource\":false}") || true
        if FS_OUT=$(wait_bgproc "$FS_JOB" 60); then
            if echo "$FS_OUT" | grep -q "Not enough free space"; then
                _pass "free-space — job refused for lack of space (minfreespace honoured)"
            else
                _fail "free-space — job did not report missing space" "${FS_OUT:0:300}"
            fi
        else
            _fail "free-space — job did not finish within 60 s"
        fi
        if pool_has_path "$POOL4_UUID" "$B4B"; then
            _pass "free-space — branch B still in pool config"
        else
            _fail "free-space — branch B removed although the space check failed"
        fi
        if [ -f "$MNT4/rbmarker.txt" ]; then
            _pass "free-space — branch B data still visible through the pool"
        else
            _fail "free-space — branch B data no longer visible through the pool"
        fi
        set_pool4_minfree 1 M || _fail "pool4 — could not reset minimum free space"
    else
        _fail "free-space — could not edit $POOL4_NAME"
    fi

    # --- Rollback: the migration fails after the branch was dropped, so the
    # branch must be restored in the config and on the live mount.
    RB_JOB=$(assert_rpc "removePath (migration will fail) — job dispatched" \
        "Mergerfs" "removePath" \
        "{\"uuid\":\"$POOL4_UUID\",\"path\":\"$B4B\",\"deletesource\":false}") || true
    if RB_OUT=$(wait_bgproc "$RB_JOB" 120); then
        if echo "$RB_OUT" | grep -q "the path was restored to the pool"; then
            _pass "rollback — failed migration triggered a restore"
        else
            _fail "rollback — no restore reported (did the migration unexpectedly succeed?)" \
                "${RB_OUT:0:300}"
        fi
        if echo "$RB_OUT" | grep -q "restoring it also failed"; then
            _fail "rollback — restore reported an error" "${RB_OUT:0:300}"
        fi
    else
        _fail "rollback — job did not finish within 120 s"
    fi
    if pool_has_path "$POOL4_UUID" "$B4B"; then
        _pass "rollback — branch B restored in pool config"
    else
        _fail "rollback — branch B missing from pool config after failed migration"
    fi
    for i in $(seq 1 10); do
        mountpoint -q "$MNT4" 2>/dev/null && [ -f "$MNT4/rbmarker.txt" ] && break
        sleep 1
    done
    if mountpoint -q "$MNT4" 2>/dev/null && [ -f "$MNT4/rbmarker.txt" ]; then
        _pass "rollback — branch B data visible through the pool again"
    else
        _fail "rollback — branch B data not visible through the pool"
    fi
    if [ -f "$B4B/rbmarker.txt" ] && [ -f "$B4B/clash" ]; then
        _pass "rollback — source files left on branch B"
    else
        _fail "rollback — files missing from branch B"
    fi
fi

# ---------------------------------------------------------------------------
# Integration — pool name containing dashes/dots: confirm saltstack renders
# the state, systemd escapes the mount unit correctly (\x2d for each literal
# dash), and the pool actually mounts and serves files end to end.
# ---------------------------------------------------------------------------
section "Integration — pool name with dashes (saltstack + systemd escaping)"

B3A=$(mktemp -d); B3B=$(mktemp -d)
echo "dash pool branch A" > "$B3A/seed_a.txt"
echo "dash pool branch B" > "$B3B/seed_b.txt"
_pass "pool3 branch directories created: $B3A, $B3B"

RESULT3=$(assert_rpc "set ($POOL3_NAME)" "Mergerfs" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '$POOL3_NAME',
    'paths': '${B3A}\n${B3B}',
    'sharedfolderrefs': [], 'filesystems': [],
    'createpolicy': 'mfs', 'minfreespace': 4, 'minfreespaceunit': 'G',
    'options': 'defaults,cache.files=off',
}))")") || true

POOL3_UUID=$(echo "$RESULT3" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$POOL3_UUID" ] || [ "$POOL3_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "dash-name — failed to create $POOL3_NAME; skipping"
else
    # The expected systemd escaping: each literal "-" becomes "\x2d" and "."
    # is left unescaped (systemd's escape table treats '.' as safe).
    UNIT3=$(systemd-escape --path --suffix=mount "$MNT3" 2>/dev/null || echo "")
    if [[ "$UNIT3" == *'\x2d'* ]]; then
        _pass "systemd-escape produces \\x2d-escaped unit name: $UNIT3"
    else
        _fail "systemd-escape did not escape dashes as expected" "got: $UNIT3"
    fi

    info "Running omv-salt deploy run mergerfs (dash-name pool) ..."
    if omv-salt deploy run mergerfs &>/dev/null; then
        _pass "omv-salt deploy — dash-name pool (no exception)"
    else
        _fail "omv-salt deploy — dash-name pool"
    fi

    UNIT3_FILE="/etc/systemd/system/${UNIT3}"
    if [ -f "$UNIT3_FILE" ]; then
        _pass "unit file created: $UNIT3_FILE"
    else
        _fail "unit file missing: $UNIT3_FILE"
    fi

    # If salt didn't start the mount, try once manually via systemctl.
    if ! mountpoint -q "$MNT3" 2>/dev/null && [ -f "$UNIT3_FILE" ]; then
        info "Mount not active after salt — attempting manual systemctl start ..."
        systemctl daemon-reload 2>/dev/null || true
        systemctl start "$UNIT3" 2>/dev/null || true
        sleep 3
    fi

    info "Waiting for dash-name pool to mount (up to 30 s) ..."
    for i in $(seq 1 15); do
        mountpoint -q "$MNT3" 2>/dev/null && break
        sleep 2
    done

    if mountpoint -q "$MNT3" 2>/dev/null; then
        _pass "$POOL3_NAME mounted at $MNT3"

        if [ -f "$MNT3/seed_a.txt" ] && [ -f "$MNT3/seed_b.txt" ]; then
            _pass "merged view shows files from both branches"
        else
            _fail "merged view missing seed file(s)" "$(ls -la "$MNT3" 2>&1)"
        fi

        echo "written through dash-name pool" > "$MNT3/dashwrite.txt"
        if [ -f "$B3A/dashwrite.txt" ] || [ -f "$B3B/dashwrite.txt" ]; then
            _pass "write through dash-name pool landed on a branch"
        else
            _fail "write through dash-name pool did not appear on any branch"
        fi

        # restartPool RPC exercises the same salt render + systemctl restart
        # path used by the UI's restart action, again with the dashed name.
        assert_rpc "restartPool — dash-name pool, no exception" "Mergerfs" "restartPool" \
            "{\"uuid\":\"$POOL3_UUID\"}" >/dev/null
        info "Waiting for dash-name pool to remount after restart (up to 20 s) ..."
        for i in $(seq 1 10); do
            mountpoint -q "$MNT3" 2>/dev/null && break
            sleep 2
        done
        if mountpoint -q "$MNT3" 2>/dev/null; then
            _pass "dash-name pool remounted after restartPool"
        else
            _fail "dash-name pool not remounted after restartPool"
        fi

        # Deleting a pool and applying the change must unmount it and remove
        # its unit, even when it was the last pool using that unit.
        assert_rpc "delete ($POOL3_NAME)" "Mergerfs" "delete" \
            "{\"uuid\":\"$POOL3_UUID\"}" >/dev/null && POOL3_UUID=""
        omv-salt deploy run mergerfs &>/dev/null || true
        if mountpoint -q "$MNT3" 2>/dev/null; then
            _fail "delete — $POOL3_NAME still mounted after deploy"
        else
            _pass "delete — $POOL3_NAME unmounted after deploy"
        fi
        if [ -f "$UNIT3_FILE" ]; then
            _fail "delete — unit file still present: $UNIT3_FILE"
        else
            _pass "delete — unit file removed"
        fi
        if [ "$(systemctl show -P LoadState "$UNIT3" 2>/dev/null)" = "loaded" ] \
            && [ "$(systemctl show -P FragmentPath "$UNIT3" 2>/dev/null)" = "$UNIT3_FILE" ]; then
            _fail "delete — systemd still loads the removed unit (no daemon-reload)"
        else
            _pass "delete — systemd reloaded, removed unit no longer loaded from disk"
        fi
    else
        _fail "$POOL3_NAME not mounted at $MNT3 after 30 s"
        if [ -n "$UNIT3" ]; then
            info "Journal for $UNIT3 (last 20 lines):"
            journalctl -u "$UNIT3" -n 20 --no-pager 2>/dev/null >&2 || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Regression — ShareMgmt::getCandidates must not throw with active pool
# ---------------------------------------------------------------------------
section "Regression — ShareMgmt::getCandidates with active pool"

assert_rpc "ShareMgmt getCandidates — no exception with active pool" \
    "ShareMgmt" "getCandidates" '{}' >/dev/null

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS + FAIL))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} (${TOTAL} total)" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done
fi
echo >&2

[ $FAIL -eq 0 ] && exit 0 || exit 1
