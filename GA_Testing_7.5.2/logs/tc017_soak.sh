#!/bin/bash
# TC-01.7: 72-hour soak post-upgrade
# Monitors all upgraded 7.5.0 devices every 5 minutes for 72 hours
# Logs ping reachability, uptime, and firmware version

DURATION_HOURS=72
INTERVAL_SEC=300  # 5 minutes
LOGFILE=/tmp/tc017_soak.log
CSVFILE=/tmp/tc017_soak.csv

# All 7.5.0 upgraded devices
declare -A DEVICES
DEVICES[USW-Pro-24-PoE]=10.10.9.4
DEVICES[USW-Pro-48-PoE]=10.10.11.150
DEVICES[USW-Pro-Agg-1]=10.10.10.107
DEVICES[USW-Ent-24-PoE-1]=10.10.9.190
DEVICES[USW-Flex]=10.10.10.91
DEVICES[ECS-48-PoE]=10.10.9.255
DEVICES[USW-Ent-24-PoE-2]=10.10.9.119
DEVICES[USW-Pro-Agg-2]=10.10.8.168
DEVICES[ECS-48S]=10.10.11.36

DUT_USER=xUvAEdEyt
DUT_PASS=fgRcR60SO5oceRUBe9qu
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=5"

TOTAL_CHECKS=$((DURATION_HOURS * 3600 / INTERVAL_SEC))

echo "=============================================" | tee $LOGFILE
echo "TC-01.7: 72-hour Soak Test" | tee -a $LOGFILE
echo "=============================================" | tee -a $LOGFILE
echo "Start: $(date)" | tee -a $LOGFILE
echo "Duration: ${DURATION_HOURS}h, Check interval: ${INTERVAL_SEC}s" | tee -a $LOGFILE
echo "Total checks: $TOTAL_CHECKS" | tee -a $LOGFILE
echo "Devices: ${!DEVICES[@]}" | tee -a $LOGFILE
echo "" | tee -a $LOGFILE

# CSV header
echo "timestamp,check_num,device,ip,ping,ssh,firmware,uptime" > $CSVFILE

OFFLINE_EVENTS=0

for check in $(seq 1 $TOTAL_CHECKS); do
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    ELAPSED_H=$(echo "scale=1; ($check * $INTERVAL_SEC) / 3600" | bc)
    echo "--- Check #${check}/${TOTAL_CHECKS} at $TS (${ELAPSED_H}h) ---" >> $LOGFILE

    for name in $(echo "${!DEVICES[@]}" | tr ' ' '\n' | sort); do
        ip=${DEVICES[$name]}

        # Ping check
        if ping -c2 -W2 $ip >/dev/null 2>&1; then
            PING_OK=1
        else
            PING_OK=0
        fi

        # SSH check + uptime + firmware
        if [ $PING_OK -eq 1 ]; then
            INFO=$(sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$ip" '
                FW=$(cat /lib/version 2>/dev/null)
                UP=$(uptime 2>/dev/null | sed "s/.*up /up /;s/,.*load.*//" )
                echo "$FW|$UP"
            ' 2>/dev/null)
            if [ -n "$INFO" ]; then
                SSH_OK=1
                FW=$(echo "$INFO" | cut -d'|' -f1)
                UPTIME=$(echo "$INFO" | cut -d'|' -f2)
            else
                SSH_OK=0
                FW=""
                UPTIME=""
            fi
        else
            SSH_OK=0
            FW=""
            UPTIME=""
        fi

        STATUS="OK"
        if [ $PING_OK -eq 0 ]; then
            STATUS="OFFLINE"
            OFFLINE_EVENTS=$((OFFLINE_EVENTS + 1))
            echo "*** OFFLINE: $name ($ip) at $TS ***" | tee -a $LOGFILE
        elif [ $SSH_OK -eq 0 ]; then
            STATUS="SSH_FAIL"
        fi

        echo "$TS,$check,$name,$ip,$PING_OK,$SSH_OK,$FW,$UPTIME" >> $CSVFILE
        printf "  %-22s %-15s %s %s %s\n" "$name" "$ip" "$STATUS" "$FW" "$UPTIME" >> $LOGFILE
    done

    # Print summary every hour (every 12 checks)
    if [ $((check % 12)) -eq 0 ]; then
        echo ""
        echo "[${ELAPSED_H}h] Soak status: $check checks done, $OFFLINE_EVENTS offline events"
        echo "[${ELAPSED_H}h] Soak status: $check checks done, $OFFLINE_EVENTS offline events" >> $LOGFILE
    fi

    # Early termination check
    if [ $OFFLINE_EVENTS -gt 10 ]; then
        echo "WARNING: >10 offline events, continuing monitoring..." | tee -a $LOGFILE
    fi

    sleep $INTERVAL_SEC
done

echo "" | tee -a $LOGFILE
echo "=============================================" | tee -a $LOGFILE
echo "TC-01.7 COMPLETE" | tee -a $LOGFILE
echo "End: $(date)" | tee -a $LOGFILE
echo "Total offline events: $OFFLINE_EVENTS" | tee -a $LOGFILE

if [ $OFFLINE_EVENTS -eq 0 ]; then
    echo "RESULT: PASS - No offline transitions in ${DURATION_HOURS}h" | tee -a $LOGFILE
else
    echo "RESULT: FAIL - $OFFLINE_EVENTS offline events detected" | tee -a $LOGFILE
    echo "Offline details:" | tee -a $LOGFILE
    grep "OFFLINE" $LOGFILE | tee -a $LOGFILE
fi
echo "Log: $LOGFILE" | tee -a $LOGFILE
echo "CSV: $CSVFILE" | tee -a $LOGFILE
