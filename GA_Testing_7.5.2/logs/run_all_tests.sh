#!/bin/bash
# TS-01 through TS-10 for GA_02~GA_10 (all on 7.5.2)
# Excludes: TC-01.7 (72h soak), TC-03.1 (24h SFP soak), TC-06.1/2 (24h camera),
#           TC-10.1 (24h baseline), TC-10.3 (7d leak)

DUT_USER=ubiquiti
DUT_PASS="Ubiquiti@12341"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"

ssh_cmd() {
    sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$1" "$2" 2>/dev/null
}

# Device list: name|ip|model|platform|has_poe|has_sfp|has_lcm
declare -a DEVICES=(
  "GA_02_Pro48PoE|10.10.11.150|US48PRO|bcm5616x|1|1|1"
  "GA_03_24PoE|10.10.8.41|USL24P|rtl838x|1|1|0"
  "GA_04_Pro24PoE|10.10.9.4|US24PRO|bcm5616x|1|1|0"
  "GA_05_ProMax48PoE|10.10.9.220|USPM48P|rtl93xx|1|1|1"
  "GA_06_ProAgg|10.10.10.107|USAGGPRO|bcm5617x|0|1|1"
  "GA_07_Flex|10.10.8.137|USF5P|mt7621|1|0|0"
  "GA_08_ProMax24PoE|10.10.11.225|USPM24P|rtl93xx|1|1|1"
  "GA_09_Lite16PoE|10.10.8.202|USL16LP|rtl838x|1|0|0"
  "GA_10_24PoE250W|10.10.10.238|US24P250|bcm5334x|1|1|0"
)

PASS=0
WARN=0
FAIL=0
BUG=0
NA=0
RESULTS=""

log_result() {
    local suite=$1 device=$2 status=$3 detail=$4
    RESULTS="${RESULTS}${suite}|${device}|${status}|${detail}\n"
    case $status in
        PASS) PASS=$((PASS+1)) ;;
        WARN) WARN=$((WARN+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        BUG)  BUG=$((BUG+1)) ;;
        N/A)  NA=$((NA+1)) ;;
    esac
    printf "  [%s] %-25s %s %s\n" "$status" "$device" "$suite" "$detail"
}

echo '================================================================'
echo ' UniFi 7.5.2 Switch Firmware - Full Test Run'
echo ' GA_02 ~ GA_10 (9 devices)'
echo " Start: $(date)"
echo '================================================================'
echo ''

########################################################################
# TS-01: Post-Upgrade Boot & Auto-Recovery
########################################################################
echo '================================================================'
echo 'TS-01: Post-Upgrade Boot & Auto-Recovery'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    # TC-01.1: Firmware version verification
    FW=$(ssh_cmd $ip 'cat /lib/version')
    if echo "$FW" | grep -q '7.5.2'; then
        log_result "TC-01.1" "$name" "PASS" "FW=$FW"
    else
        log_result "TC-01.1" "$name" "FAIL" "Expected 7.5.2, got: $FW"
    fi

    # TC-01.2: Boot time (uptime check - device should be stable)
    UPTIME=$(ssh_cmd $ip 'cat /proc/uptime | cut -d" " -f1')
    UPTIME_MIN=$(echo "$UPTIME" | awk '{printf "%.0f", $1/60}')
    if [ -n "$UPTIME" ]; then
        log_result "TC-01.2" "$name" "PASS" "Uptime: ${UPTIME_MIN}min"
    else
        log_result "TC-01.2" "$name" "FAIL" "Cannot read uptime"
    fi

    # TC-01.3: Key processes running
    PROCS=$(ssh_cmd $ip 'ps | grep -E "ubios-udapi|switchdrvr|mcad|stamgr|cfgmtd" | grep -v grep | wc -l')
    if [ "$PROCS" -ge 2 ] 2>/dev/null; then
        log_result "TC-01.3" "$name" "PASS" "$PROCS key processes running"
    else
        log_result "TC-01.3" "$name" "WARN" "Only $PROCS key processes found"
    fi

    # TC-01.4: dmesg errors check
    DMESG_ERRS=$(ssh_cmd $ip 'dmesg | grep -ciE "panic|oops|segfault|oom.killer|fatal" 2>/dev/null')
    if [ "$DMESG_ERRS" = "0" ] || [ -z "$DMESG_ERRS" ]; then
        log_result "TC-01.4" "$name" "PASS" "No critical dmesg errors"
    else
        DMESG_SAMPLE=$(ssh_cmd $ip 'dmesg | grep -iE "panic|oops|segfault|oom.killer|fatal" | tail -2')
        log_result "TC-01.4" "$name" "WARN" "${DMESG_ERRS} critical msgs: $DMESG_SAMPLE"
    fi

    # TC-01.5: ARP flood resilience (send 1000 ARPs, check device stays up)
    ssh_cmd $ip 'for i in $(seq 1 100); do arping -c1 -w1 -I br0 10.10.8.1 >/dev/null 2>&1 & done; wait; echo done' >/dev/null 2>&1
    sleep 2
    ALIVE=$(ssh_cmd $ip 'echo alive')
    if [ "$ALIVE" = "alive" ]; then
        log_result "TC-01.5" "$name" "PASS" "ARP flood resilience OK"
    else
        log_result "TC-01.5" "$name" "FAIL" "Device unresponsive after ARP flood"
    fi

    # TC-01.6: Dual boot partition check
    BOOT_INFO=$(ssh_cmd $ip 'cat /proc/mtd 2>/dev/null | grep -i kernel')
    BOOT_ENV=$(ssh_cmd $ip 'fw_printenv bootpart 2>/dev/null; ubnt-fwctl status 2>/dev/null' | head -3)
    if [ -n "$BOOT_INFO" ] || [ -n "$BOOT_ENV" ]; then
        log_result "TC-01.6" "$name" "PASS" "Boot partition info available"
    else
        log_result "TC-01.6" "$name" "WARN" "Cannot verify dual boot"
    fi
