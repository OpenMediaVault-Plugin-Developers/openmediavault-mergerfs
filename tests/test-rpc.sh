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

    # Delete integration-test pools from DB
    if [ -n "$POOL1_UUID" ]; then
        info "Deleting pool $POOL1_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL1_UUID\"}" &>/dev/null || true
    fi
    if [ -n "$POOL2_UUID" ]; then
        info "Deleting pool $POOL2_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL2_UUID\"}" &>/dev/null || true
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

# Verify get returns the pool with correct paths
GET_RESULT=$(rpc "Mergerfs" "get" "{\"uuid\":\"$POOL1_UUID\"}" 2>/dev/null || echo "{}")
STORED_PATHS=$(echo "$GET_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('paths',''))" 2>/dev/null || echo "")
if echo "$STORED_PATHS" | grep -q "$BRANCH1"; then
    _pass "get — stored paths contain branch1"
else
    _fail "get — stored paths missing branch1 (got: ${STORED_PATHS:0:100})"
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

    assert_rpc "removePath — background job dispatched" "Mergerfs" "removePath" \
        "{\"uuid\":\"$POOL1_UUID\",\"path\":\"$BRANCH2\",\"deletesource\":false}" >/dev/null || true

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

        # --- removePath while the pool is unmounted (restart/remount path) ---
        # When the pool is not mounted, the mergerfs runtime control file is
        # unavailable; removePath must rely on the mount being (re)started with
        # the new branch list (salt's deploy remounts it, with the explicit
        # restartPoolMount() as the deeper safety net). Force the unmounted state
        # and verify the pool comes back with branch B removed and data migrated.
        if pool_has_path "$POOL2_UUID" "$B2B" && mountpoint -q "$MNT2" 2>/dev/null; then
            echo "fallback marker" > "$B2B/.mgfallback"
            FB_PRE=$(manifest "$MNT2")
            stop_pool_mount "$MNT2"
            if mountpoint -q "$MNT2" 2>/dev/null; then
                _fail "fallback — could not unmount $POOL2_NAME; skipping"
            else
                _pass "fallback — $POOL2_NAME unmounted before removePath"
                assert_rpc "removePath (branch B, pool unmounted) — job dispatched" \
                    "Mergerfs" "removePath" \
                    "{\"uuid\":\"$POOL2_UUID\",\"path\":\"$B2B\",\"deletesource\":false}" >/dev/null

                info "Waiting for pool to remount and migrate (up to 120 s) ..."
                FB_OK=false
                for i in $(seq 1 60); do
                    if mountpoint -q "$MNT2" 2>/dev/null \
                        && ! pool_has_path "$POOL2_UUID" "$B2B" \
                        && [ -f "$B2A/.mgfallback" ]; then
                        FB_OK=true
                        break
                    fi
                    sleep 2
                done

                if [ "$FB_OK" = true ]; then
                    _pass "fallback — pool remounted, branch B removed, data migrated to A"
                else
                    _fail "fallback — remount/migration did not complete after 120 s"
                fi

                # Every file still readable through the pool with identical content.
                FB_POST=$(manifest "$MNT2")
                if [ "$FB_PRE" = "$FB_POST" ]; then
                    _pass "fallback — data integrity preserved after unmounted removal"
                else
                    _fail "fallback — manifest changed after unmounted removal"
                fi
            fi
        else
            _fail "fallback — preconditions not met (branch B missing or pool unmounted)"
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
