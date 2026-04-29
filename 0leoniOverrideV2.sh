#!/bin/bash
# ================================================================
#  NetLab Setup — Auto-configuratore esercizi di rete Linux
#  Compatibile con gli esercizi delle lezioni 2, 3 e 4
#  Genera: script .sh per ogni host/router + avvio tmux completo
# ================================================================

# ── Colori ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
info()   { echo -e "  ${BLUE}→${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()    { echo -e "  ${RED}✗ ERRORE:${NC} $*"; exit 1; }

# prompt <testo> <varname> [default]
prompt() {
    local _d="${3:+ [${3}]}"
    printf "${BOLD}%s%s:${NC} " "$1" "$_d"
    IFS= read -r _v
    [[ -z "$_v" && -n "$3" ]] && _v="$3"
    printf -v "$2" '%s' "$_v"
}

ABC=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)
abc=(a b c d e f g h i j k l m n o p q r s t u v w x y z)

# ================================================================
# ARITMETICA IP — lavora con indirizzi completi a 32 bit
# ================================================================

ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ip() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# Indirizzo di rete (host bits = 0) da CIDR "a.b.c.d/pfx"
net_addr() {
    local ip="${1%/*}" pfx="${1##*/}"
    local n; n=$(ip_to_int "$ip")
    local mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    int_to_ip $(( n & mask ))
}

# Primo indirizzo host (network + 1)
first_ip() {
    local ip="${1%/*}" pfx="${1##*/}"
    local n; n=$(ip_to_int "$ip")
    local mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    int_to_ip $(( (n & mask) + 1 ))
}

# Ultimo indirizzo host (broadcast - 1)
last_ip() {
    local ip="${1%/*}" pfx="${1##*/}"
    local n; n=$(ip_to_int "$ip")
    local mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    local net=$(( n & mask ))
    local bcast=$(( net | (~mask & 0xFFFFFFFF) ))
    int_to_ip $(( bcast - 1 ))
}

# N-esimo indirizzo host dalla rete (1 = primo host, 2 = secondo, ...)
nth_ip() {
    local ip="${1%/*}" pfx="${1##*/}" n_host=$2
    local n; n=$(ip_to_int "$ip")
    local mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    int_to_ip $(( (n & mask) + n_host ))
}

# Richiede primo/ultimo/specifico e restituisce l'IP scelto
# Uso: pick_ip <CIDR> <varname> [label]
pick_ip() {
    local CIDR="$1" VARNAME="$2" LABEL="${3:-interfaccia}"
    local FIRST LAST
    FIRST=$(first_ip "$CIDR")
    LAST=$(last_ip  "$CIDR")
    info "  Rete ${CIDR}  →  primo host: ${FIRST}   ultimo host: ${LAST}"
    prompt "  ${LABEL}: primo (p), ultimo (u) o inserisci IP manualmente (m)?" _choice "p"
    local CHOSEN=""
    case "$_choice" in
        [uU]) CHOSEN="$LAST" ;;
        [mM])
            prompt "  Inserisci IP (senza prefisso)" _manual ""
            CHOSEN="$_manual"
            ;;
        *)    CHOSEN="$FIRST" ;;
    esac
    printf -v "$VARNAME" '%s' "$CHOSEN"
}

# ================================================================
clear
echo -e "${CYAN}${BOLD}"
cat <<'LOGO'
  Auto-Setup Esercizi di Rete
LOGO
echo -e "${NC}"

# ================================================================
# 1. INFORMAZIONI GENERALI
# ================================================================
header "Informazioni Generali"

prompt "Nome esercizio (sarà il nome della cartella)" ES_NAME "es_lab"
[[ -z "$ES_NAME" ]] && err "Il nome non può essere vuoto."

prompt "Usare IPv6 oltre a IPv4? (s/n)" _v6 "n"
[[ "$_v6" =~ ^[sS] ]] && USE_IPV6=1 || USE_IPV6=0

prompt "Aggiungere configurazione web server nginx? (s/n)" _ng "n"
[[ "$_ng" =~ ^[sS] ]] && USE_NGINX=1 || USE_NGINX=0

# ================================================================
# 2. LAN
# ================================================================
header "Configurazione LAN"
prompt "Numero di LAN" N_LANS "2"
[[ ! "$N_LANS" =~ ^[0-9]+$ || "$N_LANS" -lt 1 ]] && err "Numero non valido."