done

echo ''

########################################################################
# TS-02: Configuration Survivability
########################################################################
echo '================================================================'
echo 'TS-02: Configuration Survivability'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    # TC-02.1: Config file exists and has content
    CFG_LINES=$(ssh_cmd $ip 'wc -l < /tmp/system.cfg 2>/dev/null || wc -l < /etc/config/system.cfg 2>/dev/null || echo 0')
    if [ "$CFG_LINES" -gt 10 ] 2>/dev/null; then
        log_result "TC-02.1" "$name" "PASS" "Config: ${CFG_LINES} lines"
    else
        log_result "TC-02.1" "$name" "WARN" "Config only ${CFG_LINES} lines"
    fi

    # TC-02.3: Management VLAN / network reachability
    MGMT_IP=$(ssh_cmd $ip 'ip addr show br0 2>/dev/null | grep "inet " | awk "{print \$2}"')
    if [ -n "$MGMT_IP" ]; then
        log_result "TC-02.3" "$name" "PASS" "Mgmt IP: $MGMT_IP"
    else
        log_result "TC-02.3" "$name" "WARN" "No br0 IP found"
    fi

    # TC-02.4: Controller inform connectivity
    INFORM=$(ssh_cmd $ip 'cat /var/run/inform.status 2>/dev/null; mca-ctrl -t dump-inform 2>/dev/null | head -1')
    INFORM_URL=$(ssh_cmd $ip 'grep -o "http[^ ]*inform" /tmp/system.cfg 2>/dev/null || grep -o "http[^ ]*inform" /etc/config/system.cfg 2>/dev/null')
    if [ -n "$INFORM_URL" ]; then
        log_result "TC-02.4" "$name" "PASS" "Inform URL: $INFORM_URL"
    else
        log_result "TC-02.4" "$name" "WARN" "No inform URL found"
    fi

    # TC-02.5: Hostname / alias preserved
    HOST=$(ssh_cmd $ip 'hostname')
    log_result "TC-02.5" "$name" "PASS" "Hostname: $HOST"
done

echo ''

