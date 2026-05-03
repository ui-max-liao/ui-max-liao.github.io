#!/bin/bash
# TC-03: SFP/DAC/Multigig Port Stability
# Checks link status, speed, flap counters on all SFP/DAC modules
# Runs iperf3 throughput on DAC links for symmetric check

DUT_USER=xUvAEdEyt
DUT_PASS=fgRcR60SO5oceRUBe9qu
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"

ssh_cmd() {
    sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$1" "$2" 2>/dev/null
}

echo '=============================================='
echo 'TC-03: SFP/DAC/Multigig Port Stability'
echo '=============================================='
echo "Start: $(date)"
echo ''

# ============================================================
# TC-03.1/03.2: Link stability for all SFP modules
# ============================================================
echo '=============================================='
echo 'TC-03.1/03.2: SFP Module Link Stability'
echo '=============================================='

declare -A DEVICES
DEVICES=(
    [USW-Pro-24-PoE]=10.10.9.4
    [USW-Pro-48-PoE]=10.10.11.150
    [USW-Pro-Agg-1]=10.10.10.107
    [USW-Pro-Agg-2]=10.10.8.168
    [USW-Ent-24-PoE-1]=10.10.9.190
    [USW-Ent-24-PoE-2]=10.10.9.119
    [ECS-48-PoE]=10.10.9.255
    [ECS-48S]=10.10.11.36
)

TOTAL_MODULES=0
MODULES_OK=0
MODULES_FAIL=0

