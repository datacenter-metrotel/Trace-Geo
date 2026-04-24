#!/bin/bash
# trace-geo-dual.sh — Traceroute geográfico Dual (Normal y TCP)

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo -e "\033[0;31mUso: $0 <dominio-o-ip> [puerto-tcp (default: 443)]\033[0m"
    exit 1
fi

TARGET="$1"
TCP_PORT="${2:-443}"

BLUE='\033[0;34m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; 
YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# Chequeo de privilegios para el traceroute TCP
if [ "$EUID" -ne 0 ]; then
    echo -e "\n${YELLOW}⚠️  Aviso: Para el traceroute TCP se requieren privilegios elevados (raw sockets).${RESET}"
    echo -e "${YELLOW}Si el comando falla, cancelá y volvé a ejecutar el script con 'sudo'.${RESET}\n"
fi

get_cable_name() {
    local from_cc="$1" to_cc="$2" isp="$3"
    isp="${isp,,}"
    if [[ "$from_cc" == "AR" && "$to_cc" == "US" ]]; then
        if [[ "$isp" == *"cirion"* || "$isp" == *"level 3"* ]]; then echo "Cable SAC (South American Crossing)"; 
        elif [[ "$isp" == *"telxius"* ]]; then echo "Cable SAm-1";
        else echo "Cable Panamericano / Seabras-1"; fi
    elif [[ "$to_cc" == "IN" ]]; then echo "Cable SEA-ME-WE 5 / AAE-1";
    else echo "Troncal Internacional"; fi
}

geo_lookup() {
    curl -sf --max-time 2 "http://ip-api.com/json/${1}?fields=status,city,country,countryCode,isp" || echo '{"status":"fail"}'
}

# --- Función Principal de Trazado ---
run_trace() {
    local mode="$1"
    local target="$2"
    local port="$3"
    local trace_cmd=""

    if [ "$mode" == "normal" ]; then
        echo -e "${BOLD}${YELLOW}Rastreando ruta física (UDP Normal) hacia: ${CYAN}${target}${RESET}\n"
        trace_cmd="traceroute -n -q 1 -w 2 $target"
    else
        echo -e "${BOLD}${YELLOW}Rastreando ruta física (TCP Puerto ${port}) hacia: ${CYAN}${target}${RESET}\n"
        # Usamos sudo internamente por si el script no se corrió como root, para intentar elevar privilegios
        trace_cmd="sudo traceroute -T -p $port -n -q 1 -w 2 $target"
    fi

    printf "${BOLD}%-4s %-16s %-9s %-22s %-32s %-20s${RESET}\n" "#" "IP" "RTT" "Ciudad" "País / Red" "Enlace"
    echo -e "${DIM}$(printf '─%.0s' {1..115})${RESET}"

    local prev_ms=0
    local prev_cc=""

    # Ejecutamos el comando de traceroute dinámico y leemos su salida
    while read -r hop ip ms; do
        local curr_ms=$(echo "$ms" | sed 's/[^0-9.]//g' | cut -d. -f1)
        [ -z "$curr_ms" ] && curr_ms=0

        local city="-"
        local country="-"
        local cc=""
        local isp=""

        if [[ "$ip" =~ ^(10|127)\. ]] || [[ "$ip" =~ ^192\.168\. ]] || \
           [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
           [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
            city="IP Privada"
            country="IP Privada"
            cc="PRIVATE" 
        else
            local geo=$(geo_lookup "$ip")
            if [ "$(echo "$geo" | jq -r '.status // "fail"')" == "success" ]; then
                city=$(echo "$geo" | jq -r '.city // ""')
                country=$(echo "$geo" | jq -r '.country // ""')
                cc=$(echo "$geo" | jq -r '.countryCode // ""')
                isp=$(echo "$geo" | jq -r '.isp // ""')
                
                [ -z "$city" ] && city="Ubicación no registrada"
                [ -z "$country" ] && country="Ubicación no registrada"
            else
                city="Ubicación no registrada"
                country="Ubicación no registrada"
            fi
        fi

        local diff=$(( curr_ms - prev_ms ))
        local jump_type=""
        
        if [ -n "$prev_cc" ] && [ "$prev_cc" != "PRIVATE" ]; then
            if [ "$cc" != "PRIVATE" ] && [ "$prev_cc" != "$cc" ]; then
                jump_type="ocean"
            elif [ "$diff" -gt 85 ]; then
                jump_type="ocean"
            fi
        fi

        local type_out=""
        if [ "$jump_type" == "ocean" ]; then
            local cable=$(get_cable_name "$prev_cc" "$cc" "$isp")
            echo -e " ${BLUE}🚢 [SALTANDO OCÉANO] >>> ${BOLD}${cable}${RESET}"
            type_out="${BLUE}🌊 Submarino${RESET}"
        else
            type_out="${GREEN}🌍 Terrestre${RESET}"
        fi

        printf "${BOLD}%-4s${RESET} %-16s %-9s %-22s %-32s %b\n" "$hop" "$ip" "${curr_ms}ms" "${city:0:22}" "${country:0:32}" "$type_out"

        prev_ms=$curr_ms
        prev_cc=$cc

    done < <($trace_cmd | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1, $2, $3}')

    echo -e "${DIM}$(printf '─%.0s' {1..115})${RESET}\n"
}

# 1. Pasada Normal (UDP)
run_trace "normal" "$TARGET" ""

# 2. Pasada TCP
run_trace "tcp" "$TARGET" "$TCP_PORT"