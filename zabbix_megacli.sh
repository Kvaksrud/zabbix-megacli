#!/bin/bash
#
# MegaCLI Zabbix Integration Script
#
# Usage:
#   zabbix_megacli.sh cache                              - Refresh cached megacli data (run as root via cron)
#   zabbix_megacli.sh discover <adapters|vd|pd|bbu>      - LLD discovery JSON
#   zabbix_megacli.sh get adapter <id> <key>              - Get adapter metric
#   zabbix_megacli.sh get vd <adapter> <vd_id> <key>      - Get virtual drive metric
#   zabbix_megacli.sh get pd <adapter> <enc:slot> <key>   - Get physical disk metric
#   zabbix_megacli.sh get bbu <adapter> <key>             - Get BBU metric
#

MEGACLI="megacli"
CACHE_DIR="/var/tmp/megacli_cache"
CACHE_MAX_AGE=600  # seconds

die() { echo "ZBX_NOTSUPPORTED: $1" >&2; exit 1; }

# ---- Cache management ----

cmd_cache() {
    mkdir -p "$CACHE_DIR"

    # Detect sudo need
    local sudo_prefix=""
    local test_out
    test_out=$($MEGACLI -AdpCount -NoLog 2>/dev/null || true)
    if echo "$test_out" | grep -q "Controller Count: 0"; then
        sudo_prefix="sudo"
    fi

    local count
    count=$(${sudo_prefix} $MEGACLI -AdpCount -NoLog 2>/dev/null | grep -oP 'Controller Count:\s*\K\d+' || echo "0")
    echo "$count" > "$CACHE_DIR/adp_count"

    for (( i=0; i<count; i++ )); do
        ${sudo_prefix} $MEGACLI -AdpAllInfo -a"$i" -NoLog 2>/dev/null > "$CACHE_DIR/adapter_${i}.txt"
        ${sudo_prefix} $MEGACLI -LDInfo -Lall -a"$i" -NoLog 2>/dev/null > "$CACHE_DIR/ld_${i}.txt"
        ${sudo_prefix} $MEGACLI -PDList -a"$i" -NoLog 2>/dev/null > "$CACHE_DIR/pd_${i}.txt"
        ${sudo_prefix} $MEGACLI -AdpBbuCmd -a"$i" -NoLog 2>/dev/null > "$CACHE_DIR/bbu_${i}.txt"
    done

    chmod -R 644 "$CACHE_DIR"/*.txt "$CACHE_DIR"/adp_count 2>/dev/null
    chmod 755 "$CACHE_DIR"
}

check_cache() {
    [ -f "$CACHE_DIR/adp_count" ] || die "Cache not found. Run: zabbix_megacli.sh cache"
    local age=$(( $(date +%s) - $(stat -c %Y "$CACHE_DIR/adp_count") ))
    [ "$age" -gt "$CACHE_MAX_AGE" ] && die "Cache stale (${age}s old)"
}

adp_count() {
    cat "$CACHE_DIR/adp_count" 2>/dev/null || echo "0"
}

# ---- Discovery ----

discover_adapters() {
    check_cache
    local count
    count=$(adp_count)
    local first=1
    echo -n '['
    for (( i=0; i<count; i++ )); do
        local product
        product=$(grep "Product Name" "$CACHE_DIR/adapter_${i}.txt" | awk -F: '{print $2}' | xargs)
        [ "$first" -eq 1 ] && first=0 || echo -n ','
        printf '{"{#ADAPTER_ID}":"%d","{#ADAPTER_NAME}":"%s"}' "$i" "$product"
    done
    echo ']'
}

discover_vd() {
    check_cache
    local count
    count=$(adp_count)
    local first=1
    echo -n '['
    for (( a=0; a<count; a++ )); do
        local file="$CACHE_DIR/ld_${a}.txt"
        [ -f "$file" ] || continue

        local vd_id="" vd_type="" raid_level="" size=""
        emit_vd() {
            if [ -n "$vd_id" ]; then
                [ "$first" -eq 1 ] && first=0 || echo -n ','
                printf '{"{#ADAPTER_ID}":"%d","{#VD_ID}":"%s","{#VD_TYPE}":"%s","{#VD_RAID}":"%s","{#VD_SIZE}":"%s"}' \
                    "$a" "$vd_id" "$vd_type" "$raid_level" "$size"
            fi
        }
        while IFS= read -r line; do
            if echo "$line" | grep -qP '^Virtual Drive:'; then
                emit_vd
                vd_id=$(echo "$line" | grep -oP ':\s*\K\d+' | head -1)
                vd_type="VD"; raid_level=""; size=""
            elif echo "$line" | grep -qP '^CacheCade Virtual Drive:'; then
                emit_vd
                vd_id=$(echo "$line" | grep -oP ':\s*\K\d+' | head -1)
                vd_type="CacheCade"; raid_level=""; size=""
            elif echo "$line" | grep -qP '^\s*RAID Level\s*:'; then
                raid_level=$(echo "$line" | awk -F: '{$1=""; print $0}' | xargs)
            elif echo "$line" | grep -qP '^\s*Size\s*:'; then
                size=$(echo "$line" | awk -F: '{print $2}' | xargs)
            fi
        done < "$file"
        emit_vd
    done
    echo ']'
}

discover_pd() {
    check_cache
    local count
    count=$(adp_count)
    local first=1
    echo -n '['
    for (( a=0; a<count; a++ )); do
        local file="$CACHE_DIR/pd_${a}.txt"
        [ -f "$file" ] || continue

        local enc="" slot="" media_type="" device_id=""
        while IFS= read -r line; do
            local key val
            key=$(echo "$line" | awk -F: '{print $1}' | xargs 2>/dev/null || true)
            val=$(echo "$line" | awk -F: '{$1=""; print $0}' | xargs 2>/dev/null || true)

            case "$key" in
                "Enclosure Device ID")
                    # Emit previous disk if we have one
                    if [ -n "$slot" ]; then
                        [ "$first" -eq 1 ] && first=0 || echo -n ','
                        printf '{"{#ADAPTER_ID}":"%d","{#ENCLOSURE}":"%s","{#SLOT}":"%s","{#MEDIA_TYPE}":"%s","{#DEVICE_ID}":"%s"}' \
                            "$a" "$enc" "$slot" "$media_type" "$device_id"
                    fi
                    enc="$val"; slot=""; media_type=""; device_id=""
                    ;;
                "Slot Number") slot="$val" ;;
                "Device Id") device_id="$val" ;;
                "Media Type") media_type="$val" ;;
            esac
        done < "$file"

        # Emit last disk
        if [ -n "$slot" ]; then
            [ "$first" -eq 1 ] && first=0 || echo -n ','
            printf '{"{#ADAPTER_ID}":"%d","{#ENCLOSURE}":"%s","{#SLOT}":"%s","{#MEDIA_TYPE}":"%s","{#DEVICE_ID}":"%s"}' \
                "$a" "$enc" "$slot" "$media_type" "$device_id"
        fi
    done
    echo ']'
}

discover_bbu() {
    check_cache
    local count
    count=$(adp_count)
    local first=1
    echo -n '['
    for (( a=0; a<count; a++ )); do
        local file="$CACHE_DIR/bbu_${a}.txt"
        [ -f "$file" ] || continue
        # Check if BBU actually exists
        if grep -q "Battery State" "$file" 2>/dev/null; then
            local bbu_type
            bbu_type=$(grep "BatteryType:" "$file" | awk -F: '{print $2}' | xargs)
            [ "$first" -eq 1 ] && first=0 || echo -n ','
            printf '{"{#ADAPTER_ID}":"%d","{#BBU_TYPE}":"%s"}' "$a" "$bbu_type"
        fi
    done
    echo ']'
}

# ---- Getters ----

get_adapter() {
    local adp="$1" key="$2"
    check_cache
    local file="$CACHE_DIR/adapter_${adp}.txt"
    [ -f "$file" ] || die "No cache for adapter $adp"

    case "$key" in
        degraded)       grep -P '^\s*Degraded\s*:' "$file" | awk '{print $NF}' ;;
        offline)        grep -P '^\s*Offline\s*:' "$file" | awk '{print $NF}' ;;
        critical_disks) grep -P '^\s*Critical Disks\s*:' "$file" | awk '{print $NF}' ;;
        failed_disks)   grep -P '^\s*Failed Disks\s*:' "$file" | awk '{print $NF}' ;;
        roc_temp)       grep -oP 'ROC temperature\s*:\s*\K\d+' "$file" ;;
        mem_correctable)   grep "Memory Correctable Errors" "$file" | awk -F: '{print $2}' | tr -d ' ' ;;
        mem_uncorrectable) grep "Memory Uncorrectable Errors" "$file" | awk -F: '{print $2}' | tr -d ' ' ;;
        virtual_drives) grep -P '^\s*Virtual Drives\s*:' "$file" | awk '{print $NF}' ;;
        physical_disks) grep -P '^\s*Disks\s*:' "$file" | awk '{print $NF}' ;;
        product_name)   grep "Product Name" "$file" | awk -F: '{print $2}' | xargs ;;
        serial)         grep "Serial No" "$file" | awk -F: '{print $2}' | xargs ;;
        fw_version)     grep "FW Version" "$file" | head -1 | awk -F: '{print $2}' | xargs ;;
        *) die "Unknown adapter key: $key" ;;
    esac
}

get_vd() {
    local adp="$1" vd_id="$2" key="$3"
    check_cache
    local file="$CACHE_DIR/ld_${adp}.txt"
    [ -f "$file" ] || die "No cache for adapter $adp LD"

    # Extract the block for the specific VD
    local in_vd=0
    local state="" cache_policy="" raid_level="" size=""
    while IFS= read -r line; do
        if echo "$line" | grep -qP '^(Virtual Drive|CacheCade Virtual Drive):\s*'"$vd_id"'\b'; then
            in_vd=1
            continue
        fi
        # Next VD starts - stop
        if [ "$in_vd" -eq 1 ] && echo "$line" | grep -qP '^(Virtual Drive|CacheCade Virtual Drive):'; then
            break
        fi
        if [ "$in_vd" -eq 1 ]; then
            local k
            k=$(echo "$line" | awk -F: '{print $1}' | xargs 2>/dev/null || true)
            case "$k" in
                "State") state=$(echo "$line" | awk -F: '{print $2}' | xargs) ;;
                "Current Cache Policy") cache_policy=$(echo "$line" | awk -F: '{print $2}' | xargs) ;;
                "RAID Level") raid_level=$(echo "$line" | awk -F: '{$1=""; print $0}' | xargs) ;;
                "Size") size=$(echo "$line" | awk -F: '{print $2}' | xargs) ;;
            esac
        fi
    done < "$file"

    case "$key" in
        state)        echo "$state" ;;
        cache_policy) echo "$cache_policy" ;;
        raid_level)   echo "$raid_level" ;;
        size)         echo "$size" ;;
        state_num)
            # Numeric: 0=Optimal, 1=Degraded, 2=Offline, 3=Other
            case "$state" in
                Optimal) echo 0 ;; Degraded) echo 1 ;; Offline) echo 2 ;; *) echo 3 ;;
            esac
            ;;
        *) die "Unknown VD key: $key" ;;
    esac
}

get_pd() {
    local adp="$1" encslot="$2" key="$3"
    check_cache
    local file="$CACHE_DIR/pd_${adp}.txt"
    [ -f "$file" ] || die "No cache for adapter $adp PD"

    local target_enc="${encslot%%:*}"
    local target_slot="${encslot##*:}"

    local in_pd=0 cur_enc="" cur_slot=""
    local fw_state="" media_errors="" other_errors="" pred_fail="" smart="" temp="" media_type=""

    while IFS= read -r line; do
        local k val
        k=$(echo "$line" | awk -F: '{print $1}' | xargs 2>/dev/null || true)
        val=$(echo "$line" | awk -F: '{$1=""; print $0}' | xargs 2>/dev/null || true)

        case "$k" in
            "Enclosure Device ID")
                if [ "$in_pd" -eq 1 ] && [ "$cur_enc" = "$target_enc" ] && [ "$cur_slot" = "$target_slot" ]; then
                    break
                fi
                cur_enc="$val"; cur_slot=""; in_pd=0
                fw_state=""; media_errors=""; other_errors=""; pred_fail=""; smart=""; temp=""
                ;;
            "Slot Number")
                cur_slot="$val"
                [ "$cur_enc" = "$target_enc" ] && [ "$cur_slot" = "$target_slot" ] && in_pd=1
                ;;
        esac

        if [ "$in_pd" -eq 1 ]; then
            case "$k" in
                "Firmware state") fw_state="$val" ;;
                "Media Error Count") media_errors="$val" ;;
                "Other Error Count") other_errors="$val" ;;
                "Predictive Failure Count") pred_fail="$val" ;;
                "Drive Temperature") temp=$(echo "$val" | grep -oP '^\d+') ;;
                "Media Type") media_type="$val" ;;
            esac
            if echo "$line" | grep -q "S.M.A.R.T alert"; then
                smart=$(echo "$line" | awk -F: '{print $NF}' | xargs)
            fi
        fi
    done < "$file"

    case "$key" in
        state)               echo "$fw_state" ;;
        state_num)
            case "$fw_state" in
                "Online, Spun Up")  echo 0 ;;
                "Hotspare, Spun Up"|"Hotspare, Spun Down") echo 0 ;;
                *Rebuild*)          echo 1 ;;
                *Failed*|*Offline*) echo 2 ;;
                *)                  echo 3 ;;
            esac
            ;;
        media_errors)        echo "${media_errors:-0}" ;;
        other_errors)        echo "${other_errors:-0}" ;;
        predictive_failures) echo "${pred_fail:-0}" ;;
        smart_alert)
            case "$smart" in
                Yes) echo 1 ;; *) echo 0 ;;
            esac
            ;;
        temperature)         echo "${temp:-0}" ;;
        media_type)          echo "$media_type" ;;
        *) die "Unknown PD key: $key" ;;
    esac
}

get_bbu() {
    local adp="$1" key="$2"
    check_cache
    local file="$CACHE_DIR/bbu_${adp}.txt"
    [ -f "$file" ] || die "No cache for adapter $adp BBU"

    case "$key" in
        state)
            grep -P '^Battery State\s*:' "$file" | awk -F: '{print $2}' | xargs
            ;;
        state_num)
            local s
            s=$(grep -P '^Battery State\s*:' "$file" | awk -F: '{print $2}' | xargs)
            case "$s" in
                Optimal) echo 0 ;; Learning) echo 1 ;; Degraded) echo 2 ;; *) echo 3 ;;
            esac
            ;;
        temperature)
            grep -P '^Temperature:\s*\d+' "$file" | grep -oP '\d+' | head -1
            ;;
        voltage)
            grep -P '^Voltage:' "$file" | head -1 | grep -oP '\d+'
            ;;
        capacitance)
            grep -P '^\s*Capacitance\s*:' "$file" | awk -F: '{print $2}' | xargs | grep -oP '\d+'
            ;;
        replacement_required)
            local v
            v=$(grep "Battery Replacement required" "$file" | awk -F: '{print $2}' | xargs)
            [ "$v" = "Yes" ] && echo 1 || echo 0
            ;;
        pack_failing)
            local v
            v=$(grep "Pack is about to fail" "$file" | awk -F: '{print $2}' | xargs)
            [ "$v" = "Yes" ] && echo 1 || echo 0
            ;;
        pack_missing)
            local v
            v=$(grep "Battery Pack Missing" "$file" | awk -F: '{print $2}' | xargs)
            [ "$v" = "Yes" ] && echo 1 || echo 0
            ;;
        learn_cycle_status)
            grep "Learn Cycle Status" "$file" | awk -F: '{print $2}' | xargs
            ;;
        remaining_capacity_low)
            local v
            v=$(grep "Remaining Capacity Low" "$file" | awk -F: '{print $2}' | xargs)
            [ "$v" = "Yes" ] && echo 1 || echo 0
            ;;
        *) die "Unknown BBU key: $key" ;;
    esac
}

# ---- Main dispatch ----

case "${1:-}" in
    cache)
        cmd_cache
        ;;
    discover)
        case "${2:-}" in
            adapters) discover_adapters ;;
            vd)       discover_vd ;;
            pd)       discover_pd ;;
            bbu)      discover_bbu ;;
            *) die "Usage: $0 discover <adapters|vd|pd|bbu>" ;;
        esac
        ;;
    get)
        case "${2:-}" in
            adapter) get_adapter "${3:-}" "${4:-}" ;;
            vd)      get_vd "${3:-}" "${4:-}" "${5:-}" ;;
            pd)      get_pd "${3:-}" "${4:-}" "${5:-}" ;;
            bbu)     get_bbu "${3:-}" "${4:-}" ;;
            *) die "Usage: $0 get <adapter|vd|pd|bbu> ..." ;;
        esac
        ;;
    *)
        echo "Usage: $0 <cache|discover|get> ..."
        exit 1
        ;;
esac
