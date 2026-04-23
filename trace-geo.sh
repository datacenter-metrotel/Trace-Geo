#!/bin/bash
# trace-geo.sh — Traceroute geográfico con clasificación de enlaces
# Requiere: traceroute, curl, jq, bc, python3
#
# NOTA SOBRE GEOLOCALIZACIÓN DE IPs:
#   Operadoras multinacionales (Telefónica, NTT, Lumen, etc.) registran sus
#   bloques de IPs en su país sede aunque los routers estén en otro continente.
#   El script usa la LATENCIA FÍSICA como fuente de verdad, no el país de la IP.
#   Física: fibra ≈ 200 000 km/s → imposible cruzar el Atlántico (<10 000 km)
#   en menos de ~50 ms. Si el delta es <30ms, es fibra terrestre local.

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Uso: $0 <dominio-o-ip>"
    echo "Ejemplo: $0 google.com"
    exit 1
fi

TARGET="$1"

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; ORANGE='\033[0;33m'; YELLOW='\033[1;33m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'
MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── Verificar dependencias ────────────────────────────────────────────────────
for cmd in traceroute curl jq bc; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Falta: $cmd  →  sudo apt install $cmd${RESET}" >&2
        exit 1
    fi
done

# ── Cache geo en /tmp ─────────────────────────────────────────────────────────
geo_lookup() {
    local ip="$1"
    local cache="/tmp/geo_${ip//\./_}.json"
    if [ ! -f "$cache" ]; then
        curl -sf --max-time 3 \
            "http://ip-api.com/json/${ip}?fields=city,country,countryCode,isp,lat,lon,as" \
            > "$cache" 2>/dev/null || echo '{}' > "$cache"
    fi
    cat "$cache"
}

# ── Distancia haversine entre dos pares lat/lon ───────────────────────────────
haversine_km() {
    local lat1="$1" lon1="$2" lat2="$3" lon2="$4"
    python3 -c "
import math
lat1,lon1,lat2,lon2=$lat1,$lon1,$lat2,$lon2
if lat1==0 and lon1==0: print(0); exit()
R=6371
dlat=math.radians(lat2-lat1); dlon=math.radians(lon2-lon1)
a=math.sin(dlat/2)**2+math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(dlon/2)**2
print(int(2*R*math.asin(math.sqrt(max(0,min(1,a))))))
" 2>/dev/null || echo 0
}

# ── Clasificar tipo de enlace ─────────────────────────────────────────────────
#
# CRITERIO PRINCIPAL: latencia física, no country code de la IP.
#
# Física del cable de fibra óptica:
#   velocidad efectiva ≈ 200 000 km/s  →  1 ms ≈ 100 km de propagación mínima
#   BUE→Madrid  ≈ 10 000 km → mínimo ~100 ms de delta RTT solo propagación
#   BUE→Miami   ≈  7 000 km → mínimo ~70 ms
#   → Si delta < 30ms: IMPOSIBLE cruzar cualquier océano. Es terrestre local.
#   → Si delta ≥ 60ms + geo_dist > 2000km: cruce oceánico probable.
#
classify_link() {
    local prev_ms="$1" curr_ms="$2"
    local prev_cc="$3" curr_cc="$4"
    local prev_lat="$5" prev_lon="$6"
    local curr_lat="$7" curr_lon="$8"

    # Delta absoluto (ECMP puede dar rutas asimétricas con ms negativos)
    local diff raw_diff
    raw_diff=$(echo "$curr_ms - $prev_ms" | bc 2>/dev/null || echo 0)
    diff=$(echo "$raw_diff" | sed 's/^-//')
    diff=${diff:-0}

    # Detección satelital: latencia absoluta muy alta
    if (( $(echo "$curr_ms > 500" | bc -l 2>/dev/null || echo 0) )); then
        echo "satellite"; return
    fi

    # Distancia geodésica entre coordenadas de geo-IP
    local geo_dist
    geo_dist=$(haversine_km "$prev_lat" "$prev_lon" "$curr_lat" "$curr_lon")

    # REGLA 1: delta < 30ms → terrestre local, sin importar el country code.
    #   (Cubre IPs de Telefónica ES en Argentina, NTT JP en USA, etc.)
    if (( $(echo "$diff < 30" | bc -l 2>/dev/null || echo 0) )); then
        echo "land"; return
    fi

    # REGLA 2: delta ≥ 60ms + distancia geo > 2000km → cruce oceánico
    if (( $(echo "$diff >= 60" | bc -l 2>/dev/null || echo 0) )); then
        if [ "$geo_dist" -gt 2000 ] 2>/dev/null; then
            echo "ocean"
        elif [ "$prev_cc" != "$curr_cc" ] && [ -n "$prev_cc" ] && [ -n "$curr_cc" ]; then
            echo "international"
        else
            echo "land"
        fi
        return
    fi

    # REGLA 3: delta 30–59ms
    if [ "$prev_cc" != "$curr_cc" ] && [ -n "$prev_cc" ] && [ -n "$curr_cc" ] \
       && [ "${geo_dist:-0}" -gt 500 ] 2>/dev/null; then
        echo "international"
    else
        echo "land"
    fi
}

