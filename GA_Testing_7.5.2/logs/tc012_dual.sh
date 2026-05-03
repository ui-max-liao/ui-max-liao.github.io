#!/bin/bash
# TC-01.2: Dual-device upgrade with SFP+ DAC
# USW-Pro-Aggregation (10.10.8.168) port 32 <-- DAC-SFP28-1M --> port 51 ECS-48S (10.10.11.36)

AGG_IP=10.10.8.168
ECS_IP=10.10.11.36
DUT_USER=xUvAEdEyt
DUT_PASS=fgRcR60SO5oceRUBe9qu
JUMP_IP=10.10.8.1
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"

ssh_cmd() {
    sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$1" "$2" 2>/dev/null
}

echo '=============================================='
echo 'TC-01.2: Dual-Device Upgrade with SFP+ DAC'
echo '=============================================='
echo "Start: $(date)"
echo "AGG: USW-Pro-Aggregation $AGG_IP (bcm5617x)"
echo "ECS: ECS-48S $ECS_IP (mvac5)"
echo "DAC Link: AGG port 32 <-> ECS port 51 (25G DAC-SFP28-1M)"
echo ''

# Step 1: Baseline
echo '--- Step 1: Baseline ---'
AGG_FW=$(ssh_cmd $AGG_IP 'cat /lib/version')
ECS_FW=$(ssh_cmd $ECS_IP 'cat /lib/version')
echo "  AGG FW: $AGG_FW"
echo "  ECS FW: $ECS_FW"

# Check DAC link status
AGG_PORT32=$(ssh_cmd $AGG_IP 'swctrl port show | grep "^.U32\|^ U32\|^  32"')
ECS_PORT51=$(ssh_cmd $ECS_IP 'swctrl port show | grep "^ *51"')
echo "  AGG port 32: $(echo $AGG_PORT32 | awk '{print $2, $3}')"
echo "  ECS port 51: $(echo $ECS_PORT51 | awk '{print $2, $3}')"
echo ''

# Step 2: Download firmware to both DUTs
echo '--- Step 2: Download firmware ---'
echo '  Downloading to AGG...'
ssh_cmd $AGG_IP "cd /tmp && rm -f fwupdate.bin && curl -s -o fwupdate.bin http://${JUMP_IP}:9999/fw_US_bcm5617x.bin && echo OK"
AGG_DL=$(ssh_cmd $AGG_IP 'stat -c%s /tmp/fwupdate.bin 2>/dev/null')
echo "  AGG: $AGG_DL bytes"

echo '  Downloading to ECS...'
ssh_cmd $ECS_IP "cd /tmp && rm -f fwupdate.bin && curl -s -o fwupdate.bin http://${JUMP_IP}:9999/fw_EAS_mvac5.bin && echo OK"
ECS_DL=$(ssh_cmd $ECS_IP 'stat -c%s /tmp/fwupdate.bin 2>/dev/null')
echo "  ECS: $ECS_DL bytes"

# Validate both
echo '  Validating AGG firmware...'
ssh_cmd $AGG_IP '/sbin/fwupdate.real -c' | sed 's/^/    /'
echo '  Validating ECS firmware...'
ssh_cmd $ECS_IP '/sbin/fwupdate.real -c' | sed 's/^/    /'
echo ''

# Step 3: Trigger simultaneous upgrade
echo '--- Step 3: Simultaneous upgrade ---'
echo "  Triggering at $(date)"
UPGRADE_TS=$(date +%s)

# Trigger both in rapid succession
ssh_cmd $AGG_IP '/sbin/fwupdate.real -m /tmp/fwupdate.bin &' &
ssh_cmd $ECS_IP '/sbin/fwupdate.real -m /tmp/fwupdate.bin &' &
echo '  Both upgrades triggered'
echo ''

# Step 4: Monitor recovery
echo '--- Step 4: Monitor recovery ---'

# Wait for both to go down
AGG_DOWN=0
ECS_DOWN=0
echo '  Waiting for reboots...'
for i in $(seq 1 300); do
    if [ $AGG_DOWN -eq 0 ] && ! ping -c1 -W1 $AGG_IP >/dev/null 2>&1; then
        AGG_DOWN=$(date +%s)
        echo "  AGG DOWN at $((AGG_DOWN - UPGRADE_TS))s"
    fi
    if [ $ECS_DOWN -eq 0 ] && ! ping -c1 -W1 $ECS_IP >/dev/null 2>&1; then
        ECS_DOWN=$(date +%s)
        echo "  ECS DOWN at $((ECS_DOWN - UPGRADE_TS))s"
    fi
    if [ $AGG_DOWN -ne 0 ] && [ $ECS_DOWN -ne 0 ]; then
        break
    fi
    sleep 1