declare -a LANS=()
declare -A LAN_CIDR=()    # lanX → "a.b.c.d/pfx"  (network address normalizzato)
declare -A LAN_PFX=()     # lanX → "24"
declare -A LAN_V6=()
declare -A LAN_V6PFX=()
declare -A LAN_RCNT=()
declare -A LAN_HCNT=()    # contatore IP sequenziali per host

for ((i=0; i<N_LANS; i++)); do
    DEF_LAN="lan${ABC[$i]}"
    prompt "  Nome LAN $((i+1))" LNAME "$DEF_LAN"
    LANS+=("$LNAME")

    DEF_NET="192.168.$((i+1)).0/24"
    prompt "  Rete per $LNAME (CIDR, es. 192.168.$((i+1)).0/24)" NETCIDR "$DEF_NET"

    PFX="${NETCIDR##*/}"
    NETADDR=$(net_addr "$NETCIDR")
    LAN_CIDR[$LNAME]="${NETADDR}/${PFX}"
    LAN_PFX[$LNAME]="$PFX"
    LAN_RCNT[$LNAME]=0
    LAN_HCNT[$LNAME]=0

    if [[ $USE_IPV6 -eq 1 ]]; then
        prompt "  Prefisso IPv6 per $LNAME (es. 2a00:0:0:a)" V6P "2a00:0:0:${abc[$i]}"
        prompt "  Lunghezza prefisso IPv6" V6L "64"
        LAN_V6[$LNAME]="$V6P"
        LAN_V6PFX[$LNAME]="$V6L"
    fi

    ok "$LNAME → ${LAN_CIDR[$LNAME]}   primo=$(first_ip "${LAN_CIDR[$LNAME]}")   ultimo=$(last_ip "${LAN_CIDR[$LNAME]}")"
done

# ================================================================
# 3. ROUTER
# ================================================================
header "Configurazione Router"
prompt "Numero di router (0 se nessuno)" N_ROUTERS "1"
[[ ! "$N_ROUTERS" =~ ^[0-9]+$ ]] && err "Numero non valido."

declare -a ROUTERS=()
declare -A RT_LANS=()
declare -A RT_IP=()      # "router:lanX" → IP completo (es. "192.168.1.254")
declare -A RT_ROUTES=()

for ((i=0; i<N_ROUTERS; i++)); do
    DEF_R="r${ABC[$i]}${ABC[$((i+1))]}"
    prompt "  Nome router $((i+1))" RNAME "$DEF_R"
    ROUTERS+=("$RNAME")

    info "LAN disponibili: ${LANS[*]}"
    prompt "  LAN collegate a $RNAME (separate da spazio, es. lanA lanB)" RLANS ""
    [[ -z "$RLANS" ]] && warn "Nessuna LAN specificata per $RNAME."
    RT_LANS[$RNAME]="$RLANS"

    ETH=0
    for LAN in $RLANS; do
        CHOSEN_IP=""
        pick_ip "${LAN_CIDR[$LAN]}" CHOSEN_IP "  $RNAME/eth${ETH} su $LAN"
        RT_IP["${RNAME}:${LAN}"]="$CHOSEN_IP"
        ok "  $RNAME eth${ETH} → ${CHOSEN_IP}/${LAN_PFX[$LAN]} ($LAN)"
        ETH=$((ETH+1))
    done
done

# ================================================================
# 4. HOST
# ================================================================
header "Configurazione Host"

declare -a HOSTS=()
declare -A H_LAN=()
declare -A H_IP=()    # host → IP completo

for LAN in "${LANS[@]}"; do
    prompt "Numero di host nella LAN $LAN (0 = LAN di transito)" NH "1"
    [[ ! "$NH" =~ ^[0-9]+$ ]] && err "Numero non valido."
    [[ "$NH" -eq 0 ]] && { info "  $LAN → LAN di transito (nessun host)"; continue; }

    for ((j=1; j<=NH; j++)); do
        DEF_H="pc${j}${LAN//lan/}"
        prompt "  Nome host $j su $LAN" HNAME "$DEF_H"
        HOSTS+=("$HNAME")
        H_LAN[$HNAME]="$LAN"

        IDX="${LAN_HCNT[$LAN]}"
        SEQ_IP=$(nth_ip "${LAN_CIDR[$LAN]}" $((IDX + 1)))
        FIRST_H=$(first_ip "${LAN_CIDR[$LAN]}")
        LAST_H=$(last_ip  "${LAN_CIDR[$LAN]}")

        info "  Rete ${LAN_CIDR[$LAN]}  →  primo: ${FIRST_H}   ultimo: ${LAST_H}   sequenziale: ${SEQ_IP}"
        prompt "  $HNAME: primo (p), ultimo (u), sequenziale (s) o manuale (m)?" _hchoice "s"

        case "$_hchoice" in
            [pP]) CHOSEN_IP="$FIRST_H" ;;
            [uU]) CHOSEN_IP="$LAST_H"  ;;
            [mM])
                prompt "  Inserisci IP (senza prefisso)" _manual ""
                CHOSEN_IP="$_manual"
                ;;
            *)    CHOSEN_IP="$SEQ_IP"  ;;
        esac

        H_IP[$HNAME]="$CHOSEN_IP"
        LAN_HCNT[$LAN]=$((IDX + 1))
        ok "  $HNAME → ${CHOSEN_IP}/${LAN_PFX[$LAN]} ($LAN)"
    done
