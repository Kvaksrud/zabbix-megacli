#!/bin/bash
#
# MegaCLI RAID Health Check Script
# Checks: adapters, virtual drives, physical disks, BBU, rebuilds, errors
#
# Requires: megacli (and typically sudo/root for hardware access)
#

set -euo pipefail

MEGACLI="megacli"
EXIT_CODE=0
WARNINGS=()
CRITICALS=()

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARNINGS+=("$1"); [ "$EXIT_CODE" -lt 1 ] && EXIT_CODE=1; }
crit() { echo -e "  ${RED}[CRIT]${NC} $1"; CRITICALS+=("$1"); EXIT_CODE=2; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
header() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

# Check if we need sudo (test once)
NEED_SUDO=0
test_output=$($MEGACLI -AdpCount -NoLog 2>&1 || true)
if echo "$test_output" | grep -q "Controller Count: 0"; then
    NEED_SUDO=1
fi

cli() {
    if [ "$NEED_SUDO" -eq 1 ]; then
        sudo $MEGACLI "$@" 2>/dev/null || true
    else
        $MEGACLI "$@" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------
header "Adapter Check"
# ----------------------------------------------------------
adp_output=$(cli -AdpCount -NoLog)
controller_count=$(echo "$adp_output" | grep -oP 'Controller Count:\s*\K\d+')

if [ "${controller_count:-0}" -eq 0 ]; then
    crit "No RAID controllers detected"
    echo -e "\n${RED}Cannot continue without a controller.${NC}"
    exit 2
fi
ok "Found $controller_count controller(s)"

adp_info=$(cli -AdpAllInfo -aAll -NoLog)

# Degraded / offline VDs from adapter summary
degraded=$(echo "$adp_info" | grep -P '^\s*Degraded\s*:' | awk '{print $NF}')
offline=$(echo "$adp_info" | grep -P '^\s*Offline\s*:' | awk '{print $NF}')
crit_disks=$(echo "$adp_info" | grep -P '^\s*Critical Disks\s*:' | awk '{print $NF}')
failed_disks=$(echo "$adp_info" | grep -P '^\s*Failed Disks\s*:' | awk '{print $NF}')

[ "${degraded:-0}" -gt 0 ] && crit "$degraded degraded virtual drive(s)" || ok "No degraded virtual drives"
[ "${offline:-0}" -gt 0 ] && crit "$offline offline virtual drive(s)" || ok "No offline virtual drives"
[ "${crit_disks:-0}" -gt 0 ] && crit "$crit_disks critical disk(s)" || ok "No critical disks"
[ "${failed_disks:-0}" -gt 0 ] && crit "$failed_disks failed disk(s)" || ok "No failed disks"

# Memory errors
mem_corr=$(echo "$adp_info" | grep "Memory Correctable Errors" | awk -F: '{print $2}' | tr -d ' ')
mem_uncorr=$(echo "$adp_info" | grep "Memory Uncorrectable Errors" | awk -F: '{print $2}' | tr -d ' ')
[ "${mem_uncorr:-0}" -gt 0 ] && crit "Controller has $mem_uncorr uncorrectable memory error(s)"
[ "${mem_corr:-0}" -gt 0 ] && warn "Controller has $mem_corr correctable memory error(s)"
[ "${mem_corr:-0}" -eq 0 ] && [ "${mem_uncorr:-0}" -eq 0 ] && ok "No controller memory errors"

# ROC temperature
roc_temp=$(echo "$adp_info" | grep -oP 'ROC temperature\s*:\s*\K\d+')
if [ -n "${roc_temp:-}" ]; then
    if [ "$roc_temp" -ge 98 ]; then
        crit "ROC temperature: ${roc_temp}C (>=98C)"
    elif [ "$roc_temp" -ge 93 ]; then
        warn "ROC temperature: ${roc_temp}C (>=93C)"
    else
        ok "ROC temperature: ${roc_temp}C"
    fi
fi

# ----------------------------------------------------------
header "Virtual Drive (Array) Check"
# ----------------------------------------------------------
vd_output=$(cli -LDInfo -Lall -aAll -NoLog)

# Parse each VD
vd_count=0
while IFS= read -r line; do
    if echo "$line" | grep -qP '^(Virtual Drive|CacheCade Virtual Drive):'; then
        vd_num=$(echo "$line" | grep -oP ':\s*\K\d+' | head -1)
        vd_type="VD"
        echo "$line" | grep -q "CacheCade" && vd_type="CacheCade"
        vd_count=$((vd_count + 1))
    fi
    if echo "$line" | grep -qP '^\s*State\s*:'; then
        state=$(echo "$line" | awk -F: '{print $2}' | xargs)
        if [ "$state" = "Optimal" ]; then
            ok "$vd_type $vd_num: $state"
        elif [ "$state" = "Degraded" ]; then
            crit "$vd_type $vd_num: $state"
        elif [ "$state" = "Offline" ]; then
            crit "$vd_type $vd_num: $state"
        else
            warn "$vd_type $vd_num: $state"
        fi
    fi
    if echo "$line" | grep -qP '^\s*RAID Level\s*:'; then
        raid_info=$(echo "$line" | awk -F: '{print $2}' | xargs)
        info "$vd_type $vd_num RAID: $raid_info"
    fi
    if echo "$line" | grep -qP '^\s*Size\s*:'; then
        size=$(echo "$line" | awk -F: '{print $2}' | xargs)
        info "$vd_type $vd_num Size: $size"
    fi
    if echo "$line" | grep -qP '^\s*Current Cache Policy\s*:'; then
        cache=$(echo "$line" | awk -F: '{print $2}' | xargs)
        # Check for WriteThrough which may indicate BBU issue
        if echo "$cache" | grep -q "WriteThrough"; then
            warn "$vd_type $vd_num cache: $cache (WriteThrough - check BBU)"
        fi
    fi
done <<< "$vd_output"

info "Total virtual drives: $vd_count"

# ----------------------------------------------------------
header "Physical Disk Check"
# ----------------------------------------------------------
pd_output=$(cli -PDList -aAll -NoLog)

slot=""
enclosure=""
media_errors=""
other_errors=""
pred_fail=""
fw_state=""
smart_alert=""
drive_temp=""
media_type=""

parse_disk() {
    local label="[${enclosure}:${slot}]"

    # Firmware state
    if [ -n "$fw_state" ]; then
        if echo "$fw_state" | grep -qiE "online.*spun up"; then
            ok "Disk $label: $fw_state"
        elif echo "$fw_state" | grep -qi "rebuild"; then
            warn "Disk $label: $fw_state (rebuilding)"
        elif echo "$fw_state" | grep -qiE "failed|offline"; then
            crit "Disk $label: $fw_state"
        elif echo "$fw_state" | grep -qi "hotspare"; then
            ok "Disk $label: $fw_state"
        else
            warn "Disk $label: $fw_state"
        fi
    fi

    # Error counters
    if [ "${media_errors:-0}" -gt 0 ]; then
        crit "Disk $label: $media_errors media error(s)"
    fi
    if [ "${other_errors:-0}" -gt 0 ]; then
        warn "Disk $label: $other_errors other error(s)"
    fi
    if [ "${pred_fail:-0}" -gt 0 ]; then
        crit "Disk $label: predictive failure count=$pred_fail"
    fi

    # SMART
    if [ -n "$smart_alert" ] && echo "$smart_alert" | grep -qi "yes"; then
        crit "Disk $label: SMART alert flagged!"
    fi

    # Temperature
    if [ -n "$drive_temp" ]; then
        temp_c=$(echo "$drive_temp" | grep -oP '^\d+')
        if [ -n "$temp_c" ]; then
            if [ "$temp_c" -ge 60 ]; then
                crit "Disk $label: temperature ${temp_c}C (>=60C)"
            elif [ "$temp_c" -ge 50 ]; then
                warn "Disk $label: temperature ${temp_c}C (>=50C)"
            fi
        fi
    fi
}

disk_count=0
while IFS= read -r line; do
    key=$(echo "$line" | awk -F: '{print $1}' | xargs 2>/dev/null || true)
    val=$(echo "$line" | awk -F: '{$1=""; print $0}' | xargs 2>/dev/null || true)

    case "$key" in
        "Enclosure Device ID")
            # If we already have a disk queued, process it
            if [ -n "$slot" ]; then
                parse_disk
            fi
            enclosure="$val"
            slot=""
            media_errors=""
            other_errors=""
            pred_fail=""
            fw_state=""
            smart_alert=""
            drive_temp=""
            media_type=""
            ;;
        "Slot Number")
            slot="$val"
            disk_count=$((disk_count + 1))
            ;;
        "Media Error Count") media_errors="$val" ;;
        "Other Error Count") other_errors="$val" ;;
        "Predictive Failure Count") pred_fail="$val" ;;
        "Firmware state") fw_state="$val" ;;
        "Drive Temperature") drive_temp="$val" ;;
        "Media Type") media_type="$val" ;;
    esac

    if echo "$line" | grep -q "S.M.A.R.T alert"; then
        smart_alert=$(echo "$line" | awk -F: '{print $NF}' | xargs)
    fi