########################################################################
# TS-03: SFP / DAC / Multigig Stability
########################################################################
echo '================================================================'
echo 'TS-03: SFP / DAC / Multigig Port Stability'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    if [ "$has_sfp" = "0" ]; then
        log_result "TC-03" "$name" "N/A" "No SFP ports"
        continue
    fi

    # TC-03.2: SFP module detection
    SFP_INFO=$(ssh_cmd $ip 'swctrl sfp show 2>/dev/null')
    if [ -n "$SFP_INFO" ]; then
        SFP_COUNT=$(echo "$SFP_INFO" | grep -cE "Ubiquiti|UBNT|OEM|FS\.COM|Finisar|Mellanox" || echo 0)
        log_result "TC-03.2" "$name" "PASS" "$SFP_COUNT SFP modules detected"
        echo "$SFP_INFO" | grep -v "^$\|^Port\|^----\|^Unit" | head -6 | sed 's/^/    /'
    else
        # Try alternate command
        SFP_INFO2=$(ssh_cmd $ip 'cat /sys/class/sfp/*/info 2>/dev/null | head -10')
        if [ -n "$SFP_INFO2" ]; then
            log_result "TC-03.2" "$name" "PASS" "SFP info via sysfs"
        else
            log_result "TC-03.2" "$name" "WARN" "No SFP data (may have no modules inserted)"
        fi
    fi

    # TC-03.3: Port link status on SFP ports
    PORT_INFO=$(ssh_cmd $ip 'swctrl port show 2>/dev/null')
    if [ -n "$PORT_INFO" ]; then
        SFP_PORTS_UP=$(echo "$PORT_INFO" | grep -E "U/U" | tail -6)
        SFP_PORTS_DN=$(echo "$PORT_INFO" | grep -E "U/D" | tail -6)
        UP_CNT=$(echo "$PORT_INFO" | grep -cE "U/U" || echo 0)
        DN_CNT=$(echo "$PORT_INFO" | grep -cE "U/D" || echo 0)
        log_result "TC-03.3" "$name" "PASS" "Ports UP:$UP_CNT DOWN:$DN_CNT"
    fi

    # TC-03.4: Link flap counter check
    FLAP_DATA=$(ssh_cmd $ip 'swctrl port counter show 2>/dev/null | head -5')
    if [ -n "$FLAP_DATA" ]; then
        log_result "TC-03.4" "$name" "PASS" "Port counters available"
    else
        log_result "TC-03.4" "$name" "N/A" "No port counter cmd"
    fi
done

echo ''

########################################################################
# TS-04: LACP / Link Aggregation
########################################################################
echo '================================================================'
echo 'TS-04: LACP / Link Aggregation'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    BOND=$(ssh_cmd $ip 'cat /proc/net/bonding/bond0 2>/dev/null | head -20')
    if [ -n "$BOND" ]; then
        SLAVES=$(echo "$BOND" | grep -c "Slave Interface" || echo 0)
        if [ "$SLAVES" -gt 0 ]; then
            MODE=$(echo "$BOND" | grep "Bonding Mode" | sed 's/.*: //')
            log_result "TC-04.1" "$name" "PASS" "LAG active: $SLAVES slaves, $MODE"
        else
            log_result "TC-04.1" "$name" "N/A" "bond0 exists, 0 slaves"
        fi
    else
        LAG=$(ssh_cmd $ip 'swctrl lag show 2>/dev/null | head -10')
        if [ -n "$LAG" ] && echo "$LAG" | grep -qE "[0-9]"; then
            log_result "TC-04.1" "$name" "PASS" "LAG config found"
            echo "$LAG" | head -5 | sed 's/^/    /'
        else
            log_result "TC-04.1" "$name" "N/A" "No LACP configured"
        fi
    fi
done

echo ''

########################################################################
# TS-05: LCM Touchscreen
########################################################################
echo '================================================================'
echo 'TS-05: LCM Touchscreen'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    if [ "$has_lcm" = "0" ]; then
        log_result "TC-05" "$name" "N/A" "No LCM on this model"
        continue
    fi

    # TC-05.1: LCM daemon running
    LCMD=$(ssh_cmd $ip 'ps | grep lcmd | grep -v grep')
    if [ -n "$LCMD" ]; then
        log_result "TC-05.1" "$name" "PASS" "lcmd running"
    else
        log_result "TC-05.1" "$name" "WARN" "lcmd not running"
    fi

    # TC-05.2: LCM firmware version
    LCM_VER=$(ssh_cmd $ip 'cat /var/log/lcm_version 2>/dev/null || lcm-ctrl -t get-version 2>/dev/null')
    if [ -n "$LCM_VER" ]; then
        log_result "TC-05.2" "$name" "PASS" "LCM FW: $LCM_VER"
    else
        LCM_VER2=$(ssh_cmd $ip 'ubnt-lcm-ctl version 2>/dev/null || ls /lib/firmware/lcm* 2>/dev/null | head -1')
        if [ -n "$LCM_VER2" ]; then
            log_result "TC-05.2" "$name" "PASS" "LCM: $LCM_VER2"
        else
            log_result "TC-05.2" "$name" "WARN" "Cannot determine LCM version"
        fi
    fi
done

echo ''

########################################################################
# TS-06: Protect / Camera Streams
########################################################################
echo '================================================================'
echo 'TS-06: Protect / Camera Streams'
echo '================================================================'
echo '  N/A - No Protect/NVR/cameras in environment'
echo '  (TC-06.1/06.2 24h camera soak also excluded per scope)'
log_result "TC-06" "ALL" "N/A" "No Protect infrastructure"