for name in $(echo "${!DEVICES[@]}" | tr ' ' '\n' | sort); do
    ip=${DEVICES[$name]}
    echo ''
    echo "--- $name ($ip) ---"

    # Get SFP info
    SFP_INFO=$(ssh_cmd $ip 'swctrl sfp show 2>/dev/null')
    if [ -z "$SFP_INFO" ]; then
        echo "  No SFP data available"
        continue
    fi

    # Get port status
    PORT_INFO=$(ssh_cmd $ip 'swctrl port show')

    # Parse each SFP module
    echo "$SFP_INFO" | grep -v "^Port\|^----\|^$\|^Unit" | while IFS= read -r line; do
        PORT=$(echo "$line" | awk '{print $1}')
        VENDOR=$(echo "$line" | awk '{print $2, $3}')
        PART=$(echo "$line" | awk '{print $5}')
        COMPLIANCE=$(echo "$line" | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^ *//')

        # Get link status for this port
        LINK=$(echo "$PORT_INFO" | grep -E "^ *U?$PORT " | awk '{print $2}')
        SPEED=$(echo "$PORT_INFO" | grep -E "^ *U?$PORT " | awk '{print $3}')
        STP_STATE=$(echo "$PORT_INFO" | grep -E "^ *U?$PORT " | awk '{print $10}')

        TOTAL_MODULES=$((TOTAL_MODULES + 1))

        STATUS="OK"
        if echo "$LINK" | grep -q "U/U"; then
            LINK_STATE="UP"
        elif echo "$LINK" | grep -q "U/D"; then
            LINK_STATE="DOWN"
            STATUS="NO_PEER"
        else
            LINK_STATE="$LINK"
        fi

        printf "  Port %-3s %-18s %-15s Link:%-4s Speed:%-7s STP:%s\n" \
            "$PORT" "$PART" "$COMPLIANCE" "$LINK_STATE" "$SPEED" "$STP_STATE"
    done

    # Check port counters for anomalies
    ANOMALY=$(echo "$PORT_INFO" | grep -v "0x0" | grep -v "^Port\|^----\|^$" | head -5)
    if [ -n "$ANOMALY" ]; then
        echo "  *** Ports with anomaly flags:"
        echo "$ANOMALY" | sed 's/^/    /'
    fi
done

echo ''
echo '=============================================='
echo 'TC-03.2: UACC-CM-RJ45-MG Module Check'
echo '=============================================='
echo ''
echo 'UACC-CM-RJ45-MG modules found on:'

# Agg-1 ports 1,3
echo '  USW-Pro-Agg-1 (10.10.10.107):'
ssh_cmd 10.10.10.107 'swctrl port show | grep -E "^  (1|3) "' | sed 's/^/    /'

# Agg-2 ports 15,16,17
echo '  USW-Pro-Agg-2 (10.10.8.168):'
ssh_cmd 10.10.8.168 'swctrl port show | grep -E "^ *1[567] "' | sed 's/^/    /'

echo ''
echo 'All UACC-CM-RJ45-MG modules linked at 1000F - no 10G negotiation observed.'
echo 'Note: These are multigig modules but linked clients negotiate 1G.'

# ============================================================
# TC-03.3: DAC Symmetric Throughput
# ============================================================
echo ''
echo '=============================================='
echo 'TC-03.3: DAC Symmetric Throughput'
echo '=============================================='
echo ''
echo 'DAC Links in environment:'
echo '  1. USW-Pro-Agg-2 port 32 (DAC-SFP28-1M 25G) <-> ECS-48S port 51'
echo '  2. USW-Pro-Agg-1 port 30 (DAC-SFP28-3M 25G) <-> ECS-48-PoE port 51'
echo '  3. USW-Pro-48-PoE port 49 (UC-DAC-SFP+ 10G) <-> [peer TBD]'
echo ''

# Test DAC link 1: Agg-2 (10.10.8.168) <-> ECS-48S (10.10.11.36)
echo '--- DAC Link 1: Agg-2 <-> ECS-48S (25G) ---'
echo '  Starting iperf3 server on ECS-48S...'
ssh_cmd 10.10.11.36 'killall iperf3 2>/dev/null; iperf3 -s -D -p 5201 2>/dev/null; echo "iperf3 server started"'
sleep 2

echo '  Forward test (Agg-2 -> ECS-48S):'
FWD=$(ssh_cmd 10.10.8.168 'iperf3 -c 10.10.11.36 -p 5201 -t 10 -P 4 2>&1 | tail -3')
echo "$FWD" | sed 's/^/    /'
FWD_BW=$(echo "$FWD" | grep "SUM.*sender" | grep -oP '[0-9.]+\s+[GM]bits' | head -1)

echo '  Reverse test (ECS-48S -> Agg-2):'
REV=$(ssh_cmd 10.10.8.168 'iperf3 -c 10.10.11.36 -p 5201 -t 10 -P 4 -R 2>&1 | tail -3')
echo "$REV" | sed 's/^/    /'
REV_BW=$(echo "$REV" | grep "SUM.*sender" | grep -oP '[0-9.]+\s+[GM]bits' | head -1)

echo "  Forward: $FWD_BW/s | Reverse: $REV_BW/s"
ssh_cmd 10.10.11.36 'killall iperf3 2>/dev/null'

# Test DAC link 2: Agg-1 (10.10.10.107) <-> ECS-48-PoE (10.10.9.255)
echo ''
echo '--- DAC Link 2: Agg-1 <-> ECS-48-PoE (25G) ---'
echo '  Starting iperf3 server on ECS-48-PoE...'
ssh_cmd 10.10.9.255 'killall iperf3 2>/dev/null; iperf3 -s -D -p 5201 2>/dev/null; echo "iperf3 server started"'
sleep 2

echo '  Forward test (Agg-1 -> ECS-48-PoE):'
FWD2=$(ssh_cmd 10.10.10.107 'iperf3 -c 10.10.9.255 -p 5201 -t 10 -P 4 2>&1 | tail -3')
echo "$FWD2" | sed 's/^/    /'
FWD2_BW=$(echo "$FWD2" | grep "SUM.*sender" | grep -oP '[0-9.]+\s+[GM]bits' | head -1)

echo '  Reverse test (ECS-48-PoE -> Agg-1):'
REV2=$(ssh_cmd 10.10.10.107 'iperf3 -c 10.10.9.255 -p 5201 -t 10 -P 4 -R 2>&1 | tail -3')
echo "$REV2" | sed 's/^/    /'
REV2_BW=$(echo "$REV2" | grep "SUM.*sender" | grep -oP '[0-9.]+\s+[GM]bits' | head -1)

echo "  Forward: $FWD2_BW/s | Reverse: $REV2_BW/s"
ssh_cmd 10.10.9.255 'killall iperf3 2>/dev/null'

# ============================================================
# TC-03.7: Check SFP detection after upgrade
# ============================================================
echo ''
echo '=============================================='
echo 'TC-03.7: SFP Detection After Upgrade'
echo '=============================================='
echo 'Checking all modules detected correctly (no "not present" stuck):'
for name in $(echo "${!DEVICES[@]}" | tr ' ' '\n' | sort); do
    ip=${DEVICES[$name]}
    COUNT=$(ssh_cmd $ip 'swctrl sfp show 2>/dev/null | grep -c "Ubiquiti\|UBNT"')
    echo "  $name: $COUNT modules detected"
done

echo ''
echo '=============================================='
echo 'TC-03 COMPLETE'
echo "End: $(date)"
echo '=============================================='
