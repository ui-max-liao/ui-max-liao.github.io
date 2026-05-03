#!/bin/bash
# TC-02: Setup VLANs on USW-Flex for config survival test

DUT=10.10.10.60
DUT_USER=xUvAEdEyt
DUT_PASS=fgRcR60SO5oceRUBe9qu
JUMP_IP=10.10.8.1
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"

run_ssh() {
    sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$DUT" "$@" 2>/dev/null
}

echo '=============================================='
echo 'TC-02: Config Survivability Setup'
echo '=============================================='
echo "DUT: USW-Flex $DUT (7.4.1)"
echo "Start: $(date)"
echo ''

# Step 1: Capture baseline
echo '--- Step 1: Baseline ---'
BASELINE_FW=$(run_ssh 'cat /lib/version')
echo "  FW: $BASELINE_FW"
run_ssh 'cat /tmp/system.cfg' > /tmp/tc02_flex_baseline.cfg
echo "  Baseline config: $(wc -l < /tmp/tc02_flex_baseline.cfg) lines"
echo ''

# Step 2: Add VLANs to system.cfg
echo '--- Step 2: Add VLANs ---'
# Create a patch script on the device
run_ssh 'cat > /tmp/add_vlans.sh' << 'REMOTE_SCRIPT'
#!/bin/sh
cp /tmp/system.cfg /tmp/system.cfg.bak

# Remove any existing TC-02 test config
sed -i '/TC-02/d' /tmp/system.cfg

# Append VLAN config
cat >> /tmp/system.cfg << 'EOF'
switch.vlan.100.id=100
switch.vlan.100.mode=tagged
switch.vlan.100.status=enabled
switch.vlan.200.id=200
switch.vlan.200.mode=tagged
switch.vlan.200.status=enabled
switch.vlan.300.id=300
switch.vlan.300.mode=tagged
switch.vlan.300.status=enabled
switch.vlan.999.id=999
switch.vlan.999.mode=tagged
switch.vlan.999.status=enabled
switch.port.1.pvid=100
switch.port.2.pvid=200
switch.port.3.pvid=300
EOF

echo "Done - VLANs added"
grep "vlan\." /tmp/system.cfg
grep "pvid" /tmp/system.cfg
REMOTE_SCRIPT

run_ssh 'chmod +x /tmp/add_vlans.sh && /tmp/add_vlans.sh'
echo ''

# Step 3: Save to persistent storage
echo '--- Step 3: Save to flash ---'
run_ssh 'cfgmtd -w -p /etc 2>&1; echo "cfgmtd exit: $?"'
echo ''

# Step 4: Capture pre-upgrade config
echo '--- Step 4: Pre-upgrade config ---'
run_ssh 'cat /tmp/system.cfg' > /tmp/tc02_flex_pre_upgrade.cfg
VLAN_COUNT=$(grep -c 'vlan\.' /tmp/tc02_flex_pre_upgrade.cfg)
PVID_COUNT=$(grep -c 'pvid' /tmp/tc02_flex_pre_upgrade.cfg)
echo "  Config: $(wc -l < /tmp/tc02_flex_pre_upgrade.cfg) lines"
echo "  VLAN entries: $VLAN_COUNT"
echo "  PVID entries: $PVID_COUNT"
echo ''

# Step 5: Delete VLAN 999 from system.cfg (for TC-02.2 resurrection test)
echo '--- Step 5: Delete VLAN 999 (resurrection test) ---'
run_ssh 'sed -i "/vlan\.999/d" /tmp/system.cfg; cfgmtd -w -p /etc 2>/dev/null'
run_ssh 'grep "vlan\.999" /tmp/system.cfg && echo "VLAN 999 still present" || echo "VLAN 999 deleted"'
echo ''

# Save the final pre-upgrade config (with 999 deleted)
run_ssh 'cat /tmp/system.cfg' > /tmp/tc02_flex_pre_upgrade_final.cfg
echo "  Final pre-upgrade config: $(wc -l < /tmp/tc02_flex_pre_upgrade_final.cfg) lines"
echo ''

# Step 6: Upgrade to 7.5.0
echo '--- Step 6: Upgrade to 7.5.0 ---'
echo "  Downloading firmware..."
run_ssh "cd /tmp && rm -f fwupdate.bin && curl -s -o fwupdate.bin http://${JUMP_IP}:9999/fw_US_mt7621.bin && echo OK"
DL_SIZE=$(run_ssh 'stat -c%s /tmp/fwupdate.bin 2>/dev/null')
echo "  Downloaded: $DL_SIZE bytes"