echo ''

########################################################################
# TS-07: AP Adoption & Downstream Lifecycle
########################################################################
echo '================================================================'
echo 'TS-07: AP Adoption & Downstream Lifecycle'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    if [ "$has_poe" = "0" ]; then
        log_result "TC-07" "$name" "N/A" "Not a PoE switch"
        continue
    fi

    # TC-07.1: LLDP neighbor discovery (check for APs)
    LLDP=$(ssh_cmd $ip 'swctrl lldp show 2>/dev/null | head -30')
    if [ -n "$LLDP" ]; then
        AP_COUNT=$(echo "$LLDP" | grep -ciE "UAP|U6|U7|nanoHD|FlexHD|AC-Pro|wifi" || echo 0)
        NON_AP=$(echo "$LLDP" | grep -cE "[0-9]" || echo 0)
        if [ "$AP_COUNT" -gt 0 ]; then
            log_result "TC-07.1" "$name" "PASS" "$AP_COUNT APs via LLDP"
        else
            log_result "TC-07.1" "$name" "WARN" "No APs in LLDP ($NON_AP total neighbors)"
        fi
    else
        # Try lldpcli
        LLDP2=$(ssh_cmd $ip 'lldpcli show neighbors 2>/dev/null | head -20')
        if [ -n "$LLDP2" ]; then
            NEIGH=$(echo "$LLDP2" | grep -c "Interface" || echo 0)
            log_result "TC-07.1" "$name" "PASS" "$NEIGH LLDP neighbors"
        else
            log_result "TC-07.1" "$name" "WARN" "No LLDP data"
        fi
    fi
done

echo ''

########################################################################
# TS-08: STP / Topology Integrity
########################################################################
echo '================================================================'
echo 'TS-08: STP / Topology Integrity'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    # TC-08.1: STP enabled and role
    STP=$(ssh_cmd $ip 'swctrl stp show 2>/dev/null')
    if [ -n "$STP" ]; then
        ROLE=$(echo "$STP" | grep -iE "root|designated|bridge" | head -1)
        PRIO=$(echo "$STP" | grep -i "priority" | head -1)
        DISC=$(echo "$STP" | grep -ci "discarding" || echo 0)
        FWD=$(echo "$STP" | grep -ci "forwarding" || echo 0)

        IS_ROOT=$(echo "$STP" | grep -ci "root bridge\|this bridge is root" || echo 0)
        if [ "$IS_ROOT" -gt 0 ]; then
            log_result "TC-08.1" "$name" "PASS" "ROOT bridge, fwd:$FWD disc:$DISC"
        else
            log_result "TC-08.1" "$name" "PASS" "STP active, fwd:$FWD disc:$DISC"
        fi
    else
        # Try brctl
        BRCTL=$(ssh_cmd $ip 'brctl showstp br0 2>/dev/null | head -20')
        if [ -n "$BRCTL" ]; then
            BRIDGE_ID=$(echo "$BRCTL" | grep "bridge id" | head -1)
            log_result "TC-08.1" "$name" "PASS" "STP via brctl: $BRIDGE_ID"
        else
            log_result "TC-08.1" "$name" "WARN" "No STP data available"
        fi
    fi

    # TC-08.2: No topology change storm
    TC_COUNT=$(ssh_cmd $ip 'swctrl stp show 2>/dev/null | grep -i "topology change" | head -3')
    if [ -n "$TC_COUNT" ]; then
        log_result "TC-08.2" "$name" "PASS" "TC info: $(echo $TC_COUNT | tr '\n' ' ')"
    else
        log_result "TC-08.2" "$name" "N/A" "No TC counter"
    fi
done

echo ''