# ── Barra de latencia ─────────────────────────────────────────────────────────
latency_bar() {
    local ms="$1" max=300 width=12
    local filled=$(( ms * width / max ))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled ))
    local color
    if   [ "$ms" -lt 30  ]; then color="$GREEN"
    elif [ "$ms" -lt 100 ]; then color="$YELLOW"
    elif [ "$ms" -lt 200 ]; then color="$ORANGE"
    else                          color="$RED"
    fi
    printf "${color}"; printf '█%.0s' $(seq 1 "$filled" 2>/dev/null || true)
    printf "${DIM}";   printf '░%.0s' $(seq 1 "$empty"  2>/dev/null || true)
    printf "${RESET}"
}

# ── Icono de tipo ─────────────────────────────────────────────────────────────
type_icon() {
    case "$1" in
        local)         echo -e "${MAGENTA}🏠 Red local      ${RESET}" ;;
        land)          echo -e "${GREEN}🌍 Fibra terrestre${RESET}" ;;
        international) echo -e "${CYAN}✈  Internacional  ${RESET}" ;;
        ocean)         echo -e "${BLUE}🌊 Cable oceánico ${RESET}" ;;
        satellite)     echo -e "${YELLOW}🛰  Satélite       ${RESET}" ;;
        *)             echo -e "${DIM}?  Desconocido    ${RESET}" ;;
    esac
}

# ── Encabezado ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║          TRACEROUTE GEOGRÁFICO  →  ${CYAN}${TARGET}${YELLOW}${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
printf "${BOLD}%-3s  %-16s  %-7s  %-14s  %-20s  %-18s  %s${RESET}\n" \
       "#" "IP" "ms" "Latencia" "Ciudad" "País" "Tipo de enlace"
echo -e "${DIM}$(printf '─%.0s' {1..105})${RESET}"

# ── Variables de estado ───────────────────────────────────────────────────────
prev_ms=0
prev_cc=""
prev_country_name=""
prev_lat=0
prev_lon=0
hop_n=0
total_ocean_hops=0
total_intl_hops=0
last_country_name=""

