#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
info()   { echo -e "  ${BLUE}→${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()    { echo -e "  ${RED}✗ ERRORE:${NC} $*"; exit 1; }

prompt() {
    local _d="${3:+ [${3}]}" _in
    printf "${BOLD}%s%s:${NC} " "$1" "$_d"
    IFS= read -r _in || { echo; exit 1; }
    _in="${_in#"${_in%%[![:space:]]*}"}"
    _in="${_in%"${_in##*[![:space:]]}"}"
    [[ -z "$_in" && -n "$3" ]] && _in="$3"
    printf -v "$2" '%s' "$_in"
}

yesno() {
    local _a
    prompt "$1" _a "$2"
    [[ "$_a" =~ ^[sSyY] ]]
}

ABC=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)
abc=(a b c d e f g h i j k l m n o p q r s t u v w x y z)

declare -a LANS=() ROUTERS=() HOSTS=()
declare -A LAN_CIDR=() LAN_PFX=() LAN_V6=() LAN_V6PFX=() LAN_RCNT=() LAN_DHCP=() LAN_TAG=() LAN_GWR=() LAN_RTRS=()
declare -A POOL_S=() POOL_E=() POOL_L=() DHCP_SRV=() DHCP_DNS=()
declare -A RT_LANS=() RT_IP=() RT_ROUTES=() RT_DEF4=() RT_DEF6=() RT_DEFVIA=() RT_REACH=()
declare -A H_LAN=() H_IP=() H_DHCP=() IP_WHY=()

ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

int_to_ip() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

mask_int() { echo $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); }
pfx_to_mask() { int_to_ip "$(mask_int "$1")"; }

mask_to_pfx() {
    local n inv b=0
    n=$(ip_to_int "$1")
    inv=$(( ~n & 0xFFFFFFFF ))
    (( (inv & (inv + 1)) == 0 )) || return 1
    while (( n & 0x80000000 )); do b=$((b+1)); n=$(( (n << 1) & 0xFFFFFFFF )); done
    echo "$b"
}

valid_ip() {
    local x a b c d
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$1"
    for x in $a $b $c $d; do (( 10#$x <= 255 )) || return 1; done
    return 0
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

net_addr()   { local n; n=$(ip_to_int "${1%/*}"); int_to_ip $(( n & $(mask_int "${1##*/}") )); }
first_ip()   { local n; n=$(ip_to_int "${1%/*}"); int_to_ip $(( (n & $(mask_int "${1##*/}")) + 1 )); }
cidr_start() { echo $(( $(ip_to_int "${1%/*}") & $(mask_int "${1##*/}") )); }
cidr_end()   { local m; m=$(mask_int "${1##*/}"); echo $(( ($(ip_to_int "${1%/*}") & m) | (~m & 0xFFFFFFFF) )); }
last_ip()    { int_to_ip $(( $(cidr_end "$1") - 1 )); }

parse_cidr() {
    local in="${1// //}" ip pfx
    [[ "$in" == */* ]] || return 1
    ip="${in%%/*}"; pfx="${in#*/}"
    valid_ip "$ip" || return 1
    if [[ "$pfx" == *.* ]]; then
        valid_ip "$pfx" && pfx=$(mask_to_pfx "$pfx") || return 1
    fi
    [[ "$pfx" =~ ^[0-9]+$ ]] || return 1
    (( pfx >= 1 && pfx <= 30 )) || return 1
    echo "$(net_addr "$ip/$pfx")/$pfx"
}

dev_exists() { local x; for x in "${ROUTERS[@]}" "${HOSTS[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
lan_exists() { local x; for x in "${LANS[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
in_list()    { local x i="$1"; shift; for x in "$@"; do [[ "$x" == "$i" ]] && return 0; done; return 1; }
on_lan()     { [[ " ${RT_LANS[$1]} " == *" $2 "* ]]; }
rip()        { echo "${RT_IP[$1:$2]}"; }

lan_overlap() {
    local c="$1" L s e s2 e2
    s=$(cidr_start "$c"); e=$(cidr_end "$c")
    for L in "${LANS[@]}"; do
        s2=$(cidr_start "${LAN_CIDR[$L]}"); e2=$(cidr_end "${LAN_CIDR[$L]}")
        if (( s <= e2 && s2 <= e )); then echo "$L"; return 0; fi
    done
    return 1
}

vlsm_alloc() {
    local base="$1" need="$2" bits=2 size start end a cand pfx
    while (( (1 << bits) - 2 < need )); do bits=$((bits+1)); done
    pfx=$((32 - bits))
    (( pfx >= ${base##*/} && pfx <= 30 )) || return 1
    size=$((1 << bits))
    start=$(cidr_start "$base"); end=$(cidr_end "$base")
    for (( a=start; a+size-1 <= end; a+=size )); do
        cand="$(int_to_ip $a)/$pfx"
        lan_overlap "$cand" > /dev/null || { echo "$cand"; return 0; }
    done
    return 1
}

lan_contains() {
    local c="${LAN_CIDR[$1]}" m n
    m=$(mask_int "${c##*/}"); n=$(ip_to_int "$2")
    (( (n & m) == $(cidr_start "$c") ))
}

host_ok() {
    local n
    valid_ip "$2" || return 1
    lan_contains "$1" "$2" || return 1
    n=$(ip_to_int "$2")
    (( n != $(cidr_start "${LAN_CIDR[$1]}") && n != $(cidr_end "${LAN_CIDR[$1]}") ))
}

in_pool() {
    [[ "${LAN_DHCP[$1]}" == 1 ]] || return 1
    local n; n=$(ip_to_int "$2")
    (( n >= $(ip_to_int "${POOL_S[$1]}") && n <= $(ip_to_int "${POOL_E[$1]}") ))
}

ip_used() {
    local ip="$1" L="$2" ex="$3" D
    for D in "${ROUTERS[@]}"; do
        [[ "$D" == "$ex" ]] && continue
        [[ "$(rip "$D" "$L")" == "$ip" ]] && return 0
    done
    for D in "${HOSTS[@]}"; do
        [[ "$D" == "$ex" ]] && continue
        [[ "${H_LAN[$D]}" == "$L" && "${H_IP[$D]}" == "$ip" ]] && return 0
    done
    return 1
}

owner_router() {
    local D
    for D in "${ROUTERS[@]}"; do
        [[ "$(rip "$D" "$1")" == "$2" ]] && { echo "$D"; return 0; }
    done
    return 1
}

v6id() {
    local off=$(( $(ip_to_int "$2") - $(cidr_start "${LAN_CIDR[$1]}") ))
    if (( off < 10000 )); then echo "$off"; else printf '%x' "$off"; fi
}

v6addr() { echo "${LAN_V6[$1]}::$(v6id "$1" "$2")"; }

rip6() {
    (( USE_IPV6 )) || { echo ""; return; }
    v6addr "$2" "$(rip "$1" "$2")"
}

eth_of() {
    local D="$1" L="$2" i=0 X
    if [[ -n "${RT_LANS[$D]+x}" ]]; then
        for X in ${RT_LANS[$D]}; do
            [[ "$X" == "$L" ]] && { echo "$i"; return; }
            i=$((i+1))
        done
    fi
    echo 0
}

resolve_ip() {
    local L="$1" spec="$2" ex="$3" first last n ip
    first=$(ip_to_int "$(first_ip "${LAN_CIDR[$L]}")")
    last=$(ip_to_int "$(last_ip "${LAN_CIDR[$L]}")")
    case "$spec" in
        p) int_to_ip "$first" ;;
        u) int_to_ip "$last" ;;
        n) int_to_ip $((last - 1)) ;;
        s)
            for ((n=first; n<=last; n++)); do
                ip=$(int_to_ip $n)
                ip_used "$ip" "$L" "$ex" && continue
                in_pool "$L" "$ip" && continue
                echo "$ip"; return
            done
            ;;
        -[0-9]*) [[ "${spec#-}" =~ ^[0-9]+$ ]] && int_to_ip $((last - ${spec#-} + 1)) ;;
        [0-9]*.*.*.*) valid_ip "$spec" && echo "$spec" ;;
        [0-9]*) [[ "$spec" =~ ^[0-9]+$ ]] && int_to_ip $((first + spec - 1)) ;;
    esac
}

PICK_WHY=""
pick_ip() {
    local L="$1" LABEL="$2" EX="$3" OUT="$4" DEF="$5" net first last pen spec ip
    net="${LAN_CIDR[$L]}"
    first=$(first_ip "$net"); last=$(last_ip "$net")
    pen=$(int_to_ip $(( $(ip_to_int "$last") - 1 )))
    while true; do
        info "  ${L}: ${net}  primo=${first}  penultimo=${pen}  ultimo=${last}"
        prompt "  ${LABEL} (p primo, u ultimo, n penultimo, s primo libero, N-esimo, -N dalla fine, o IP)" spec "$DEF"
        ip=$(resolve_ip "$L" "$spec" "$EX")
        if [[ -z "$ip" ]]; then warn "Valore non valido."; continue; fi
        if ! host_ok "$L" "$ip"; then warn "${ip} non è un indirizzo assegnabile in ${net}."; continue; fi
        if ip_used "$ip" "$L" "$EX"; then warn "${ip} è già assegnato su ${L}."; continue; fi
        if in_pool "$L" "$ip"; then warn "${ip} cade nel pool DHCP di ${L}."; continue; fi
        break
    done
    case "$spec" in
        p) PICK_WHY="primo indirizzo" ;;
        u) PICK_WHY="ultimo indirizzo" ;;
        n) PICK_WHY="penultimo indirizzo" ;;
        s) PICK_WHY="primo indirizzo libero" ;;
        -[0-9]*) PICK_WHY="${spec#-}° indirizzo contando dalla fine" ;;
        [0-9]*.*.*.*) PICK_WHY="indirizzo scelto a mano" ;;
        *) PICK_WHY="${spec}° indirizzo contando dall'inizio" ;;
    esac
    printf -v "$OUT" '%s' "$ip"
}

