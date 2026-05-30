#!/usr/bin/env bash
# diag-mergerfs.sh — diagnose why a fresh 3-branch mergerfs pool mounts with
# "no valid mergerfs branch found". Creates one temp pool, deploys it, dumps
# the generated systemd unit + mount state + mergerfs journal, then cleans up.
#
# Usage: sudo bash tests/diag-mergerfs.sh
set -u

OMV_NEW_UUID=$(. /etc/default/openmediavault; echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")
LOG=$(mktemp /var/log/mgdiag.XXXXXX.log 2>/dev/null || mktemp)

D1=$(mktemp -d); D2=$(mktemp -d); D3=$(mktemp -d)
echo "seed1" > "$D1/seed1.txt"
echo "seed2" > "$D2/seed2.txt"
echo "branches:"
echo "  D1=$D1"
echo "  D2=$D2"
echo "  D3=$D3"

PARAMS=$(python3 -c "import json,sys; d1,d2,d3=sys.argv[1:4]; print(json.dumps({'uuid':'$OMV_NEW_UUID','mntentref':'$OMV_NEW_UUID','name':'mgdiagpool','paths':d1+chr(10)+d2+chr(10)+d3,'sharedfolderrefs':[],'filesystems':[],'createpolicy':'rand','minfreespace':1,'minfreespaceunit':'M','options':'defaults,cache.files=off'}))" "$D1" "$D2" "$D3")

echo "=== set RPC ==="
RES=$(omv-rpc -u admin Mergerfs set "$PARAMS")
echo "$RES"
UUID=$(echo "$RES" | python3 -c "import sys,json;print(json.load(sys.stdin).get('uuid',''))")
echo "pool uuid: $UUID"

echo "=== stored config (Mergerfs get) ==="
omv-rpc -u admin Mergerfs get "{\"uuid\":\"$UUID\"}" 2>&1

echo "=== omv-salt deploy ==="
omv-salt deploy run mergerfs > "$LOG" 2>&1; echo "salt rc=$?"

MNT="/srv/mergerfs/mgdiagpool"
UNIT=$(systemd-escape --path --suffix=mount "$MNT")

echo "=== generated unit: /etc/systemd/system/$UNIT ==="
cat "/etc/systemd/system/$UNIT" 2>&1

echo "=== systemctl status ==="
systemctl --no-pager status "$UNIT" 2>&1 | head -20

echo "=== journal for unit (mergerfs stderr) ==="
journalctl -u "$UNIT" -n 30 --no-pager 2>&1

echo "=== mountpoint / findmnt ==="
mountpoint "$MNT" 2>&1
findmnt "$MNT" 2>&1

echo "=== ls mount ==="
ls -la "$MNT" 2>&1

echo "=== mergerfs runtime branches xattr ==="
getfattr -n user.mergerfs.branches "$MNT" 2>&1 || true

echo "=== salt log tail ==="
tail -40 "$LOG"

echo "=== cleanup ==="
if mountpoint -q "$MNT" 2>/dev/null; then
    systemctl stop "$UNIT" 2>/dev/null || true
    sleep 1
    mountpoint -q "$MNT" && fusermount -uz "$MNT" 2>/dev/null || true
fi
[ -n "$UUID" ] && omv-rpc -u admin Mergerfs delete "{\"uuid\":\"$UUID\"}" >/dev/null 2>&1 || true
omv-salt deploy run mergerfs >/dev/null 2>&1 || true
rm -rf "$D1" "$D2" "$D3" "$LOG"
echo done