# ── Procesado ─────────────────────────────────────────────────────────────────
while IFS= read -r line; do
    ip=$(echo "$line" | awk '{print $1}')
    raw_ms=$(echo "$line" | awk '{print $2}')

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    [[ "$raw_ms" == "*" ]] && continue

    curr_ms=$(echo "$raw_ms" | sed 's/[^0-9.]//g' | cut -d. -f1)
    [ -z "$curr_ms" ] && curr_ms=0
    hop_n=$(( hop_n + 1 ))

    geo_warn=""
    display_country=""

    # ── IP privada ────────────────────────────────────────────────────────────
    if [[ "$ip" =~ ^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.64\.) ]]; then
        city="Red Local"; country="–"; isp=""; cc=""; lat=0; lon=0
        link_type="local"
        display_country="–"

    # ── IP pública ────────────────────────────────────────────────────────────
    else
        geo=$(geo_lookup "$ip")
        city=$(echo "$geo" | jq -r '.city // "N/A"')
        country=$(echo "$geo" | jq -r '.country // "N/A"')
        cc=$(echo "$geo" | jq -r '.countryCode // ""')
        isp=$(echo "$geo" | jq -r '.isp // ""' | cut -c1-16)
        lat=$(echo "$geo" | jq -r '.lat // 0')
        lon=$(echo "$geo" | jq -r '.lon // 0')
        display_country="$country"

        if [ "$hop_n" -eq 1 ]; then
            link_type="land"
        else
            link_type=$(classify_link "$prev_ms" "$curr_ms" \
                                      "$prev_cc" "$cc" \
                                      "$prev_lat" "$prev_lon" \
                                      "$lat" "$lon")
        fi

        # ── Detectar IP mal geolocalizada ─────────────────────────────────────
        # Si el country code cambió pero la latencia es físicamente imposible
        # para ese salto intercontinental → IP registrada en sede corporativa.
        # IMPORTANTE: no pisamos $cc con $prev_cc porque necesitamos el cc real
        # para detectar correctamente el cambio de país en el hop siguiente.
        # Solo cambiamos display_country para lo que se muestra en pantalla.
        if [ "$cc" != "$prev_cc" ] && [ -n "$prev_cc" ] && [ "$link_type" = "land" ]; then
            local_diff=$(echo "$curr_ms - $prev_ms" | bc 2>/dev/null | sed 's/^-//')
            local_diff=${local_diff:-0}
            if (( $(echo "$local_diff < 30" | bc -l 2>/dev/null || echo 0) )); then
                geo_warn="${DIM} ⚠ IP de ${country} (sede corporativa, router en ${prev_country_name:-red local})${RESET}"
                display_country="${prev_country_name:-?}"
                # NO pisamos cc: el país real de la IP lo usamos para el
                # tracking, así el salto siguiente detecta correctamente
                # si hay un cambio de país genuino.
            fi
        fi

        # Contar países distintos visitados (ocean también es internacional)
        [ "$link_type" = "ocean" ]         && total_ocean_hops=$(( total_ocean_hops + 1 ))
        # Un cruce oceánico implica cambio de país → siempre sumar a intl
        if [ "$link_type" = "international" ] || [ "$link_type" = "ocean" ] || [ "$link_type" = "satellite" ]; then
            # Solo contar si realmente cambia el país (evitar doble conteo
            # cuando varios hops seguidos son del mismo país extranjero)
            if [ "$cc" != "$prev_cc" ] && [ -n "$prev_cc" ] && [ -n "$cc" ]; then
                total_intl_hops=$(( total_intl_hops + 1 ))
            fi
        fi
        last_country_name="$country"
    fi

    # ── Separador visual al cruzar océano ────────────────────────────────────
    if [ "$link_type" = "ocean" ]; then
        echo -e "${BLUE}${DIM}  ────────────────  CRUCE OCEÁNICO  ────────────────${RESET}"
    elif [ "$link_type" = "satellite" ]; then
        echo -e "${YELLOW}${DIM}  ────────────────  ENLACE SATELITAL  ───────────────${RESET}"
    fi

    bar=$(latency_bar "$curr_ms")
    icon=$(type_icon "$link_type")

    printf "%-3s  %-16s  %-7s  %s  %-20s  %-18s  %b\n" \
           "$hop_n" "$ip" "${curr_ms}ms" "$bar" \
           "${city:0:20}" "${display_country:0:18}" "$icon"

    [ -n "$geo_warn" ] && echo -e "     ${geo_warn}"

    prev_ms=$curr_ms
    prev_cc=$cc
    prev_country_name=$country
    prev_lat=$lat
    prev_lon=$lon

done < <(traceroute -n -q 2 -w 3 "$TARGET" 2>/dev/null \
         | awk 'NR>1 && $2 != "*" { print $2, $3 }')

# ── Resumen ───────────────────────────────────────────────────────────────────
echo -e "${DIM}$(printf '─%.0s' {1..105})${RESET}"
echo ""
echo -e "${BOLD}Resumen:${RESET}"
echo -e "  ${BLUE}🌊 Cruces oceánicos detectados : ${total_ocean_hops}${RESET}"
echo -e "  ${CYAN}✈  Países atravesados          : ${total_intl_hops}${RESET}"
echo -e "  ${DIM}Destino final                  : ${last_country_name:-desconocido}${RESET}"
echo ""