done

# Wait for both to come back
AGG_UP=0
ECS_UP=0
echo '  Waiting for recovery...'
for i in $(seq 1 300); do
    if [ $AGG_UP -eq 0 ] && ping -c1 -W1 $AGG_IP >/dev/null 2>&1; then
        AGG_UP=$(date +%s)
        echo "  AGG UP at $((AGG_UP - UPGRADE_TS))s (downtime: $((AGG_UP - AGG_DOWN))s)"
    fi
    if [ $ECS_UP -eq 0 ] && ping -c1 -W1 $ECS_IP >/dev/null 2>&1; then
        ECS_UP=$(date +%s)
        echo "  ECS UP at $((ECS_UP - UPGRADE_TS))s (downtime: $((ECS_UP - ECS_DOWN))s)"
    fi
    if [ $AGG_UP -ne 0 ] && [ $ECS_UP -ne 0 ]; then
        break
    fi
    sleep 1
done

# Clear known hosts
ssh-keygen -f /root/.ssh/known_hosts -R $AGG_IP >/dev/null 2>&1
ssh-keygen -f /root/.ssh/known_hosts -R $ECS_IP >/dev/null 2>&1

# Wait for SSH on both
echo '  Waiting for SSH...'
for i in $(seq 1 60); do
    AGG_SSH=$(ssh_cmd $AGG_IP 'echo ok' 2>/dev/null)
    ECS_SSH=$(ssh_cmd $ECS_IP 'echo ok' 2>/dev/null)
    if [ "$AGG_SSH" = "ok" ] && [ "$ECS_SSH" = "ok" ]; then
        break
    fi
    sleep 2
done
SSH_TS=$(date +%s)
echo "  Both SSH ready at $((SSH_TS - UPGRADE_TS))s"
echo ''

# Step 5: Verify upgrade and DAC link
echo '--- Step 5: Post-upgrade verification ---'
NEW_AGG_FW=$(ssh_cmd $AGG_IP 'cat /lib/version')
NEW_ECS_FW=$(ssh_cmd $ECS_IP 'cat /lib/version')
echo "  AGG FW: $NEW_AGG_FW"
echo "  ECS FW: $NEW_ECS_FW"

# Check DAC link
echo ''
echo '  DAC link status:'
for i in $(seq 1 15); do
    AGG_P32=$(ssh_cmd $AGG_IP 'swctrl port show | grep "U32\|^ *32"' | awk '{print $2, $3}')
    ECS_P51=$(ssh_cmd $ECS_IP 'swctrl port show | grep "^ *51"' | awk '{print $2, $3}')
    NOW=$(($(date +%s) - UPGRADE_TS))
    echo "  [${NOW}s] AGG-32: $AGG_P32 | ECS-51: $ECS_P51"
    if echo "$AGG_P32" | grep -q "U/U" && echo "$ECS_P51" | grep -q "U/U"; then
        DAC_UP_TS=$(date +%s)
        echo "  DAC link UP at $((DAC_UP_TS - UPGRADE_TS))s"
        break
    fi
    sleep 2
done

# LLDP verification
echo ''
echo '  LLDP neighbors:'
echo '  AGG:'
ssh_cmd $AGG_IP 'swctrl lldp show' | grep '32' | sed 's/^/    /'
echo '  ECS:'
ssh_cmd $ECS_IP 'swctrl lldp show' | grep '51' | sed 's/^/    /'

echo ''
echo '--- Results ---'
echo "  AGG: $AGG_FW -> $NEW_AGG_FW"
echo "  ECS: $ECS_FW -> $NEW_ECS_FW"

AGG_OK=0
ECS_OK=0
[ "$NEW_AGG_FW" != "$AGG_FW" ] && AGG_OK=1
[ "$NEW_ECS_FW" != "$ECS_FW" ] && ECS_OK=1

if [ $AGG_OK -eq 1 ] && [ $ECS_OK -eq 1 ]; then
    echo "  Both upgraded: PASS"
else
    echo "  Upgrade: FAIL (AGG=$AGG_OK, ECS=$ECS_OK)"
fi

echo ''
echo '=============================================='
echo 'TC-01.2 COMPLETE'
echo "End: $(date)"
echo '=============================================='