ask_name() {
    local _n
    while true; do
        prompt "$2" _n "$3"
        if ! valid_name "$_n"; then warn "Usa solo lettere, numeri, _ e -."
        elif dev_exists "$_n" || [[ "$_n" == "$ES_NAME" ]]; then warn "Nome già usato (da un dispositivo o dallo script di avvio)."
        else break; fi
    done
    printf -v "$1" '%s' "$_n"
}

check_lan_list() {
    local L seen=" "
    [[ -n "$1" ]] || { warn "Indica almeno una LAN."; return 1; }
    for L in $1; do
        lan_exists "$L" || { warn "LAN '$L' inesistente."; return 1; }
        [[ "$seen" == *" $L "* ]] && { warn "LAN '$L' ripetuta."; return 1; }
        seen+="$L "
    done
    return 0
}

[[ -t 1 ]] && clear
echo -e "${CYAN}${BOLD}  Auto-Setup Esercizi di Rete${NC}"

header "Informazioni Generali"

prompt "Nome esercizio (sarà il nome della cartella)" ES_NAME "es_lab"
valid_name "$ES_NAME" || err "Nome non valido (usa lettere, numeri, _ e -)."

yesno "Usare IPv6 oltre a IPv4? (s/n)" n && USE_IPV6=1 || USE_IPV6=0
yesno "Configurare un server DHCP (dnsmasq)? (s/n)" n && USE_DHCP=1 || USE_DHCP=0
TWO_PHASE=0
if (( USE_DHCP )) && yesno "L'esercizio ha due parti (prima tutto statico, poi DHCP, con due consegne)? (s/n)" s; then TWO_PHASE=1; fi
yesno "Configurare un web server nginx? (s/n)" n && USE_NGINX=1 || USE_NGINX=0

header "Configurazione LAN"
prompt "Numero di LAN" N_LANS "2"
[[ "$N_LANS" =~ ^[0-9]+$ && "$N_LANS" -ge 1 ]] || err "Numero non valido."

VLSM_BASE=""

for ((i=0; i<N_LANS; i++)); do
    while true; do
        prompt "  Nome LAN $((i+1))" LNAME "lan${ABC[$i]}"
        if ! valid_name "$LNAME"; then warn "Usa solo lettere, numeri, _ e -."
        elif lan_exists "$LNAME"; then warn "Nome LAN già usato."
        else break; fi
    done

    prompt "  Rete di $LNAME: scritta a mano (m) o calcolata dal numero di host (h)?" _mode "m"
    while true; do
        if [[ "$_mode" =~ ^[hH] ]]; then
            if [[ -z "$VLSM_BASE" ]]; then
                while true; do
                    prompt "  Blocco di indirizzi da suddividere (CIDR)" _b "192.168.0.0/24"
                    VLSM_BASE=$(parse_cidr "$_b") && break
                    warn "Blocco non valido."
                done
            fi
            prompt "  Quanti host servono su $LNAME?" _nh "50"
            if ! [[ "$_nh" =~ ^[0-9]+$ ]] || (( _nh < 1 )); then warn "Numero non valido."; continue; fi
            NETCIDR=$(vlsm_alloc "$VLSM_BASE" "$_nh") || { warn "Spazio insufficiente in ${VLSM_BASE}: inserisci la rete a mano."; _mode="m"; continue; }
            info "  Assegnata ${NETCIDR} per ${_nh} host"
            break
        else
            prompt "  Rete (es. 192.168.1.0/24 oppure 192.168.1.0/255.255.255.0)" _c "192.168.$((i+1)).0/24"
            NETCIDR=$(parse_cidr "$_c") || { warn "Rete non valida (prefisso ammesso da /1 a /30)."; continue; }
            if _o=$(lan_overlap "$NETCIDR"); then warn "Si sovrappone a ${_o}."; continue; fi
            break
        fi
    done

    LANS+=("$LNAME")
    LAN_CIDR[$LNAME]="$NETCIDR"
    LAN_PFX[$LNAME]="${NETCIDR##*/}"
    LAN_RCNT[$LNAME]=0
    LAN_DHCP[$LNAME]=0
    LAN_TAG[$LNAME]="net$i"

    if (( USE_IPV6 )); then
        prompt "  Prefisso IPv6 per $LNAME (es. 2a00:0:0:a)" V6P "2a00:0:0:${abc[$i]}"
        while [[ "$V6P" == *: ]]; do V6P="${V6P%:}"; done
        prompt "  Lunghezza prefisso IPv6" V6L "64"
        [[ "$V6L" =~ ^[0-9]+$ ]] && (( V6L >= 1 && V6L <= 128 )) || V6L=64
        LAN_V6[$LNAME]="$V6P"
        LAN_V6PFX[$LNAME]="$V6L"
    fi

    ok "$LNAME → ${NETCIDR}  maschera $(pfx_to_mask "${NETCIDR##*/}")  primo=$(first_ip "$NETCIDR")  ultimo=$(last_ip "$NETCIDR")  host utili=$(( (1 << (32 - ${NETCIDR##*/})) - 2 ))"
done

if (( USE_DHCP )); then
    header "DHCP: pool di indirizzi"
    NPOOLS=0
    for L in "${LANS[@]}"; do
        yesno "DHCP sulla LAN $L? (s/n)" n || continue
        LAN_DHCP[$L]=1
        NPOOLS=$((NPOOLS+1))
        usable=$(( (1 << (32 - ${LAN_PFX[$L]})) - 2 ))
        fs=$(ip_to_int "$(first_ip "${LAN_CIDR[$L]}")")
        def_s=$(int_to_ip $(( fs + usable*39/100 )))
        def_e=$(int_to_ip $(( fs - 1 + usable*79/100 )))
        while true; do
            prompt "  Primo indirizzo del pool" _ps "$def_s"
            prompt "  Ultimo indirizzo del pool" _pe "$def_e"
            if ! host_ok "$L" "$_ps" || ! host_ok "$L" "$_pe"; then warn "Indirizzi non validi per ${LAN_CIDR[$L]}."; continue; fi
            if (( $(ip_to_int "$_ps") > $(ip_to_int "$_pe") )); then warn "Il primo indirizzo deve precedere l'ultimo."; continue; fi
            break
        done
        prompt "  Durata del lease (es. 12h, 1d, 600)" _ls "12h"
        POOL_S[$L]="$_ps"; POOL_E[$L]="$_pe"; POOL_L[$L]="$_ls"
        ok "$L → pool ${_ps} - ${_pe}, lease ${_ls}"
    done
    if (( NPOOLS == 0 )); then
        warn "Nessuna LAN con DHCP: la parte DHCP viene disattivata."
        USE_DHCP=0
        TWO_PHASE=0
    fi
fi

header "Configurazione Router"
prompt "Numero di router (0 se nessuno)" N_ROUTERS "1"
[[ "$N_ROUTERS" =~ ^[0-9]+$ ]] || err "Numero non valido."

for ((i=0; i<N_ROUTERS; i++)); do
    ask_name RNAME "  Nome router $((i+1))" "r${ABC[$i]}${ABC[$((i+1))]}"
    ROUTERS+=("$RNAME")

    info "LAN disponibili: ${LANS[*]}"
    while true; do
        prompt "  LAN collegate a $RNAME (l'ordine decide eth0, eth1, ...)" RLANS ""
        check_lan_list "$RLANS" && break
    done
    RT_LANS[$RNAME]="$RLANS"

    ETH=0
    for LAN in $RLANS; do
        k="${LAN_RCNT[$LAN]}"
        case "$k" in 0) DEFSPEC="u" ;; 1) DEFSPEC="n" ;; *) DEFSPEC="-$((k+1))" ;; esac
        pick_ip "$LAN" "$RNAME/eth${ETH} su $LAN" "$RNAME" CHOSEN_IP "$DEFSPEC"
        RT_IP[$RNAME:$LAN]="$CHOSEN_IP"
        IP_WHY[$RNAME:$LAN]="$PICK_WHY"
        LAN_RCNT[$LAN]=$((k+1))
        ok "  $RNAME eth${ETH} → ${CHOSEN_IP}/${LAN_PFX[$LAN]} ($LAN)"
        ETH=$((ETH+1))
    done