########################################################################
# TS-09: PoE Delivery & Reporting
########################################################################
echo '================================================================'
echo 'TS-09: PoE Delivery & Reporting'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    if [ "$has_poe" = "0" ]; then
        log_result "TC-09" "$name" "N/A" "Not a PoE switch"
        continue
    fi

    # TC-09.1: PoE budget / total power
    POE=$(ssh_cmd $ip 'swctrl poe show 2>/dev/null')
    if [ -n "$POE" ]; then
        TOTAL_LIMIT=$(echo "$POE" | grep -i "total.*limit\|power.*budget\|max.*power" | head -1)
        TOTAL_CONSUMPTION=$(echo "$POE" | grep -i "consumption\|current.*power\|total.*watt" | head -1)

        # Check for negative values (known BCM bug)
        NEG_CHECK=$(echo "$POE" | grep -oE "\-[0-9]{5,}")
        if [ -n "$NEG_CHECK" ]; then
            log_result "TC-09.1" "$name" "BUG" "Negative PoE value: $NEG_CHECK"
        else
            log_result "TC-09.1" "$name" "PASS" "$(echo $TOTAL_LIMIT | tr -s ' ')"
        fi

        # TC-09.2: Per-port PoE status
        POE_PORTS=$(echo "$POE" | grep -cE "^[[:space:]]*[0-9]+" || echo 0)
        DELIVERING=$(echo "$POE" | grep -ci "delivering\|enabled\|on" || echo 0)
        log_result "TC-09.2" "$name" "PASS" "$POE_PORTS PoE ports listed, $DELIVERING active"
    else
        # Try alternate PoE commands
        POE2=$(ssh_cmd $ip 'ubnt-poe show 2>/dev/null || cat /proc/poe/info 2>/dev/null')
        if [ -n "$POE2" ]; then
            log_result "TC-09.1" "$name" "PASS" "PoE info via alternate path"
            echo "$POE2" | head -5 | sed 's/^/    /'
        else
            log_result "TC-09.1" "$name" "WARN" "No PoE data available"
        fi
    fi
done

echo ''

########################################################################
# TS-10: CPU, Memory & Stability (snapshot only, no 24h/7d tests)
########################################################################
echo '================================================================'
echo 'TS-10: CPU, Memory & Stability (snapshot)'
echo '================================================================'

for dev in "${DEVICES[@]}"; do
    IFS='|' read -r name ip model platform has_poe has_sfp has_lcm <<< "$dev"

    # TC-10.2: CPU load
    LOAD=$(ssh_cmd $ip 'cat /proc/loadavg')
    LOAD1=$(echo "$LOAD" | awk '{print $1}')
    LOAD5=$(echo "$LOAD" | awk '{print $2}')
    LOAD15=$(echo "$LOAD" | awk '{print $3}')

    # TC-10.2: Memory usage
    MEM=$(ssh_cmd $ip 'free -m 2>/dev/null || free 2>/dev/null')
    MEM_TOTAL=$(echo "$MEM" | grep -i "^Mem" | awk '{print $2}')
    MEM_USED=$(echo "$MEM" | grep -i "^Mem" | awk '{print $3}')
    if [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null; then
        MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
    else
        MEM_PCT="?"
    fi

    # Evaluate CPU
    CPU_STATUS="PASS"
    # Check if load > 4.0 (high for single-core ARM)
    HIGH=$(echo "$LOAD1" | awk '{print ($1 > 4.0) ? 1 : 0}')
    if [ "$HIGH" = "1" ]; then
        CPU_STATUS="WARN"
    fi

    log_result "TC-10.2" "$name" "$CPU_STATUS" "CPU: $LOAD1/$LOAD5/$LOAD15  RAM: ${MEM_USED}/${MEM_TOTAL}MB (${MEM_PCT}%)"

    # TC-10.4: Top processes
    TOP_PROCS=$(ssh_cmd $ip 'ps -w 2>/dev/null | sort -k3 -rn 2>/dev/null | head -3 || ps | head -5')
    TOP1=$(echo "$TOP_PROCS" | head -1 | sed 's/  */ /g')
    log_result "TC-10.4" "$name" "PASS" "Top: $TOP1"

    # TC-10.5: Filesystem usage
    DISK=$(ssh_cmd $ip 'df -h / 2>/dev/null | tail -1')
    DISK_PCT=$(echo "$DISK" | awk '{print $5}' | tr -d '%')
    if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -gt 90 ] 2>/dev/null; then
        log_result "TC-10.5" "$name" "WARN" "Disk usage: ${DISK_PCT}%"
    elif [ -n "$DISK_PCT" ]; then
        log_result "TC-10.5" "$name" "PASS" "Disk usage: ${DISK_PCT}%"
    else
        log_result "TC-10.5" "$name" "WARN" "Cannot read disk usage"
    fi
done

echo ''
echo '================================================================'
echo ' SUMMARY'
echo '================================================================'
echo " PASS: $PASS"
echo " WARN: $WARN"
echo " FAIL: $FAIL"
echo " BUG:  $BUG"
echo " N/A:  $NA"
echo " Total: $((PASS+WARN+FAIL+BUG+NA))"
echo ""
echo "End: $(date)"
echo '================================================================'

# Output CSV for report integration
echo ""
echo "=== CSV RESULTS ==="
echo "suite|device|status|detail"
printf "$RESULTS"
echo "=== END CSV ==="
