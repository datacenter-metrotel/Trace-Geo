#!/bin/bash
# trace-geo.sh — Versión definitiva con múltiples triggers oceánicos

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo -e "\033[0;31mUso: $0 <dominio-o-ip>\033[0m"
    exit 1
fi

TARGET="$1"

BLUE='\033[0;34m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; 
YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

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

echo -e "\n${BOLD}${YELLOW}Rastreando ruta física hacia: ${CYAN}${TARGET}${RESET}\n"
printf "${BOLD}%-4s %-16s %-9s %-22s %-32s %-20s${RESET}\n" "#" "IP" "RTT" "Ciudad" "País / Red" "Enlace"
echo -e "${DIM}$(printf '─%.0s' {1..115})${RESET}"

prev_ms=0; prev_cc=""

while read -r hop ip ms; do
    curr_ms=$(echo "$ms" | sed 's/[^0-9.]//g' | cut -d. -f1)
    [ -z "$curr_ms" ] && curr_ms=0

    if [[ "$ip" =~ ^(10|127)\. ]] || [[ "$ip" =~ ^192\.168\. ]] || \
       [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
       [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
        city="IP Privada"
        country="IP Privada"
        cc="PRIVATE" 
        isp=""
    else
        geo=$(geo_lookup "$ip")
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
            cc=""
            isp=""
        fi
    fi

    diff=$(( curr_ms - prev_ms ))
    jump_type=""
    
    # Desacoplamos la validación de latencia de la de país.
    if [ -n "$prev_cc" ] && [ "$prev_cc" != "PRIVATE" ]; then
        # 1. Si el código de país cambia (y es una IP pública), disparamos la alerta de fibra
        if [ "$cc" != "PRIVATE" ] && [ "$prev_cc" != "$cc" ]; then
            jump_type="ocean"
        # 2. Si la latencia se dispara >85ms dentro del mismo país, la geolocalización miente y estamos cruzando el charco
        elif [ "$diff" -gt 85 ]; then
            jump_type="ocean"
        fi
    fi

    if [ "$jump_type" == "ocean" ]; then
        cable=$(get_cable_name "$prev_cc" "$cc" "$isp")
        echo -e " ${BLUE}🚢 [SALTANDO OCÉANO] >>> ${BOLD}${cable}${RESET}"
        type_out="${BLUE}🌊 Submarino${RESET}"
    else
        type_out="${GREEN}🌍 Terrestre${RESET}"
    fi

    printf "${BOLD}%-4s${RESET} %-16s %-9s %-22s %-32s %b\n" "$hop" "$ip" "${curr_ms}ms" "${city:0:22}" "${country:0:32}" "$type_out"

    prev_ms=$curr_ms; prev_cc=$cc

done < <(traceroute -n -q 1 -w 2 "$TARGET" | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1, $2, $3}')

echo -e "${DIM}$(printf '─%.0s' {1..115})${RESET}\n"