done

header "Configurazione Host"

for L in "${LANS[@]}"; do
    prompt "Numero di host nella LAN $L (0 = nessuno)" NH "1"
    [[ "$NH" =~ ^[0-9]+$ ]] || err "Numero non valido."
    for ((j=1; j<=NH; j++)); do
        ask_name HNAME "  Nome host $j su $L" "pc${j}${L#lan}"
        HOSTS+=("$HNAME")
        H_LAN[$HNAME]="$L"
        H_DHCP[$HNAME]=0
        HLABEL="$HNAME"
        if [[ "${LAN_DHCP[$L]}" == 1 ]] && yesno "  $HNAME riceve l'IP via DHCP? (s/n)" n; then
            H_DHCP[$HNAME]=1
            HLABEL="$HNAME, IP statico della parte 1"
            if (( ! TWO_PHASE )); then
                H_IP[$HNAME]=""
                IP_WHY[$HNAME]=""
                ok "  $HNAME → client DHCP ($L)"
                continue
            fi
        fi
        pick_ip "$L" "$HLABEL" "$HNAME" CHOSEN_IP "s"
        H_IP[$HNAME]="$CHOSEN_IP"
        IP_WHY[$HNAME]="$PICK_WHY"
        ok "  $HNAME → ${CHOSEN_IP}/${LAN_PFX[$L]} ($L)$([[ ${H_DHCP[$HNAME]} == 1 ]] && echo '  [client DHCP]')"
    done
done

for L in "${LANS[@]}"; do
    rl=()
    for R in "${ROUTERS[@]}"; do on_lan "$R" "$L" && rl+=("$R"); done
    LAN_RTRS[$L]="${rl[*]}"
    case "${#rl[@]}" in
        0) LAN_GWR[$L]="" ;;
        1) LAN_GWR[$L]="${rl[0]}" ;;
        *)
            nhh=0
            for H in "${HOSTS[@]}"; do [[ "${H_LAN[$H]}" == "$L" ]] && nhh=$((nhh+1)); done
            if (( nhh == 0 )); then LAN_GWR[$L]="${rl[0]}"; continue; fi
            while true; do
                prompt "Gateway predefinito degli host su $L (${rl[*]}, '-' = nessuno)" _g "${rl[0]}"
                [[ "$_g" == "-" ]] && { LAN_GWR[$L]=""; break; }
                in_list "$_g" "${rl[@]}" && { LAN_GWR[$L]="$_g"; break; }
                warn "Scegli uno tra: ${rl[*]}"
            done
            ;;
    esac
done

