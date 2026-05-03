#!/bin/bash
# TC-01.3 (Modified): PoE recovery timing during upgrade
# NOTE: PoE budget is only ~8% (32W/400W), not 80% as required by test plan
# Testing PoE resume timing with available load

DUT=10.10.9.119
DUT_USER=xUvAEdEyt
DUT_PASS=fgRcR60SO5oceRUBe9qu
JUMP_IP=10.10.8.1
FW_FILE=fw_US_bcm5616x.bin
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"

run_ssh() {
    sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$DUT" "$@" 2>/dev/null
}

echo '=============================================='
echo 'TC-01.3 (Modified): PoE Recovery After Upgrade'
echo '=============================================='
echo "Start: $(date)"
echo "DUT: USW-Enterprise-24-PoE #2 $DUT"
echo 'NOTE: PoE budget ~8%, test plan requires >=80%'
echo '      Testing PoE resume mechanism with available load'
echo ''

# Step 1: Baseline
echo '--- Step 1: Baseline ---'
BASELINE_FW=$(run_ssh 'cat /lib/version')
echo "  FW: $BASELINE_FW"
echo '  PoE ports powered before upgrade:'
run_ssh 'swctrl poe show | grep "On"' | sed 's/^/    /'
POE_PORTS_BEFORE=$(run_ssh 'swctrl poe show | grep -c "On"')
echo "  PoE ports powered count: $POE_PORTS_BEFORE"
echo ''

# Step 2: Trigger firmware upgrade
echo '--- Step 2: Firmware upgrade ---'
echo "  Downloading $FW_FILE to DUT..."
run_ssh "cd /tmp && rm -f fwupdate.bin && curl -s -o fwupdate.bin http://${JUMP_IP}:9999/${FW_FILE} && echo DL_OK"
DL_SIZE=$(run_ssh 'stat -c%s /tmp/fwupdate.bin 2>/dev/null')
echo "  Downloaded: $DL_SIZE bytes"

echo '  Validating...'
run_ssh '/sbin/fwupdate.real -c' | sed 's/^/    /'

echo '  Starting upgrade (will reboot)...'
run_ssh 'nohup syswrapper.sh fwupdate /tmp/fwupdate.bin &>/dev/null &'

echo ''
echo '--- Step 3: Monitoring recovery ---'
UPGRADE_TS=$(date +%s)

# Wait for device to go down
echo '  Waiting for reboot...'
while ping -c1 -W1 $DUT >/dev/null 2>&1; do
    sleep 1
done
DOWN_TS=$(date +%s)
echo "  Device DOWN at $((DOWN_TS - UPGRADE_TS))s"

# Wait for device to come back
echo '  Waiting for recovery...'
while ! ping -c1 -W1 $DUT >/dev/null 2>&1; do
    sleep 1
done
UP_TS=$(date +%s)
echo "  Device UP (ping) at $((UP_TS - UPGRADE_TS))s (downtime: $((UP_TS - DOWN_TS))s)"

# Clear known hosts for new key
ssh-keygen -f /root/.ssh/known_hosts -R $DUT >/dev/null 2>&1

# Wait for SSH
echo '  Waiting for SSH...'
for i in $(seq 1 30); do
    if run_ssh 'echo ok' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
SSH_TS=$(date +%s)
echo "  SSH ready at $((SSH_TS - UPGRADE_TS))s"

# Step 4: Check PoE recovery
echo ''
echo '--- Step 4: PoE recovery check ---'
NEW_FW=$(run_ssh 'cat /lib/version')
echo "  New FW: $NEW_FW"

# Poll PoE status every 2 seconds for up to 60 seconds
POE_RECOVERED=0
POE_TS=0
for i in $(seq 1 30); do
    POE_NOW=$(run_ssh 'swctrl poe show | grep -c "On"')
    NOW_TS=$(date +%s)
    ELAPSED=$((NOW_TS - UP_TS))
    echo "  [${ELAPSED}s post-up] PoE ports powered: ${POE_NOW:-0}/$POE_PORTS_BEFORE"
    if [ "${POE_NOW:-0}" -ge "$POE_PORTS_BEFORE" ] 2>/dev/null; then
        POE_RECOVERED=1
        POE_TS=$NOW_TS
        echo "  PoE RECOVERED at $((POE_TS - UP_TS))s after ping-up, $((POE_TS - UPGRADE_TS))s total"
        break
    fi
    sleep 2
done

echo ''
echo '--- Step 5: Final PoE status ---'
run_ssh 'swctrl poe show | grep "On"' | sed 's/^/  /'

echo ''
if [ $POE_RECOVERED -eq 1 ]; then
    POE_RESUME=$((POE_TS - UP_TS))
    if [ $POE_RESUME -le 30 ]; then
        echo "RESULT: PASS - PoE resumed in ${POE_RESUME}s (<=30s) after device up"
    else
        echo "RESULT: FAIL - PoE resumed in ${POE_RESUME}s (>30s) after device up"
    fi
else
    echo "RESULT: FAIL - PoE did not recover within 60s"
fi

echo ''
echo '=============================================='
echo 'TC-01.3 COMPLETE'
echo "End: $(date)"
echo '=============================================='