done

# ================================================================
# 5. OPZIONI NGINX
# ================================================================
NGINX_HOST=""
NGINX_PORT="80"
NGINX_ROOT="/var/www/html"
MAKE_HTML=0
HTML_NOME=""; HTML_COGNOME=""; HTML_CF=""; HTML_TITLE=""; HTML_EXTRA=""

if [[ $USE_NGINX -eq 1 ]]; then
    echo ""
    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        warn "Nessun host definito: impossibile configurare nginx."
        USE_NGINX=0
    else
        info "Host disponibili: ${HOSTS[*]}"
        prompt "Su quale host avviare nginx?" NGINX_HOST "${HOSTS[-1]}"
        prompt "Porta di ascolto nginx" NGINX_PORT "80"
        prompt "Directory root del sito (es. /var/www/html)" NGINX_ROOT "/var/www/html"
        prompt "Creare un index.html personalizzato? (s/n)" _mkhtml "s"
        [[ "$_mkhtml" =~ ^[sS] ]] && MAKE_HTML=1 || MAKE_HTML=0
        if [[ $MAKE_HTML -eq 1 ]]; then
            prompt "Titolo pagina HTML" HTML_TITLE "Il mio server"
            prompt "Nome" HTML_NOME ""
            prompt "Cognome" HTML_COGNOME ""
            prompt "Codice fiscale" HTML_CF ""
            prompt "Testo aggiuntivo (facoltativo)" HTML_EXTRA ""
        fi
    fi
fi

