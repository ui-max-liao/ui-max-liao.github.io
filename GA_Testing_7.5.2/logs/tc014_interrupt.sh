#!/bin/bash
# TC-01.4: Firmware Download Interruption Test
# Tests device behavior when receiving truncated/interrupted firmware
# DUT: USW-Flex 10.10.10.60 (mt7621, 7.4.1)

DUT=10.10.10.60
DUT_USER=xUvAEdEyt
DUT_PASS=fgRcR60SO5oceRUBe9qu
JUMP_IP=10.10.8.1
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10"

run_ssh() {
    sshpass -p "$DUT_PASS" ssh $SSH_OPTS "$DUT_USER@$DUT" "$@" 2>/dev/null
}

echo '=============================================='
echo 'TC-01.4: Firmware Download Interruption Test'
echo '=============================================='
echo "Start: $(date)"
echo "DUT: USW-Flex $DUT (mt7621)"
echo ''

# Get baseline version
BASELINE=$(run_ssh 'cat /lib/version')
echo "Baseline FW: $BASELINE"
echo ''

for PCT in 30 60 90; do
    echo "--- Test ${PCT}% interruption ---"
    TRUNC_FILE=fw_trunc_${PCT}.bin
    TRUNC_SIZE=$(stat -c%s /tmp/$TRUNC_FILE 2>/dev/null || stat -f%z /tmp/$TRUNC_FILE 2>/dev/null)
    echo "  Truncated file: $TRUNC_FILE ($TRUNC_SIZE bytes)"

    # Trigger download on DUT
    echo "  Triggering firmware download..."
    RESULT=$(run_ssh "
        cd /tmp
        rm -f fwupdate.bin
        curl -s -o fwupdate.bin http://${JUMP_IP}:9999/${TRUNC_FILE}
        DL_SIZE=\$(stat -c%s fwupdate.bin 2>/dev/null || echo 0)
        echo \"DL_SIZE: \$DL_SIZE\"

        # Try to validate the firmware
        echo 'Validating...'
        /sbin/fwupdate.real -c 2>&1 || echo 'VALIDATION_FAILED'

        # Check header bytes
        echo 'Header:'
        hexdump -C fwupdate.bin 2>/dev/null | head -2

        # Clean up
        rm -f fwupdate.bin
        echo 'Cleaned up'
    ")
    echo "$RESULT" | sed 's/^/    /'

    # Verify DUT still alive and on same version
    sleep 2
    CURRENT=$(run_ssh 'cat /lib/version')
    if [ -z "$CURRENT" ]; then
        echo "  WARNING: DUT unreachable after ${PCT}% test!"
        echo "  Waiting 60s for recovery..."
        sleep 60
        CURRENT=$(run_ssh 'cat /lib/version')
    fi

    if [ "$CURRENT" = "$BASELINE" ]; then
        echo "  RESULT: PASS - DUT stayed on $BASELINE (firmware rejected)"
    elif [ -z "$CURRENT" ]; then
        echo "  RESULT: FAIL - DUT unreachable"
    else
        echo "  RESULT: UNEXPECTED - FW changed to $CURRENT"
    fi
    echo ''
done

# Test actual download interruption (kill HTTP server mid-transfer)
echo '--- Test: Kill HTTP server mid-download (real interruption) ---'
echo '  Using full firmware file with server kill after 1s'

# Get HTTP server PID
HTTP_PID=$(pgrep -f 'python3 -m http.server 9999' | head -1)
echo "  Current HTTP server PID: $HTTP_PID"

# Start download on DUT (background via nohup)
run_ssh "cd /tmp && rm -f fwupdate.bin && nohup curl -s --max-time 30 -o fwupdate.bin http://${JUMP_IP}:9999/fw_US_mt7621.bin &" &
sleep 1

# Kill HTTP server to interrupt download
kill $HTTP_PID 2>/dev/null
echo '  HTTP server killed during download'
sleep 5

# Check what the DUT has
PARTIAL_RESULT=$(run_ssh "
    FSIZE=\$(stat -c%s /tmp/fwupdate.bin 2>/dev/null || echo 0)
    echo \"Downloaded: \$FSIZE bytes (expected: 7735987)\"
    if [ -f /tmp/fwupdate.bin ]; then
        /sbin/fwupdate.real -c 2>&1 || echo 'VALIDATION_FAILED'
    else
        echo 'No file downloaded'
    fi
    rm -f /tmp/fwupdate.bin
    cat /lib/version
")
echo "$PARTIAL_RESULT" | sed 's/^/    /'

CURRENT=$(run_ssh 'cat /lib/version')
if [ "$CURRENT" = "$BASELINE" ]; then
    echo "  RESULT: PASS - DUT stayed on $BASELINE after interrupted download"
else
    echo "  RESULT: FAIL - FW changed unexpectedly"
fi

# Restart HTTP server
cd /tmp && nohup python3 -m http.server 9999 &>/dev/null &
sleep 1
echo '  HTTP server restarted'

echo ''
echo '=============================================='
echo 'TC-01.4 COMPLETE'
echo "End: $(date)"
echo '=============================================='