echo "  Validating..."
run_ssh '/sbin/fwupdate.real -c' | sed 's/^/    /'

echo "  Flashing firmware..."
run_ssh '/sbin/fwupdate.real -m /tmp/fwupdate.bin &'
sleep 5

echo ''
echo '--- Step 7: Monitor recovery ---'
UPGRADE_TS=$(date +%s)

# Wait for reboot
echo '  Waiting for reboot...'
while ping -c1 -W1 $DUT >/dev/null 2>&1; do
    sleep 1
done
DOWN_TS=$(date +%s)
echo "  Device DOWN at $((DOWN_TS - UPGRADE_TS))s"

# Wait for recovery
echo '  Waiting for recovery...'
while ! ping -c1 -W1 $DUT >/dev/null 2>&1; do
    sleep 1
done
UP_TS=$(date +%s)
echo "  Device UP at $((UP_TS - UPGRADE_TS))s (downtime: $((UP_TS - DOWN_TS))s)"

ssh-keygen -f /root/.ssh/known_hosts -R $DUT >/dev/null 2>&1

# Wait for SSH
echo '  Waiting for SSH...'
for i in $(seq 1 30); do
    if run_ssh 'echo ok' >/dev/null 2>&1; then break; fi
    sleep 2
done

# Step 8: Capture post-upgrade config IMMEDIATELY (before controller reprovisions)
echo ''
echo '--- Step 8: Post-upgrade config (pre-controller) ---'
NEW_FW=$(run_ssh 'cat /lib/version')
echo "  New FW: $NEW_FW"

run_ssh 'cat /tmp/system.cfg' > /tmp/tc02_flex_post_upgrade.cfg
echo "  Post-upgrade config: $(wc -l < /tmp/tc02_flex_post_upgrade.cfg) lines"

# Check VLAN survival
echo ''
echo '--- Step 9: VLAN Survival Check ---'
echo '  VLANs in post-upgrade config:'
grep 'vlan\.' /tmp/tc02_flex_post_upgrade.cfg | sed 's/^/    /'
echo '  PVIDs in post-upgrade config:'
grep 'pvid' /tmp/tc02_flex_post_upgrade.cfg | sed 's/^/    /'

# TC-02.1: Management VLAN preserved
echo ''
echo '--- TC-02.1: Management VLAN ---'
PRE_MGMT=$(grep 'managementvlan' /tmp/tc02_flex_pre_upgrade_final.cfg)
POST_MGMT=$(grep 'managementvlan' /tmp/tc02_flex_post_upgrade.cfg)
echo "  Pre:  $PRE_MGMT"
echo "  Post: $POST_MGMT"
if [ "$PRE_MGMT" = "$POST_MGMT" ]; then
    echo "  RESULT: PASS - Management VLAN preserved"
else
    echo "  RESULT: FAIL - Management VLAN changed"
fi

# TC-02.2: Deleted VLAN 999 should NOT resurrect
echo ''
echo '--- TC-02.2: Deleted VLAN resurrection ---'
if grep -q 'vlan\.999' /tmp/tc02_flex_post_upgrade.cfg; then
    echo "  RESULT: FAIL - VLAN 999 resurrected!"
else
    echo "  RESULT: PASS - VLAN 999 stayed deleted"
fi

# TC-02.6/02.7: Config diff
echo ''
echo '--- TC-02.7: Config diff ---'
diff /tmp/tc02_flex_pre_upgrade_final.cfg /tmp/tc02_flex_post_upgrade.cfg > /tmp/tc02_flex_diff.txt 2>&1
DIFF_LINES=$(wc -l < /tmp/tc02_flex_diff.txt)
if [ "$DIFF_LINES" -eq 0 ]; then
    echo "  RESULT: PASS - Config identical"
else
    echo "  RESULT: DIFF detected ($DIFF_LINES lines):"
    cat /tmp/tc02_flex_diff.txt | head -30 | sed 's/^/    /'
fi

echo ''
echo '=============================================='
echo 'TC-02 COMPLETE'
echo "End: $(date)"
echo '=============================================='