# ================================================================
# 6. CALCOLO ROTTE (BFS per ogni router)
# ================================================================
_calc_routes() {
    local ROUTER="$1"
    local ROUTES=""

    local -A vis_lan=()
    local -A vis_rtr=()
    local -a queue=()     # elementi: "router|nexthop_ipv4"

    vis_rtr[$ROUTER]=1
    for L in ${RT_LANS[$ROUTER]}; do
        vis_lan[$L]="direct"
    done

    # Seed: router vicini che condividono una LAN
    for L in ${RT_LANS[$ROUTER]}; do
        for R2 in "${ROUTERS[@]}"; do
            [[ "$R2" == "$ROUTER" ]] && continue
            [[ -n "${vis_rtr[$R2]}" ]] && continue
            for RL2 in ${RT_LANS[$R2]}; do
                if [[ "$RL2" == "$L" ]]; then
                    NH4="${RT_IP["${R2}:${L}"]}"
                    queue+=("${R2}|${NH4}")
                    vis_rtr[$R2]=1
                    break
                fi
            done
        done
    done

    # BFS
    while [[ ${#queue[@]} -gt 0 ]]; do
        local ITEM="${queue[0]}"
        queue=("${queue[@]:1}")
        local CURR_R="${ITEM%%|*}"
        local CURR_NH4="${ITEM##*|}"

        for L in ${RT_LANS[$CURR_R]}; do
            if [[ -z "${vis_lan[$L]}" ]]; then
                vis_lan[$L]="$CURR_NH4"
                local NET_A PFX_L
                NET_A=$(net_addr "${LAN_CIDR[$L]}")
                PFX_L="${LAN_PFX[$L]}"
                ROUTES+="ip route add ${NET_A}/${PFX_L} via ${CURR_NH4}\n"
                if [[ $USE_IPV6 -eq 1 ]]; then
                    local OCT4
                    OCT4=$(echo "$CURR_NH4" | cut -d. -f4)
                    ROUTES+="ip route add ${LAN_V6[$L]}::/${LAN_V6PFX[$L]} via ${LAN_V6[$L]}::${OCT4}\n"
                fi
            fi
        done

        for L in ${RT_LANS[$CURR_R]}; do
            for R3 in "${ROUTERS[@]}"; do
                [[ -n "${vis_rtr[$R3]}" ]] && continue
                for RL3 in ${RT_LANS[$R3]}; do
                    if [[ "$RL3" == "$L" ]]; then
                        vis_rtr[$R3]=1
                        queue+=("${R3}|${CURR_NH4}")
                        break
                    fi
                done
            done
        done
    done

    RT_ROUTES[$ROUTER]="$ROUTES"
}

for R in "${ROUTERS[@]}"; do
    _calc_routes "$R"
done

# ================================================================
# 7. GENERAZIONE FILE
# ================================================================
header "Generazione file di configurazione"

mkdir -p "$ES_NAME" || err "Impossibile creare la directory $ES_NAME"
cd "$ES_NAME" || exit 1

# Gateway IPv4 per un host
_gw4() {
    local LAN="${H_LAN[$1]}"
    for R in "${ROUTERS[@]}"; do
        for RL in ${RT_LANS[$R]}; do
            [[ "$RL" == "$LAN" ]] && echo "${RT_IP["${R}:${LAN}"]}" && return
        done
    done
}

# Gateway IPv6 per un host (usa l'ultimo ottetto del GW IPv4 come suffisso)
_gw6() {
    local LAN="${H_LAN[$1]}"
    for R in "${ROUTERS[@]}"; do
        for RL in ${RT_LANS[$R]}; do
            if [[ "$RL" == "$LAN" ]]; then
                local OCT4
                OCT4=$(echo "${RT_IP["${R}:${LAN}"]}" | cut -d. -f4)
                echo "${LAN_V6[$LAN]}::${OCT4}"
                return
            fi
        done
    done
}

# ── Script per ogni HOST ─────────────────────────────────────────
for H in "${HOSTS[@]}"; do
    LAN="${H_LAN[$H]}"
    IP4="${H_IP[$H]}/${LAN_PFX[$LAN]}"
    GW4=$(_gw4 "$H")

    {
        echo "#!/bin/bash"
        echo "# ────────────────────────────────"
        echo "# Host : $H"
        echo "# LAN  : $LAN"
        echo "# IPv4 : $IP4  gw: ${GW4:-nessuno}"
        if [[ $USE_IPV6 -eq 1 ]]; then
            OCT4=$(echo "${H_IP[$H]}" | cut -d. -f4)
            echo "# IPv6 : ${LAN_V6[$LAN]}::${OCT4}/${LAN_V6PFX[$LAN]}"
        fi
        echo "# ────────────────────────────────"
        echo ""

        echo "ip address add $IP4 dev eth0"
        [[ -n "$GW4" ]] && echo "ip route add default via $GW4"

        if [[ $USE_IPV6 -eq 1 ]]; then
            OCT4=$(echo "${H_IP[$H]}" | cut -d. -f4)
            IP6="${LAN_V6[$LAN]}::${OCT4}/${LAN_V6PFX[$LAN]}"
            GW6=$(_gw6 "$H")
            echo "ip address add $IP6 dev eth0"
            [[ -n "$GW6" ]] && echo "ip route add default via $GW6 dev eth0"
        fi

        if [[ "$H" == "$NGINX_HOST" ]]; then
            echo ""
            echo "# ── Configurazione nginx ──"
            if [[ "$NGINX_PORT" != "80" ]]; then
                echo "sed -i 's/listen 80 default_server/listen ${NGINX_PORT} default_server/g' /etc/nginx/sites-enabled/default"
                echo "sed -i 's/listen \[::]:80 default_server/listen [::]:${NGINX_PORT} default_server/g' /etc/nginx/sites-enabled/default"
            fi
            if [[ "$NGINX_ROOT" != "/var/www/html" ]]; then
                echo "sed -i 's|root /var/www/html|root ${NGINX_ROOT}|g' /etc/nginx/sites-enabled/default"
                echo "mkdir -p ${NGINX_ROOT}"
            fi
            if [[ $MAKE_HTML -eq 1 ]]; then
                NOME_LINE=""; COG_LINE=""; CF_LINE=""; EXTRA_LINE=""
                [[ -n "$HTML_NOME" ]]    && NOME_LINE="<p><strong>Nome:</strong> ${HTML_NOME}</p>"
                [[ -n "$HTML_COGNOME" ]] && COG_LINE="<p><strong>Cognome:</strong> ${HTML_COGNOME}</p>"
                [[ -n "$HTML_CF" ]]      && CF_LINE="<p><strong>Codice fiscale:</strong> ${HTML_CF}</p>"
                [[ -n "$HTML_EXTRA" ]]   && EXTRA_LINE="<p>${HTML_EXTRA}</p>"
                cat <<HTMLEOF
cat <<EOF > ${NGINX_ROOT}/index.html
<!DOCTYPE html>
<html lang="it">
<head><meta charset="UTF-8"><title>${HTML_TITLE}</title></head>
<body>
  <h1>${HTML_TITLE}</h1>
  ${NOME_LINE}
  ${COG_LINE}
  ${CF_LINE}
  ${EXTRA_LINE}
  <p><a href="pagina2.html">Seconda pagina</a></p>
</body>
</html>
EOF
cat <<EOF > ${NGINX_ROOT}/pagina2.html
<!DOCTYPE html>
<html lang="it">
<head><meta charset="UTF-8"><title>Pagina 2 — ${HTML_TITLE}</title></head>
<body>
  <h1>Pagina 2</h1>
  <p><a href="index.html">← Home</a></p>
</body>
</html>
EOF
HTMLEOF
            fi
            echo "nginx -t && nginx"
            echo "echo 'nginx avviato su porta ${NGINX_PORT}, root: ${NGINX_ROOT}'"
        fi
    } > "${H}.sh"
    ok "Creato ${H}.sh  (IP: $IP4, GW: ${GW4:-nessuno})"
done

# ── Script per ogni ROUTER ───────────────────────────────────────
for R in "${ROUTERS[@]}"; do
    {
        echo "#!/bin/bash"
        echo "# ────────────────────────────────"
        echo "# Router: $R"
        echo "# LAN  : ${RT_LANS[$R]}"
        echo "# ────────────────────────────────"
        echo ""

        ETH=0
        for LAN in ${RT_LANS[$R]}; do
            FULL_IP="${RT_IP["${R}:${LAN}"]}"
            IP4="${FULL_IP}/${LAN_PFX[$LAN]}"
            echo "# eth${ETH} <-> $LAN"
            echo "ip address add $IP4 dev eth${ETH}"
            if [[ $USE_IPV6 -eq 1 ]]; then
                OCT4=$(echo "$FULL_IP" | cut -d. -f4)
                echo "ip address add ${LAN_V6[$LAN]}::${OCT4}/${LAN_V6PFX[$LAN]} dev eth${ETH}"
            fi
            ETH=$((ETH+1))
        done

        RROUTES="${RT_ROUTES[$R]}"
        if [[ -n "$RROUTES" ]]; then
            echo ""
            echo "# ── Rotte verso reti non direttamente connesse ──"
            echo -e "$RROUTES"
        fi
    } > "${R}.sh"
    ok "Creato ${R}.sh"
done

# ── Script principale tmux ───────────────────────────────────────
{
    echo "#!/bin/bash"
    echo ""
    echo "tmux new-session -d -s debian-net -n Console"
    echo ""

    if [[ ${#HOSTS[@]} -gt 0 ]]; then
        echo "# ── Avvio Host ──"
        for H in "${HOSTS[@]}"; do
            LAN="${H_LAN[$H]}"
            echo "tmux new-window -t debian-net -n ${H} \"bash -ic 'hstart ${H} ${LAN}'\""
        done
        echo ""
    fi

    if [[ ${#ROUTERS[@]} -gt 0 ]]; then
        echo "# ── Avvio Router ──"
        for R in "${ROUTERS[@]}"; do
            echo "tmux new-window -t debian-net -n ${R} \"bash -ic 'rstart ${R} ${RT_LANS[$R]}'\""
        done
        echo ""
    fi

    echo "tmux attach -t debian-net"
} > "${ES_NAME}.sh"
chmod +x "${ES_NAME}.sh"
ok "Creato ${ES_NAME}.sh (script di avvio principale)"

# ── README riepilogativo ─────────────────────────────────────────
{
    echo "# Esercizio: $ES_NAME"
    echo ""
    echo "## Topologia"
    echo ""
    echo "### LAN"
    for L in "${LANS[@]}"; do
        echo "- **$L**: ${LAN_CIDR[$L]}   primo: $(first_ip "${LAN_CIDR[$L]}")   ultimo: $(last_ip "${LAN_CIDR[$L]}")"
        [[ $USE_IPV6 -eq 1 ]] && echo "  IPv6: ${LAN_V6[$L]}::/${LAN_V6PFX[$L]}"
    done
    echo ""
    echo "### Router"
    for R in "${ROUTERS[@]}"; do
        echo "- **$R**: LAN connesse → ${RT_LANS[$R]}"
        ETH=0
        for LAN in ${RT_LANS[$R]}; do
            echo "  - eth${ETH}: ${RT_IP["${R}:${LAN}"]}/${LAN_PFX[$LAN]} ($LAN)"
            ETH=$((ETH+1))
        done
        if [[ -n "${RT_ROUTES[$R]}" ]]; then
            echo "  - Rotte statiche:"
            while IFS= read -r line; do
                [[ -n "$line" ]] && echo "    - $line"
            done <<< "$(echo -e "${RT_ROUTES[$R]}")"
        fi
    done
    echo ""
    echo "### Host"
    for H in "${HOSTS[@]}"; do
        LAN="${H_LAN[$H]}"
        IP="${H_IP[$H]}/${LAN_PFX[$LAN]}"
        GW=$(_gw4 "$H")
        echo "- **$H** ($LAN): IP=$IP  GW=${GW:-nessuno}"
        [[ $USE_IPV6 -eq 1 ]] && echo "  IPv6: ${LAN_V6[$LAN]}::$(echo "${H_IP[$H]}" | cut -d. -f4)/${LAN_V6PFX[$LAN]}"
        [[ "$H" == "$NGINX_HOST" ]] && echo "  ← nginx server (porta $NGINX_PORT)"
    done
    echo ""
    echo "## Avvio"
    echo '```bash'
    echo "cd $ES_NAME && bash ${ES_NAME}.sh"
    echo '```'
    echo ""
    echo "## Comandi utili"
    echo '```bash'
    echo "ping <ip_destinazione>"
    echo "tcpdump -n -i eth0"
    if [[ $USE_NGINX -eq 1 && -n "$NGINX_HOST" ]]; then
        IP_SRV="${H_IP[$NGINX_HOST]}"
        echo "curl http://${IP_SRV}:${NGINX_PORT}"
    fi
    echo "tar -czvf ${ES_NAME}.tgz ${ES_NAME}/"
    echo '```'
} > README.md
ok "Creato README.md"

# ================================================================
# 8. RIEPILOGO FINALE
# ================================================================
header "Riepilogo Configurazione"

echo -e "${BOLD}LAN:${NC}"
for L in "${LANS[@]}"; do
    echo -e "  ${CYAN}${L}${NC}: ${LAN_CIDR[$L]}   primo=$(first_ip "${LAN_CIDR[$L]}")   ultimo=$(last_ip "${LAN_CIDR[$L]}")"
done

if [[ ${#ROUTERS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}Router:${NC}"
    for R in "${ROUTERS[@]}"; do
        echo -ne "  ${CYAN}${R}${NC}:"
        ETH=0
        for LAN in ${RT_LANS[$R]}; do
            echo -ne "  eth${ETH}=${RT_IP["${R}:${LAN}"]}/${LAN_PFX[$LAN]}(${LAN})"
            ETH=$((ETH+1))
        done
        echo ""
        if [[ -n "${RT_ROUTES[$R]}" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && echo -e "    ${YELLOW}↳${NC} $line"
            done <<< "$(echo -e "${RT_ROUTES[$R]}")"
        fi
    done
fi

echo ""
echo -e "${BOLD}Host:${NC}"
for H in "${HOSTS[@]}"; do
    LAN="${H_LAN[$H]}"
    IP="${H_IP[$H]}/${LAN_PFX[$LAN]}"
    GW=$(_gw4 "$H")
    EXTRA=""
    [[ "$H" == "$NGINX_HOST" ]] && EXTRA=" ${YELLOW}[nginx :${NGINX_PORT}]${NC}"
    echo -e "  ${CYAN}${H}${NC}: ${IP}  gw=${GW:-nessuno}  (${LAN})${EXTRA}"
done

echo ""
echo -e "${BOLD}File generati in:${NC} ${ES_NAME}/"
for F in "${HOSTS[@]}" "${ROUTERS[@]}"; do echo "  ${F}.sh"; done
echo "  ${ES_NAME}.sh  ← script di avvio principale"
echo "  README.md"

echo ""
echo -e "${GREEN}${BOLD}✓ Tutto pronto!${NC}"
echo -e "${BOLD}Per avviare l'esercizio:${NC}"
echo -e "  ${CYAN}cd ${ES_NAME} && bash ${ES_NAME}.sh${NC}"
echo ""