if (( USE_DHCP )); then
    header "DHCP: server e opzioni"
    for L in "${LANS[@]}"; do
        [[ "${LAN_DHCP[$L]}" == 1 ]] || continue
        cands=()
        for H in "${HOSTS[@]}"; do
            [[ "${H_LAN[$H]}" == "$L" && "${H_DHCP[$H]}" != 1 ]] && cands+=("$H")
        done
        for R in "${ROUTERS[@]}"; do on_lan "$R" "$L" && cands+=("$R"); done
        (( ${#cands[@]} )) || err "Su $L non c'è nessun dispositivo con IP statico che possa fare da server DHCP."
        defsrv="${cands[0]}"
        for c in "${cands[@]}"; do
            [[ "${c,,}" == *dhcp* ]] && { defsrv="$c"; break; }
        done
        while true; do
            prompt "Server DHCP per $L (${cands[*]})" _s "$defsrv"
            in_list "$_s" "${cands[@]}" && break
            warn "Scegli uno tra: ${cands[*]}"
        done
        DHCP_SRV[$L]="$_s"
        while true; do
            prompt "Server DNS da distribuire su $L (invio = nessuno)" _dns ""
            [[ -z "$_dns" ]] && break
            valid_ip "$_dns" && break
            warn "IP non valido."
        done
        DHCP_DNS[$L]="$_dns"
        if [[ -z "${LAN_GWR[$L]}" ]]; then
            warn "Su $L non c'è nessun router: i client non riceveranno un gateway."
        else
            info "Gateway distribuito su $L: ${LAN_GWR[$L]} ($(rip "${LAN_GWR[$L]}" "$L"))"
        fi
        nc=0
        for H in "${HOSTS[@]}"; do [[ "${H_LAN[$H]}" == "$L" && "${H_DHCP[$H]}" == 1 ]] && nc=$((nc+1)); done
        psize=$(( $(ip_to_int "${POOL_E[$L]}") - $(ip_to_int "${POOL_S[$L]}") + 1 ))
        (( nc == 0 )) && warn "Nessun client DHCP definito su $L."
        (( nc > psize )) && warn "Su $L ci sono $nc client ma il pool ha solo $psize indirizzi."
    done
fi

header "Connettività Internet"

USE_INTERNET=0; GW_INTERNET=""; EXIT_LAN=""; GW_INTERNET_IP=""; EXT_ROUTER=""

if (( N_ROUTERS > 0 )) && yesno "C'è un'uscita verso Internet/ISP? (s/n)" n; then
    USE_INTERNET=1
    while true; do
        prompt "Quale router è il gateway verso Internet? (${ROUTERS[*]})" GW_INTERNET "${ROUTERS[$((N_ROUTERS-1))]}"
        in_list "$GW_INTERNET" "${ROUTERS[@]}" && break
        warn "Scegli uno tra: ${ROUTERS[*]}"
    done
    gl=(${RT_LANS[$GW_INTERNET]})
    while true; do
        prompt "Su quale LAN di $GW_INTERNET si trova il collegamento verso l'ISP? (${gl[*]})" EXIT_LAN "${gl[$((${#gl[@]}-1))]}"
        in_list "$EXIT_LAN" "${gl[@]}" && break
        warn "Scegli una tra: ${gl[*]}"
    done
    sug=""
    for X in "${ROUTERS[@]}"; do
        if [[ "$X" != "$GW_INTERNET" ]] && on_lan "$X" "$EXIT_LAN"; then sug="$(rip "$X" "$EXIT_LAN")"; break; fi
    done
    [[ -z "$sug" ]] && sug=$(resolve_ip "$EXIT_LAN" s "$GW_INTERNET")
    while true; do
        prompt "IP del router ISP su $EXIT_LAN, next-hop della default route ('-' = nessuno, il gateway è già l'ultimo router)" GW_INTERNET_IP "$sug"
        [[ "$GW_INTERNET_IP" == "-" ]] && { GW_INTERNET_IP=""; break; }
        if ! host_ok "$EXIT_LAN" "$GW_INTERNET_IP"; then warn "IP non valido per ${LAN_CIDR[$EXIT_LAN]}."; continue; fi
        if [[ "$GW_INTERNET_IP" == "$(rip "$GW_INTERNET" "$EXIT_LAN")" ]]; then warn "È l'IP del router stesso."; continue; fi
        if EXT_ROUTER=$(owner_router "$EXIT_LAN" "$GW_INTERNET_IP"); then break; fi
        EXT_ROUTER=""
        if ip_used "$GW_INTERNET_IP" "$EXIT_LAN" ""; then warn "IP già usato da un host."; continue; fi
        break
    done
    if [[ -n "$GW_INTERNET_IP" ]]; then
        ok "$GW_INTERNET → default via ${GW_INTERNET_IP} (ISP su $EXIT_LAN)"
    else
        ok "$GW_INTERNET → gateway Internet senza ulteriore hop"
    fi
fi

NGINX_HOST=""; NGINX_PORT="80"; NGINX_ROOT="/var/www/html"; MAKE_HTML=0
HTML_NOME=""; HTML_COGNOME=""; HTML_CF=""; HTML_TITLE=""; HTML_EXTRA=""

if (( USE_NGINX )); then
    header "Web server nginx"
    cands=()
    for H in "${HOSTS[@]}"; do [[ "${H_DHCP[$H]}" != 1 ]] && cands+=("$H"); done
    if (( ${#cands[@]} == 0 )); then
        warn "Nessun host con IP statico: nginx non configurato."
        USE_NGINX=0
    else
        info "Host disponibili (con IP statico): ${cands[*]}"
        while true; do
            prompt "Su quale host avviare nginx?" NGINX_HOST "${cands[$((${#cands[@]}-1))]}"
            in_list "$NGINX_HOST" "${cands[@]}" && break
            warn "Scegli uno tra: ${cands[*]}"
        done
        while true; do
            prompt "Porta di ascolto (80, 8080, ...)" NGINX_PORT "80"
            [[ "$NGINX_PORT" =~ ^[0-9]+$ ]] && (( NGINX_PORT >= 1 && NGINX_PORT <= 65535 )) && break
            warn "Porta non valida."
        done
        prompt "Directory root del sito" NGINX_ROOT "/var/www/html"
        if yesno "Creare index.html e una seconda pagina collegata? (s/n)" s; then
            MAKE_HTML=1
            prompt "Titolo pagina" HTML_TITLE "Il mio server"
            prompt "Nome (facoltativo)" HTML_NOME ""
            prompt "Cognome (facoltativo)" HTML_COGNOME ""
            prompt "Codice fiscale (facoltativo)" HTML_CF ""
            prompt "Frase da mostrare (facoltativo)" HTML_EXTRA ""
        fi
    fi
fi

calc_routes() {
    local R="$1" out="" L R2 item cur nh4 nh6 via
    local -A vl=() vr=()
    local -a q=()
    vr[$R]=1
    for L in ${RT_LANS[$R]}; do vl[$L]=1; done
    for L in ${RT_LANS[$R]}; do
        for R2 in "${ROUTERS[@]}"; do
            [[ -n "${vr[$R2]}" ]] && continue
            if on_lan "$R2" "$L"; then
                vr[$R2]=1
                q+=("$R2|$(rip "$R2" "$L")|$(rip6 "$R2" "$L")|$R2")
            fi
        done
    done
    while (( ${#q[@]} )); do
        item="${q[0]}"; q=("${q[@]:1}")
        IFS='|' read -r cur nh4 nh6 via <<< "$item"
        for L in ${RT_LANS[$cur]}; do
            if [[ -z "${vl[$L]}" ]]; then
                vl[$L]=1
                out+="$L|$nh4|$nh6|$via"$'\n'
            fi
        done
        for L in ${RT_LANS[$cur]}; do
            for R2 in "${ROUTERS[@]}"; do
                [[ -n "${vr[$R2]}" ]] && continue
                if on_lan "$R2" "$L"; then
                    vr[$R2]=1
                    q+=("$R2|$nh4|$nh6|$via")
                fi
            done
        done
    done
    RT_ROUTES[$R]="$out"
    RT_REACH[$R]="${!vl[*]}"
}

calc_defaults() {
    (( USE_INTERNET )) || return
    local L R2 item cur nh4 nh6 via nh6gw=""
    local -A vr=()
    local -a q=()
    vr[$GW_INTERNET]=1
    [[ -n "$EXT_ROUTER" ]] && vr[$EXT_ROUTER]=1
    if [[ -n "$GW_INTERNET_IP" ]]; then
        (( USE_IPV6 )) && nh6gw="${LAN_V6[$EXIT_LAN]}::$(v6id "$EXIT_LAN" "$GW_INTERNET_IP")"
        RT_DEF4[$GW_INTERNET]="$GW_INTERNET_IP"
        RT_DEF6[$GW_INTERNET]="$nh6gw"
        RT_DEFVIA[$GW_INTERNET]="ISP"
    fi
    for L in ${RT_LANS[$GW_INTERNET]}; do
        for R2 in "${ROUTERS[@]}"; do
            [[ -n "${vr[$R2]}" ]] && continue
            if on_lan "$R2" "$L"; then
                vr[$R2]=1
                q+=("$R2|$(rip "$GW_INTERNET" "$L")|$(rip6 "$GW_INTERNET" "$L")|$GW_INTERNET")
            fi
        done
    done
    while (( ${#q[@]} )); do
        item="${q[0]}"; q=("${q[@]:1}")
        IFS='|' read -r cur nh4 nh6 via <<< "$item"
        RT_DEF4[$cur]="$nh4"; RT_DEF6[$cur]="$nh6"; RT_DEFVIA[$cur]="$via"
        for L in ${RT_LANS[$cur]}; do
            for R2 in "${ROUTERS[@]}"; do
                [[ -n "${vr[$R2]}" ]] && continue
                if on_lan "$R2" "$L"; then
                    vr[$R2]=1
                    q+=("$R2|$(rip "$cur" "$L")|$(rip6 "$cur" "$L")|$cur")
                fi
            done
        done
    done
}

for R in "${ROUTERS[@]}"; do calc_routes "$R"; done
calc_defaults

header "Controlli"
for L in "${LANS[@]}"; do
    if (( N_ROUTERS > 0 )) && [[ "${LAN_RCNT[$L]}" == 0 ]]; then
        warn "$L non è collegata a nessun router: resta isolata."
    fi
done
for R in "${ROUTERS[@]}"; do
    for L in "${LANS[@]}"; do
        [[ "${LAN_RCNT[$L]}" == 0 ]] && continue
        [[ " ${RT_REACH[$R]} " == *" $L "* ]] || warn "$R non raggiunge $L: manca un collegamento tra router."
    done
done
ok "Verifiche completate"

BODY=""; DOC=""

put() {
    BODY+="$1"$'\n'
    DOC+="- \`$1\`"$'\n'"  - $2"$'\n'
}

put_block() {
    BODY+="$1"$'\n'
    DOC+="- $2"$'\n'"  - $3"$'\n'
}

dhcp_block() {
    local D="$1" L eth T gwip txt="" conf="/tmp/dnsmasq-$1.conf"
    local -a served=()
    for L in "${LANS[@]}"; do
        [[ "${LAN_DHCP[$L]}" == 1 && "${DHCP_SRV[$L]}" == "$D" ]] && served+=("$L")
    done
    (( ${#served[@]} )) || return
    txt+="port=0"$'\n'"bind-interfaces"$'\n'
    txt+="pid-file=/tmp/dnsmasq-${D}.pid"$'\n'
    txt+="dhcp-leasefile=/tmp/dnsmasq-${D}.leases"$'\n'
    txt+="log-dhcp"$'\n'"log-facility=/tmp/dnsmasq-${D}.log"$'\n'
    DOC+="- Crea \`${conf}\` (configurazione di dnsmasq) con queste direttive:"$'\n'
    DOC+="  - \`port=0\`: spegne la parte DNS di dnsmasq, qui serve solo il DHCP; evita conflitti sulla porta 53."$'\n'
    DOC+="  - \`bind-interfaces\`: dnsmasq ascolta solo sulle schede indicate con \`interface\`."$'\n'
    DOC+="  - \`dhcp-leasefile\`, \`pid-file\`, \`log-dhcp\`, \`log-facility\`: file in /tmp per vedere gli indirizzi assegnati e il log delle richieste (DISCOVER, OFFER, REQUEST, ACK)."$'\n'
    for L in "${served[@]}"; do
        eth=$(eth_of "$D" "$L"); T="${LAN_TAG[$L]}"
        txt+="interface=eth${eth}"$'\n'
        txt+="dhcp-range=set:${T},${POOL_S[$L]},${POOL_E[$L]},$(pfx_to_mask "${LAN_PFX[$L]}"),${POOL_L[$L]}"$'\n'
        DOC+="  - \`interface=eth${eth}\`: il server risponde solo sulla scheda collegata a ${L}."$'\n'
        DOC+="  - \`dhcp-range=set:${T},${POOL_S[$L]},${POOL_E[$L]},$(pfx_to_mask "${LAN_PFX[$L]}"),${POOL_L[$L]}\`: pool da distribuire (primo, ultimo, maschera della rete ${LAN_CIDR[$L]}, durata del lease). Il pool non deve contenere gli IP statici. L'etichetta \`${T}\` serve ad associare le opzioni successive a questa rete."$'\n'
        gwip=""
        [[ -n "${LAN_GWR[$L]}" ]] && gwip=$(rip "${LAN_GWR[$L]}" "$L")
        if [[ -n "$gwip" ]]; then
            txt+="dhcp-option=tag:${T},option:router,${gwip}"$'\n'
            DOC+="  - \`dhcp-option=tag:${T},option:router,${gwip}\`: gateway che i client riceveranno, cioè l'IP di ${LAN_GWR[$L]} su ${L}. Senza questa riga dnsmasq darebbe ai client il proprio IP come gateway, che è sbagliato; e poiché ai client si toglie la rotta statica, il gateway deve arrivare dal DHCP."$'\n'
        fi
        if [[ -n "${DHCP_DNS[$L]}" ]]; then
            txt+="dhcp-option=tag:${T},option:dns-server,${DHCP_DNS[$L]}"$'\n'
            DOC+="  - \`dhcp-option=tag:${T},option:dns-server,${DHCP_DNS[$L]}\`: DNS distribuito ai client."$'\n'
        fi
    done
    BODY+="cat > ${conf} <<'EOF'"$'\n'"${txt}EOF"$'\n'
    put "dnsmasq -C ${conf}" "Avvia il server DHCP con quel file. Il server ha IP statico (i client lo cercano prima di avere un indirizzo) e deve partire dopo che le schede hanno l'IP, per questo sta in fondo allo script."
}

nginx_block() {
    local H="$1" blk=""
    if [[ "$NGINX_PORT" != "80" ]]; then
        put "sed -i 's/listen 80 default_server/listen ${NGINX_PORT} default_server/g' /etc/nginx/sites-enabled/default" "nginx di default ascolta sulla porta 80 (direttiva listen). sed la cambia in ${NGINX_PORT} per IPv4. Va rifatto a ogni avvio: il simulatore ripristina i file di configurazione originali, quindi le modifiche persistono solo se stanno nello script dell'host."
        put "sed -i 's/listen \[::]:80 default_server/listen [::]:${NGINX_PORT} default_server/g' /etc/nginx/sites-enabled/default" "Stessa modifica per IPv6 (la direttiva listen [::] è separata)."
    fi
    if [[ "$NGINX_ROOT" != "/var/www/html" ]]; then
        put "sed -i 's|root /var/www/html|root ${NGINX_ROOT}|g' /etc/nginx/sites-enabled/default" "La direttiva root indica la cartella che contiene i file del sito: la porta alla cartella scelta."
        put "mkdir -p ${NGINX_ROOT}" "Crea la cartella se non esiste."
    fi
    if (( MAKE_HTML )); then
        local nome="" cog="" cf="" ex=""
        [[ -n "$HTML_NOME" ]]    && nome="<p><strong>Nome:</strong> ${HTML_NOME}</p>"
        [[ -n "$HTML_COGNOME" ]] && cog="<p><strong>Cognome:</strong> ${HTML_COGNOME}</p>"
        [[ -n "$HTML_CF" ]]      && cf="<p><strong>Codice fiscale:</strong> ${HTML_CF}</p>"
        [[ -n "$HTML_EXTRA" ]]   && ex="<p>${HTML_EXTRA}</p>"
        blk=$(cat <<HTMLEOF
cat > ${NGINX_ROOT}/index.html <<'EOF'
<!DOCTYPE html>
<html lang="it">
<head><meta charset="UTF-8"><title>${HTML_TITLE}</title></head>
<body>
  <h1>${HTML_TITLE}</h1>
  ${nome}
  ${cog}
  ${cf}
  ${ex}
  <p><a href="pagina2.html">Seconda pagina</a></p>
</body>
</html>
EOF
cat > ${NGINX_ROOT}/pagina2.html <<'EOF'
<!DOCTYPE html>
<html lang="it">
<head><meta charset="UTF-8"><title>Pagina 2 - ${HTML_TITLE}</title></head>
<body>
  <h1>Pagina 2</h1>
  <p><a href="index.html">Torna alla home</a></p>
</body>
</html>
EOF
HTMLEOF
)
        put_block "$blk" "Crea \`${NGINX_ROOT}/index.html\` (titolo, dati, link) e \`${NGINX_ROOT}/pagina2.html\`" "index è il file che nginx invia quando l'URL non indica nessuna pagina (direttiva index). Il link permette di verificare la navigazione tra due pagine. L'heredoc con 'EOF' tra apici copia il testo così com'è."
    fi
    put "nginx -t && nginx" "Controlla la configurazione e avvia il server in background. Si raggiunge con http://$(echo "${H_IP[$H]}")$([[ "$NGINX_PORT" != 80 ]] && echo ":${NGINX_PORT}")."
}

host_script() {
    local H="$1" MODE="$2" L PFX IP GWR GW
    L="${H_LAN[$H]}"; PFX="${LAN_PFX[$L]}"; IP="${H_IP[$H]}"; GWR="${LAN_GWR[$L]}"
    GW=""; [[ -n "$GWR" ]] && GW=$(rip "$GWR" "$L")
    BODY="#!/bin/bash"$'\n'; DOC=""

    if [[ "$MODE" == dhcp && "${H_DHCP[$H]}" == 1 ]]; then
        if (( TWO_PHASE )); then
            put "dhclient -v eth0" "Chiede via DHCP indirizzo, maschera e gateway sulla scheda eth0. Sostituisce sia l'IP statico sia la rotta di default della parte 1 (la consegna dice di toglierli): per questo lo script contiene solo questa riga. -v mostra DISCOVER, OFFER, REQUEST, ACK. Il server deve essere già attivo; se non risponde, rilancia il comando."
        else
            put "dhclient -v eth0" "Chiede via DHCP indirizzo, maschera e gateway sulla scheda eth0: il client non ha nient'altro da configurare, tutto arriva dal server. -v mostra DISCOVER, OFFER, REQUEST, ACK. Il server deve essere già attivo; se non risponde, rilancia il comando."
        fi
    else
        put "ip address add ${IP}/${PFX} dev eth0" "Assegna a eth0 (l'unica scheda dell'host, collegata a ${L}) l'indirizzo ${IP}: ${IP_WHY[$H]} della rete ${LAN_CIDR[$L]}. /${PFX} (maschera $(pfx_to_mask "$PFX")) significa che gli indirizzi di ${LAN_CIDR[$L]} si raggiungono direttamente, senza router."
        if [[ -n "$GW" ]]; then
            put "ip route add default via ${GW}" "Per ogni destinazione fuori da ${L} l'host consegna il pacchetto al router ${GWR}, che su ${L} ha IP ${GW} (il gateway deve stare sulla stessa rete dell'host). Serve anche per le risposte: senza gateway una richiesta può arrivare ma la risposta non torna."
        fi
    fi

    if (( USE_IPV6 )); then
        if [[ -n "$IP" ]]; then
            put "ip address add $(v6addr "$L" "$IP")/${LAN_V6PFX[$L]} dev eth0" "Indirizzo IPv6 sulla rete ${LAN_V6[$L]}::/${LAN_V6PFX[$L]}. La parte finale è la posizione dell'host nella rete IPv4, come nelle slide (.1 diventa ::1)."
            if [[ -n "$GW" ]]; then
                put "ip -6 route add default via $(v6addr "$L" "$GW") dev eth0" "Default route IPv6 verso lo stesso router."
            fi
        else
            DOC+="- IPv6 non configurato: il DHCP è solo IPv4 e questo host non ha un IPv4 fisso da cui ricavare l'indirizzo."$'\n'
        fi
    fi

    if [[ "$MODE" == dhcp ]]; then dhcp_block "$H"; fi
    if (( USE_NGINX )) && [[ "$H" == "$NGINX_HOST" ]]; then nginx_block "$H"; fi
}

router_script() {
    local R="$1" MODE="$2" ETH=0 L PFX IP rec dl nh4 nh6 via net
    BODY="#!/bin/bash"$'\n'; DOC=""

    for L in ${RT_LANS[$R]}; do
        IP=$(rip "$R" "$L"); PFX="${LAN_PFX[$L]}"
        put "ip address add ${IP}/${PFX} dev eth${ETH}" "eth${ETH} è la scheda collegata a ${L} (nel comando rstart l'ordine delle reti decide eth0, eth1, ...). Un router ha un IP per ogni rete: ${IP} corrisponde a: ${IP_WHY[$R:$L]} di ${LAN_CIDR[$L]}. Non servono rotte per ${L}: le reti collegate direttamente il router le conosce da solo."
        if (( USE_IPV6 )); then
            put "ip address add $(v6addr "$L" "$IP")/${LAN_V6PFX[$L]} dev eth${ETH}" "Indirizzo IPv6 della stessa scheda su ${LAN_V6[$L]}::/${LAN_V6PFX[$L]}."
        fi
        ETH=$((ETH+1))
    done

    while IFS='|' read -r dl nh4 nh6 via; do
        [[ -z "$dl" ]] && continue
        [[ -n "${RT_DEF4[$R]}" && "$nh4" == "${RT_DEF4[$R]}" ]] && continue
        net="${LAN_CIDR[$dl]}"
        put "ip route add ${net} via ${nh4}" "${R} non è collegato a ${dl} (${net}). Per raggiungerla passa dal router ${via}, che su una rete in comune ha IP ${nh4} (il next-hop deve essere raggiungibile direttamente). Serve anche la strada di ritorno: ${via} deve conoscere le reti di ${R}."
        if (( USE_IPV6 )) && [[ -n "$nh6" ]]; then
            put "ip -6 route add ${LAN_V6[$dl]}::/${LAN_V6PFX[$dl]} via ${nh6}" "Stessa rotta per IPv6."
        fi
    done <<< "${RT_ROUTES[$R]}"

    if [[ -n "${RT_DEF4[$R]}" ]]; then
        if [[ "${RT_DEFVIA[$R]}" == "ISP" ]]; then
            put "ip route add default via ${RT_DEF4[$R]}" "Default route: tutto ciò che non appartiene a reti note va al router dell'ISP (${RT_DEF4[$R]} su ${EXIT_LAN}). L'IP della WAN, se non è specificato dalla consegna, si sceglie liberamente purché la rete sia diversa dalle altre."
        else
            put "ip route add default via ${RT_DEF4[$R]}" "Default route: il traffico verso Internet passa da ${RT_DEFVIA[$R]} (${RT_DEF4[$R]}), il percorso verso il gateway Internet ${GW_INTERNET}."
        fi
        if (( USE_IPV6 )) && [[ -n "${RT_DEF6[$R]}" ]]; then
            put "ip -6 route add default via ${RT_DEF6[$R]}" "Default route IPv6."
        fi
    fi

    if [[ "$MODE" == dhcp ]]; then dhcp_block "$R"; fi
}

write_script() {
    printf '%s' "$BODY" > "$OUT/$1.sh"
    chmod +x "$OUT/$1.sh"
    DEVDOCS+="### \`$1.sh\` ($2)"$'\n\n'"${DOC}"$'\n'
}

start_order() {
    local MODE="$1" R H
    for R in "${ROUTERS[@]}"; do echo "rstart ${R} ${RT_LANS[$R]}"; done
    for H in "${HOSTS[@]}"; do
        [[ "$MODE" == dhcp && "${H_DHCP[$H]}" == 1 ]] && continue
        echo "hstart ${H} ${H_LAN[$H]}"
    done
    for H in "${HOSTS[@]}"; do
        [[ "$MODE" == dhcp && "${H_DHCP[$H]}" == 1 ]] && echo "hstart ${H} ${H_LAN[$H]}"
    done
}

write_start() {
    local MODE="$1"
    {
        echo "#!/bin/bash"
        echo '[ -n "$BASH_VERSION" ] || { echo "Usa da bash: source $0"; exit 1; }'
        echo '[[ "${BASH_SOURCE[0]}" != "$0" ]] || { echo "Usa: source $0"; exit 1; }'
        echo 'cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || return 1'
        start_order "$MODE"
    } > "$OUT/${ES_NAME}.sh"
    chmod +x "$OUT/${ES_NAME}.sh"
}

write_readme() {
    local MODE="$1" RUNDIR="$2" L R H ETH first x
    {
        echo "# Esercizio: ${ES_NAME}"
        echo ""
        if (( USE_DHCP )); then
            if (( TWO_PHASE )); then
                if [[ "$MODE" == static ]]; then
                    echo "> **Parte 1: indirizzamento statico** (prima consegna). La parte 2 con DHCP è nella cartella \`${ES_NAME}_fase2/${ES_NAME}\`."
                else
                    echo "> **Parte 2: con DHCP** (seconda consegna). I client DHCP non hanno più IP né rotta statici. La parte 1 è nella cartella \`${ES_NAME}\`."
                fi
            else
                echo "> **Esercizio con DHCP:** i client DHCP ricevono IP e gateway dal server."
            fi
            echo ""
        fi
        echo "## Topologia"
        echo ""
        echo "### Reti"
        for L in "${LANS[@]}"; do
            echo "- **$L**: ${LAN_CIDR[$L]} (maschera $(pfx_to_mask "${LAN_PFX[$L]}"), $(( (1 << (32 - ${LAN_PFX[$L]})) - 2 )) host utili), primo $(first_ip "${LAN_CIDR[$L]}"), ultimo $(last_ip "${LAN_CIDR[$L]}")"
            (( USE_IPV6 )) && echo "  - IPv6: ${LAN_V6[$L]}::/${LAN_V6PFX[$L]}"
            if [[ "${LAN_DHCP[$L]}" == 1 ]]; then
                x="  - DHCP: pool ${POOL_S[$L]} - ${POOL_E[$L]}, lease ${POOL_L[$L]}, server ${DHCP_SRV[$L]}"
                [[ -n "${LAN_GWR[$L]}" ]] && x+=", gateway distribuito $(rip "${LAN_GWR[$L]}" "$L")"
                [[ -n "${DHCP_DNS[$L]}" ]] && x+=", DNS ${DHCP_DNS[$L]}"
                [[ "$MODE" == static ]] && x+=" (da attivare nella parte 2)"
                echo "$x"
            fi
        done
        if (( ${#ROUTERS[@]} > 0 )); then
            echo ""
            echo "### Router"
            for R in "${ROUTERS[@]}"; do
                echo "- **$R**: ${RT_LANS[$R]}"
                ETH=0
                for L in ${RT_LANS[$R]}; do
                    echo "  - eth${ETH}: $(rip "$R" "$L")/${LAN_PFX[$L]} ($L)"
                    ETH=$((ETH+1))
                done
                [[ -n "${RT_DEF4[$R]}" ]] && echo "  - default via ${RT_DEF4[$R]}"
            done
        fi
        echo ""
        echo "### Host"
        for H in "${HOSTS[@]}"; do
            L="${H_LAN[$H]}"
            x=""; [[ -n "${LAN_GWR[$L]}" ]] && x="$(rip "${LAN_GWR[$L]}" "$L")"
            if [[ "$MODE" == dhcp && "${H_DHCP[$H]}" == 1 ]]; then
                echo "- **$H** ($L): client DHCP"
            else
                echo "- **$H** ($L): IP=${H_IP[$H]}/${LAN_PFX[$L]}  GW=${x:-nessuno}"
            fi
            (( USE_NGINX )) && [[ "$H" == "$NGINX_HOST" ]] && echo "  - nginx sulla porta ${NGINX_PORT}"
        done
        echo ""
        echo "## Cosa fa ogni script e perché"
        echo ""
        printf '%s' "$DEVDOCS"
        cat <<'GUIDE'
## Come ricavare i valori dalla consegna

- **Rete tipo 192.168.1.0/24**: /24 = maschera 255.255.255.0. Il primo indirizzo (.0) è la rete e l'ultimo (.255) il broadcast, non si assegnano. In una /n: primo = rete+1, ultimo = broadcast-1, penultimo = broadcast-2, host utili = 2^(32-n) - 2.
- **"primo / ultimo / penultimo indirizzo"**: si contano tra gli indirizzi assegnabili. Il plurale ("r_az: ultimi indirizzi") significa la stessa posizione in ogni rete a cui il dispositivo è collegato.
- **Una scheda = una rete**: un host ha un solo cavo e un IP; un router ha un IP per ogni rete collegata. L'ordine delle reti in `hstart`/`rstart` decide eth0, eth1, ...
- **Rete "non specificata"** (per esempio la WAN): se ne sceglie una libera, diversa da tutte le altre. Per un collegamento tra due router basta una /30 (2 host).
- **Gateway**: è l'IP del router sulla stessa rete dell'host. Per le reti lontane ogni router deve conoscere la strada di andata e di ritorno (rotte statiche o default route).
- **Pool DHCP "da A a B"**: diventa `dhcp-range=A,B,maschera,durata`. Gli IP statici (router, server) devono stare fuori dal pool.
- **Persistenza**: il simulatore ripristina i file a ogni avvio, per questo ogni configurazione sta negli script degli host.
GUIDE
        echo ""
        echo "## Avvio"
        echo "Dalla cartella degli script:"
        echo '```bash'
        echo "cd ${RUNDIR}"
        echo "source ${ES_NAME}.sh"
        echo '```'
        echo "Va caricato con \`source\`, non eseguito con \`bash\` o \`sh\`: così \`rstart\` e \`hstart\` girano nel tuo terminale come se li scrivessi a mano. Apre i dispositivi uno dopo l'altro (router, server e per ultimi i client DHCP): in ogni terminale scrivi \`exit\` per passare al successivo, il dispositivo resta attivo. Ogni dispositivo esegue da solo il proprio \`<nome>.sh\`. Per rientrare in un dispositivo: \`hstart <nome>\`; per cancellare tutto: \`clean\`."
        echo ""
        echo "Oppure a mano, un comando per terminale:"
        echo '```bash'
        start_order "$MODE"
        echo '```'
        echo ""
        echo "## Verifica"
        echo '```bash'
        echo "ip a; ip r"
        first=""
        for H in "${HOSTS[@]}"; do
            [[ "$MODE" == dhcp && "${H_DHCP[$H]}" == 1 ]] && continue
            first="$H"; break
        done
        if [[ -n "$first" ]]; then
            L="${H_LAN[$first]}"
            [[ -n "${LAN_GWR[$L]}" ]] && echo "# da ${first}: ping -c 2 $(rip "${LAN_GWR[$L]}" "$L")"
            for H in "${HOSTS[@]}"; do
                [[ "$H" == "$first" ]] && continue
                [[ "$MODE" == dhcp && "${H_DHCP[$H]}" == 1 ]] && continue
                echo "# da ${first}: ping -c 2 ${H_IP[$H]}   # ${H}"
            done
        fi
        for R in "${ROUTERS[@]}"; do
            echo "# su ${R}: ip r   # controlla le rotte"
        done
        echo "tcpdump -n -i eth0"
        if [[ "$MODE" == dhcp ]]; then
            for H in "${HOSTS[@]}"; do
                [[ "${H_DHCP[$H]}" == 1 ]] || continue
                L="${H_LAN[$H]}"
                x=""; [[ -n "${LAN_GWR[$L]}" ]] && x=", default via $(rip "${LAN_GWR[$L]}" "$L")"
                echo "# su ${H}: ip a ; ip r   # deve avere un IP tra ${POOL_S[$L]} e ${POOL_E[$L]}${x}"
            done
            for L in "${LANS[@]}"; do
                [[ "${LAN_DHCP[$L]}" == 1 ]] || continue
                echo "# su ${DHCP_SRV[$L]}: cat /tmp/dnsmasq-${DHCP_SRV[$L]}.leases ; cat /tmp/dnsmasq-${DHCP_SRV[$L]}.log"
                echo "# su ${DHCP_SRV[$L]}: tcpdump -n -i eth$(eth_of "${DHCP_SRV[$L]}" "$L") port 67 or port 68   # scambio DISCOVER/OFFER/REQUEST/ACK"
            done
        fi
        if (( USE_NGINX )); then
            x="${H_IP[$NGINX_HOST]}"; [[ "$NGINX_PORT" != 80 ]] && x+=":${NGINX_PORT}"
            echo "# da un client: links http://${x}   (oppure curl / wget)"
            echo "# su ${NGINX_HOST}: tcpdump -n -i eth0 port ${NGINX_PORT}   # 3-way handshake, GET, 200 OK, chiusura"
            echo "# su ${NGINX_HOST}: nginx -t ; nginx -s reload ; nginx -s stop"
        fi
        echo '```'
        if [[ "$MODE" == dhcp ]] && (( TWO_PHASE )); then
            echo ""
            echo "## Dalla parte 1 alla parte 2 a mano (se i dispositivi sono già attivi)"
            echo "Prima avvia il server DHCP, poi sui client:"
            echo '```bash'
            for H in "${HOSTS[@]}"; do
                [[ "${H_DHCP[$H]}" == 1 ]] || continue
                L="${H_LAN[$H]}"
                echo "# su ${H}:"
                echo "ip address del ${H_IP[$H]}/${LAN_PFX[$L]} dev eth0"
                echo "ip route del default"
                echo "dhclient -v eth0"
            done
            echo '```'
        fi
        echo ""
        echo "## Consegna"
        echo "Da eseguire nella cartella che contiene \`${ES_NAME}\`."
        echo '```bash'
        if (( TWO_PHASE )); then
            if [[ "$MODE" == static ]]; then
                echo "tar czf ${ES_NAME}.tar ${ES_NAME}                          # parte 1"
            else
                echo "tar czf ${ES_NAME}2.tar -C ${ES_NAME}_fase2 ${ES_NAME}     # parte 2"
            fi
        else
            echo "tar czf ${ES_NAME}.tar ${ES_NAME}"
        fi
        echo '```'
    } > "$OUT/README.md"
}

build_phase() {
    local MODE="$1" OUT="$2" RUNDIR="$3" H R DEVDOCS=""
    mkdir -p "$OUT" || err "Impossibile creare ${OUT}"
    for H in "${HOSTS[@]}"; do
        host_script "$H" "$MODE"
        write_script "$H" "host su ${H_LAN[$H]}"
        ok "Creato ${OUT}/${H}.sh"
    done
    for R in "${ROUTERS[@]}"; do
        router_script "$R" "$MODE"
        write_script "$R" "router"
        ok "Creato ${OUT}/${R}.sh"
    done
    write_start "$MODE"
    ok "Creato ${OUT}/${ES_NAME}.sh (avvio)"
    write_readme "$MODE" "$RUNDIR"
    ok "Creato ${OUT}/README.md"
}

header "Generazione file"

if [[ -d "$ES_NAME" ]]; then
    yesno "La cartella $ES_NAME esiste già: sovrascrivere i file? (s/n)" n || err "Annullato."
fi

if (( USE_DHCP && TWO_PHASE )); then
    build_phase static "$ES_NAME" "$ES_NAME"
    build_phase dhcp "${ES_NAME}_fase2/${ES_NAME}" "${ES_NAME}_fase2/${ES_NAME}"
    MAIN_MODE=static
elif (( USE_DHCP )); then
    build_phase dhcp "$ES_NAME" "$ES_NAME"
    MAIN_MODE=dhcp
else
    build_phase static "$ES_NAME" "$ES_NAME"
    MAIN_MODE=static
fi

header "Riepilogo"
echo -e "${BOLD}Reti:${NC}"
for L in "${LANS[@]}"; do
    echo -e "  ${CYAN}${L}${NC}: ${LAN_CIDR[$L]}  primo=$(first_ip "${LAN_CIDR[$L]}")  ultimo=$(last_ip "${LAN_CIDR[$L]}")$([[ ${LAN_DHCP[$L]} == 1 ]] && echo "  DHCP ${POOL_S[$L]}-${POOL_E[$L]} (${DHCP_SRV[$L]})")"
done
if (( ${#ROUTERS[@]} > 0 )); then
    echo -e "\n${BOLD}Router:${NC}"
    for R in "${ROUTERS[@]}"; do
        echo -ne "  ${CYAN}${R}${NC}:"
        ETH=0
        for L in ${RT_LANS[$R]}; do
            echo -ne "  eth${ETH}=$(rip "$R" "$L")/${LAN_PFX[$L]}(${L})"
            ETH=$((ETH+1))
        done
        echo ""
        while IFS='|' read -r dl nh4 nh6 via; do
            [[ -z "$dl" ]] && continue
            [[ -n "${RT_DEF4[$R]}" && "$nh4" == "${RT_DEF4[$R]}" ]] && continue
            echo -e "    ${YELLOW}↳${NC} ip route add ${LAN_CIDR[$dl]} via ${nh4}"
        done <<< "${RT_ROUTES[$R]}"
        [[ -n "${RT_DEF4[$R]}" ]] && echo -e "    ${YELLOW}↳${NC} ip route add default via ${RT_DEF4[$R]}"
    done
fi
echo -e "\n${BOLD}Host:${NC}"
for H in "${HOSTS[@]}"; do
    L="${H_LAN[$H]}"
    x=""; [[ -n "${LAN_GWR[$L]}" ]] && x="$(rip "${LAN_GWR[$L]}" "$L")"
    if [[ -z "${H_IP[$H]}" ]]; then
        echo -e "  ${CYAN}${H}${NC}: client DHCP  (${L})"
    else
        echo -e "  ${CYAN}${H}${NC}: ${H_IP[$H]}/${LAN_PFX[$L]}  gw=${x:-nessuno}  (${L})$([[ ${H_DHCP[$H]} == 1 ]] && echo '  [client DHCP nella parte 2]')$([[ -n "$NGINX_HOST" && "$H" == "$NGINX_HOST" ]] && echo "  [nginx :${NGINX_PORT}]")"
    fi
done
echo ""
if (( USE_DHCP && TWO_PHASE )); then
    echo -e "${GREEN}${BOLD}✓ Pronto.${NC} Parte 1 (statica): ${CYAN}${ES_NAME}/${NC}   Parte 2 (DHCP): ${CYAN}${ES_NAME}_fase2/${ES_NAME}/${NC}"
else
    echo -e "${GREEN}${BOLD}✓ Pronto.${NC} Cartella: ${CYAN}${ES_NAME}/${NC}"
fi
if (( USE_DHCP && TWO_PHASE )); then
    echo -e "${BOLD}Avvio parte 1:${NC} ${CYAN}cd ${ES_NAME} && source ${ES_NAME}.sh${NC}"
    echo -e "${BOLD}Avvio parte 2:${NC} ${CYAN}cd ${ES_NAME}_fase2/${ES_NAME} && source ${ES_NAME}.sh${NC}"
else
    echo -e "${BOLD}Avvio:${NC} ${CYAN}cd ${ES_NAME} && source ${ES_NAME}.sh${NC}"
fi
echo ""
