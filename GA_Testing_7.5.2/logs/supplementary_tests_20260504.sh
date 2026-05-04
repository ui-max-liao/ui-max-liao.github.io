#!/bin/bash
DUT_USER=ubiquiti
DUT_PASS="Ubiquiti@12341"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"
ssh_cmd() { sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$1" "$2" 2>/dev/null; }

echo '================================================================'
echo ' Supplementary Tests: GA_01 + TS-07 AP Adoption'
echo " Start: $(date)"
echo '================================================================'

########################################################################
# PART 1: GA_01 (USW Lite 8 PoE, 10.10.10.73) — Full TS-01~TS-10
########################################################################
GA01_IP=10.10.10.73
echo ''
echo '================================================================'
echo 'PART 1: GA_01 (USW Lite 8 PoE) Full Test'
echo '================================================================'

echo '--- TS-01: Boot & Recovery ---'
FW=$(ssh_cmd $GA01_IP 'cat /lib/version')
echo "  TC-01.1 FW: $FW"

UPTIME=$(ssh_cmd $GA01_IP 'cat /proc/uptime | cut -d" " -f1')
UPTIME_MIN=$(echo "$UPTIME" | awk '{printf "%.0f", $1/60}')
echo "  TC-01.2 Uptime: ${UPTIME_MIN}min"

PROCS=$(ssh_cmd $GA01_IP 'ps | grep -E "ubios-udapi|switchdrvr|mcad|stamgr|cfgmtd|inform" | grep -v grep')
PROC_CNT=$(echo "$PROCS" | grep -c "." || echo 0)
echo "  TC-01.3 Key processes: $PROC_CNT"
echo "$PROCS" | sed 's/^/    /'

DMESG_ERRS=$(ssh_cmd $GA01_IP 'dmesg | grep -ciE "panic|oops|segfault|oom.killer|fatal" 2>/dev/null')
echo "  TC-01.4 Critical dmesg: $DMESG_ERRS"

ssh_cmd $GA01_IP 'for i in $(seq 1 100); do arping -c1 -w1 -I br0 10.10.8.1 >/dev/null 2>&1 & done; wait' >/dev/null 2>&1
sleep 2
ALIVE=$(ssh_cmd $GA01_IP 'echo alive')
echo "  TC-01.5 ARP flood: $ALIVE"

BOOT_ENV=$(ssh_cmd $GA01_IP 'cat /proc/mtd 2>/dev/null | grep -i kernel; fw_printenv bootpart 2>/dev/null' | head -3)
echo "  TC-01.6 Boot partition: $(echo $BOOT_ENV | head -1)"

echo ''
echo '--- TS-02: Config Survivability ---'
CFG_LINES=$(ssh_cmd $GA01_IP 'wc -l < /tmp/system.cfg 2>/dev/null || echo 0')
echo "  TC-02.1 Config: ${CFG_LINES} lines"

MGMT_IP=$(ssh_cmd $GA01_IP 'ip addr show eth0 2>/dev/null | grep "inet "'
)
echo "  TC-02.3 Mgmt: $MGMT_IP"

INFORM_URL=$(ssh_cmd $GA01_IP 'grep inform /tmp/system.cfg 2>/dev/null | head -1')
echo "  TC-02.4 Inform: $INFORM_URL"

HOST=$(ssh_cmd $GA01_IP 'hostname')
echo "  TC-02.5 Hostname: $HOST"

echo ''
echo '--- TS-03: SFP ---'
SFP=$(ssh_cmd $GA01_IP 'swctrl sfp show 2>/dev/null')
if [ -n "$SFP" ]; then
    echo "  SFP data:"
    echo "$SFP" | head -10 | sed 's/^/    /'
else
    echo "  N/A - No SFP data (Lite 8 PoE has no SFP)"
fi

echo ''
echo '--- TS-04: LACP ---'
echo '  N/A - No LACP on USW Lite 8 PoE'

echo ''
echo '--- TS-05: LCM ---'
echo '  N/A - No LCM on USW Lite 8 PoE'

echo ''
echo '--- TS-06: Protect ---'
echo '  N/A - No cameras'

echo ''
echo '--- TS-07: AP Adoption (GA_01) ---'
LLDP=$(ssh_cmd $GA01_IP 'swctrl lldp show 2>/dev/null')
echo "  LLDP neighbors:"
echo "$LLDP" | head -10 | sed 's/^/    /'

echo ''
echo '--- TS-08: STP ---'
STP_CFG=$(ssh_cmd $GA01_IP 'grep "stp\." /tmp/system.cfg 2>/dev/null | head -3')
echo "  STP config: $STP_CFG"
STP_CMD=$(ssh_cmd $GA01_IP 'swctrl stp show 2>&1 | head -10')
if [ -n "$STP_CMD" ]; then
    echo "  swctrl stp:"
    echo "$STP_CMD" | sed 's/^/    /'
else
    echo "  swctrl stp: not available"
fi

echo ''
echo '--- TS-09: PoE ---'
POE=$(ssh_cmd $GA01_IP 'swctrl poe show 2>/dev/null')
echo "$POE" | head -8 | sed 's/^/  /'

echo ''
echo '--- TS-10: CPU/Memory ---'
LOAD=$(ssh_cmd $GA01_IP 'cat /proc/loadavg')
echo "  CPU: $LOAD"
MEM=$(ssh_cmd $GA01_IP 'free 2>/dev/null')
echo "$MEM" | head -3 | sed 's/^/  /'
DISK=$(ssh_cmd $GA01_IP 'df -h / 2>/dev/null | tail -1')
echo "  Disk: $DISK"


########################################################################
# PART 2: TS-07 AP Adoption on GA_02 and GA_05
########################################################################
echo ''
echo '================================================================'
echo 'PART 2: TS-07 AP Adoption & Downstream Lifecycle'
echo '================================================================'

echo ''
echo '--- GA_02 (10.10.11.150) port 1 -> U7-Pro ---'
echo '  TC-07.1 LLDP:'
ssh_cmd 10.10.11.150 'swctrl lldp show 2>/dev/null | grep -E "Port|----| *1 "' | sed 's/^/    /'
echo '  TC-07.1 PoE on port 1:'
ssh_cmd 10.10.11.150 'swctrl poe show 2>/dev/null | grep -E "^Port|^----|^   1 "' | sed 's/^/    /'
echo '  TC-07.1 Port 1 link status:'
ssh_cmd 10.10.11.150 'swctrl port show 2>/dev/null | grep -E "^Port|^----|^   1 "' | sed 's/^/    /'

echo ''
echo '--- GA_05 (10.10.9.220) port 1 -> U6-IW ---'
echo '  TC-07.1 LLDP:'
ssh_cmd 10.10.9.220 'swctrl lldp show 2>/dev/null | grep -E "Port|----| *1 "' | sed 's/^/    /'
echo '  TC-07.1 PoE on port 1:'
ssh_cmd 10.10.9.220 'swctrl poe show 2>/dev/null | grep -E "^Port|^----|^   1 "' | sed 's/^/    /'
echo '  TC-07.1 Port 1 link status:'
ssh_cmd 10.10.9.220 'swctrl port show 2>/dev/null | grep -E "^Port|^----|^   1 "' | sed 's/^/    /'

echo ''
echo '--- TC-07.2 AP Adoption status from controller ---'

########################################################################
# PART 3: Verify AP status from controller MongoDB
########################################################################
echo ''
echo '--- AP devices in controller ---'
mongo --quiet --port 27117 ace --eval '
db.device.find({type:"uap"}, {name:1, ip:1, mac:1, model:1, version:1, state:1, "last_seen":1}).forEach(function(d) {
  var state_map = {0:"disconnected",1:"connected",2:"pending",4:"upgrading",5:"provisioning"};
  var s = state_map[d.state] || ("state="+d.state);
  print(d.name + " | " + d.ip + " | " + d.mac + " | " + d.model + " | " + d.version + " | " + s);
})
'

echo ''
echo '--- TC-07.2 AP adoption detail ---'
mongo --quiet --port 27117 ace --eval '
db.device.find({type:"uap"}, {name:1, ip:1, model:1, version:1, state:1, "uplink.sw_mac":1, "uplink.sw_port":1, "uplink.type":1}).forEach(function(d) {
  var ul = d.uplink || {};
  print("AP: " + d.name + " (" + d.model + " / " + d.version + ")");
  print("  State: " + d.state);
  print("  Uplink: sw_mac=" + ul.sw_mac + " sw_port=" + ul.sw_port + " type=" + ul.type);
})
'

echo ''
echo '--- TC-07.3 PoE delivery to APs (verifies PoE bug impact) ---'
echo '  GA_02 port 1 (BCM5616x, PwrLimit=-1, U7-Pro):'
ssh_cmd 10.10.11.150 'swctrl poe show 2>/dev/null | grep "^   1 "' | sed 's/^/    /'
echo '  GA_05 port 1 (RTL93xx, PwrLimit=32000, U6-IW):'
ssh_cmd 10.10.9.220 'swctrl poe show 2>/dev/null | grep "^   1 "' | sed 's/^/    /'

echo ''
echo '================================================================'
echo " End: $(date)"
echo '================================================================'