done <<< "$pd_output"

# Process last disk
if [ -n "$slot" ]; then
    parse_disk
fi

info "Total physical disks: $disk_count"

# ----------------------------------------------------------
header "Rebuild Check"
# ----------------------------------------------------------
rebuild_output=$(cli -PDRbld -ShowProg -PhysDrv "[252:0,252:1,252:2,252:3,252:4,252:5,252:6,252:7]" -aAll -NoLog 2>&1 || true)

rebuilding=0
while IFS= read -r line; do
    if echo "$line" | grep -qi "rebuild progress"; then
        warn "Rebuild in progress: $line"
        rebuilding=1
    fi
done <<< "$rebuild_output"

if [ "$rebuilding" -eq 0 ]; then
    ok "No rebuilds in progress"
fi

# ----------------------------------------------------------
header "BBU (Battery Backup Unit) Check"
# ----------------------------------------------------------
bbu_output=$(cli -AdpBbuCmd -aAll -NoLog 2>&1)

if echo "$bbu_output" | grep -qi "not found\|no battery\|get bbu status failed"; then
    crit "BBU not found or not responding"
else
    # Battery state
    bbu_state=$(echo "$bbu_output" | grep -P '^Battery State\s*:' | awk -F: '{print $2}' | xargs)
    if [ -n "$bbu_state" ]; then
        if [ "$bbu_state" = "Optimal" ]; then
            ok "BBU state: $bbu_state"
        elif [ "$bbu_state" = "Learning" ]; then
            warn "BBU state: $bbu_state (learn cycle active)"
        else
            crit "BBU state: $bbu_state"
        fi
    fi

    # BBU temperature
    bbu_temp=$(echo "$bbu_output" | grep -P '^Temperature:\s*\d+' | grep -oP '\d+')
    if [ -n "${bbu_temp:-}" ]; then
        if [ "$bbu_temp" -ge 55 ]; then
            crit "BBU temperature: ${bbu_temp}C (>=55C)"
        elif [ "$bbu_temp" -ge 45 ]; then
            warn "BBU temperature: ${bbu_temp}C (>=45C)"
        else
            ok "BBU temperature: ${bbu_temp}C"
        fi
    fi

    # Voltage
    bbu_voltage=$(echo "$bbu_output" | grep -P '^Voltage:' | head -1 | grep -oP '\d+')
    if [ -n "${bbu_voltage:-}" ]; then
        info "BBU voltage: ${bbu_voltage} mV"
    fi

    # Key firmware status flags
    replacement=$(echo "$bbu_output" | grep "Battery Replacement required" | awk -F: '{print $2}' | xargs)
    if [ "${replacement:-No}" != "No" ]; then
        crit "BBU: Battery replacement required!"
    fi

    pack_fail=$(echo "$bbu_output" | grep "Pack is about to fail" | awk -F: '{print $2}' | xargs)
    if [ "${pack_fail:-No}" != "No" ]; then
        crit "BBU: Pack is about to fail!"
    fi

    pack_missing=$(echo "$bbu_output" | grep "Battery Pack Missing" | awk -F: '{print $2}' | xargs)
    if [ "${pack_missing:-No}" != "No" ]; then
        crit "BBU: Battery pack missing!"
    fi

    remaining_low=$(echo "$bbu_output" | grep "Remaining Capacity Low" | awk -F: '{print $2}' | xargs)
    if [ "${remaining_low:-No}" != "No" ]; then
        warn "BBU: Remaining capacity low"
    fi

    no_cache_space=$(echo "$bbu_output" | grep "No space to cache offload" | awk -F: '{print $2}' | xargs)
    if [ "${no_cache_space:-No}" != "No" ]; then
        warn "BBU: No space to cache offload"
    fi

    i2c_errors=$(echo "$bbu_output" | grep "I2c Errors Detected" | awk -F: '{print $2}' | xargs)
    if [ "${i2c_errors:-No}" != "No" ]; then
        warn "BBU: I2C errors detected"
    fi

    learn_status=$(echo "$bbu_output" | grep "Learn Cycle Status" | awk -F: '{print $2}' | xargs)
    if [ -n "${learn_status:-}" ] && [ "$learn_status" != "OK" ]; then
        warn "BBU learn cycle status: $learn_status"
    fi

    # Capacitance (for CVPM/supercap units)
    capacitance=$(echo "$bbu_output" | grep -P '^\s*Capacitance\s*:' | awk -F: '{print $2}' | xargs)
    if [ -n "${capacitance:-}" ]; then
        cap_val=$(echo "$capacitance" | grep -oP '\d+')
        if [ -n "$cap_val" ]; then
            if [ "$cap_val" -lt 50 ]; then
                crit "BBU capacitance: ${cap_val}% (< 50%)"
            elif [ "$cap_val" -lt 70 ]; then
                warn "BBU capacitance: ${cap_val}% (< 70%)"
            else
                ok "BBU capacitance: ${cap_val}%"
            fi
        fi
    fi
fi

# ----------------------------------------------------------
header "Foreign Config Check"
# ----------------------------------------------------------
foreign_output=$(cli -CfgForeign -Scan -aAll -NoLog 2>&1 || true)
foreign_count=$(echo "$foreign_output" | grep -oP 'Total Foreign Configs Found\s*:\s*\K\d+' || echo "0")
if [ "${foreign_count:-0}" -gt 0 ]; then
    warn "$foreign_count foreign config(s) detected (may need import or clear)"
else
    ok "No foreign configs"
fi

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
header "Summary"
echo ""
if [ ${#CRITICALS[@]} -gt 0 ]; then
    echo -e "${RED}${BOLD}CRITICAL issues (${#CRITICALS[@]}):${NC}"
    for msg in "${CRITICALS[@]}"; do
        echo -e "  ${RED}- $msg${NC}"
    done
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}Warnings (${#WARNINGS[@]}):${NC}"
    for msg in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}- $msg${NC}"
    done
fi
if [ ${#CRITICALS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All checks passed. RAID system is healthy.${NC}"
fi

echo ""
exit $EXIT_CODE
