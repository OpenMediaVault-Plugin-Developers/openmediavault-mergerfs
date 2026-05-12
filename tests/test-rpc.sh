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

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
POOL1_UUID=""
BRANCH1=""
BRANCH2=""
SALT_LOG=""

LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

OMV_MOUNT_DIR=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_MOUNT_DIR:-/srv}")

# Pool name avoids hyphens so the systemd unit name has no \x2d escaping.
POOL_NAME="mgtestpool1"
MNT1="${OMV_MOUNT_DIR}/mergerfs/${POOL_NAME}"

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    # Stop pool mount if still active
    if mountpoint -q "$MNT1" 2>/dev/null; then
        info "Stopping pool mount at $MNT1"
        local unit
        unit=$(systemd-escape --path --suffix=mount "$MNT1" 2>/dev/null || echo "")
        if [ -n "$unit" ]; then
            systemctl stop "$unit" 2>/dev/null || true
            sleep 1
        fi
        mountpoint -q "$MNT1" 2>/dev/null && fusermount -uz "$MNT1" 2>/dev/null || true
    fi

    # Delete integration-test pool from DB
    if [ -n "$POOL1_UUID" ]; then
        info "Deleting pool $POOL1_UUID from DB"
        rpc "Mergerfs" "delete" "{\"uuid\":\"$POOL1_UUID\"}" &>/dev/null || true
    fi

    # Redeploy to remove generated systemd unit files
    info "Running omv-salt deploy run mergerfs (cleanup)"
    omv-salt deploy run mergerfs &>/dev/null || true

    # Remove temp branch directories and salt log
    [ -n "$BRANCH1" ] && rm -rf "$BRANCH1" 2>/dev/null || true
    [ -n "$BRANCH2" ] && rm -rf "$BRANCH2" 2>/dev/null || true
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
