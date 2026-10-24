#!/usr/bin/env bash

set -Eeuo pipefail
set +H

# ============================================================
# VARIÁVEIS OBRIGATÓRIAS
# ============================================================

: "${ROLE:?Informe ROLE=PRIMARY ou SECONDARY}"

: "${PRIMARY_HOSTNAME:?Informe PRIMARY_HOSTNAME}"
: "${PRIMARY_IP:?Informe PRIMARY_IP}"

: "${SECONDARY_HOSTNAME:?Informe SECONDARY_HOSTNAME}"
: "${SECONDARY_IP:?Informe SECONDARY_IP}"

: "${DOMAIN:?Informe DOMAIN}"
: "${NETBIOS:?Informe NETBIOS}"

: "${PREFIX:?Informe PREFIX}"
: "${GW:?Informe GW}"

: "${PIHOLE1:?Informe PIHOLE1}"
: "${PIHOLE2:?Informe PIHOLE2}"

: "${NTP:?Informe NTP}"
: "${REVERSE_ZONE:?Informe REVERSE_ZONE}"

# ============================================================
# VARIÁVEIS OPCIONAIS
# ============================================================

REALM="${REALM:-${DOMAIN^^}}"

UPDATE_SYSTEM="${UPDATE_SYSTEM:-yes}"

SYSVOL_SYNC_SECONDS="${SYSVOL_SYNC_SECONDS:-60}"
IDMAP_SYNC_SECONDS="${IDMAP_SYNC_SECONDS:-3600}"
SYSVOL_ACL_CHECK_SECONDS="${SYSVOL_ACL_CHECK_SECONDS:-300}"

DRS_WAIT_SECONDS="${DRS_WAIT_SECONDS:-180}"
DNS_REPLICATION_WAIT_SECONDS="${DNS_REPLICATION_WAIT_SECONDS:-180}"

TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
IFACE="${IFACE:-eth0}"

# O script sempre TESTA os Pi-hole.
# "yes" = falha nos Pi-hole também torna o exit code do script != 0.
# "no"  = auditoria mostra a falha, mas não invalida a configuração Samba/AD.
REQUIRE_PIHOLE_AUDIT="${REQUIRE_PIHOLE_AUDIT:-no}"

# ============================================================
# DERIVAÇÕES
# ============================================================

ROLE="${ROLE^^}"

case "$ROLE" in
    PRIMARY)
        HOSTNAME="$PRIMARY_HOSTNAME"
        IP="$PRIMARY_IP"
        PEER_HOSTNAME="$SECONDARY_HOSTNAME"
        PEER_IP="$SECONDARY_IP"
        ;;
    SECONDARY)
        HOSTNAME="$SECONDARY_HOSTNAME"
        IP="$SECONDARY_IP"
        PEER_HOSTNAME="$PRIMARY_HOSTNAME"
        PEER_IP="$PRIMARY_IP"
        ;;
    *)
        echo "ERRO: ROLE deve ser PRIMARY ou SECONDARY"
        exit 1
        ;;
esac

FQDN="${HOSTNAME}.${DOMAIN}"
CIDR="${IP}/${PREFIX}"

PRIMARY_FQDN="${PRIMARY_HOSTNAME}.${DOMAIN}"
SECONDARY_FQDN="${SECONDARY_HOSTNAME}.${DOMAIN}"
PEER_FQDN="${PEER_HOSTNAME}.${DOMAIN}"

PTR_NAME="${IP##*.}"

LOG="/root/configurar-${HOSTNAME}.log"
RESULT="/root/resultado-${HOSTNAME}.txt"

ADMIN_PASSWORD_FILE="/root/AD-Administrator-password.txt"
AUTH_FILE="/root/.samba-admin-${HOSTNAME}.conf"

SAMDB="/var/lib/samba/private/sam.ldb"
IDMAP="/var/lib/samba/private/idmap.ldb"
SYSVOL="/var/lib/samba/sysvol"

SYSVOL_KEY="/root/.ssh/id_ed25519_sysvol"

ETAPA="INICIO"

ADPASS=""
PRIMARY_ROOT_PASS=""

# ============================================================
# LOG
# ============================================================

exec 3>&1 4>&2

: >"$LOG"

exec >"$LOG" 2>&1

# ============================================================
# FUNÇÕES GERAIS
# ============================================================

status() {
    printf "[%s] %s\n" "$1" "$2" >&3
}

prompt_secret() {
    local TEXTO="$1"
    local VARIAVEL="$2"
    local VALOR=""

    printf "%s" "$TEXTO" >/dev/tty
    IFS= read -r -s VALOR </dev/tty
    printf "\n" >/dev/tty

    printf -v "$VARIAVEL" '%s' "$VALOR"
}

cleanup_secrets() {
    ADPASS=""
    PRIMARY_ROOT_PASS=""

    rm -f "$AUTH_FILE" 2>/dev/null || true
}

falha() {
    local RC=$?

    trap - ERR

    cleanup_secrets

    exec 1>&3 2>&4

    clear 2>/dev/null || true

    echo "============================================================"
    echo " ${HOSTNAME} - ERRO"
    echo "============================================================"
    echo
    echo "ETAPA....... ${ETAPA}"
    echo "CODIGO...... ${RC}"
    echo "LOG......... ${LOG}"
    echo
    echo "ULTIMAS LINHAS:"
    echo

    tail -n 25 "$LOG" 2>/dev/null || true

    echo
    echo "============================================================"

    exit "$RC"
}

trap falha ERR

# ============================================================
# 1. VALIDAR VM LIMPA
# ============================================================

ETAPA="VALIDAR_VM_LIMPA"

status "1/10" "Validando VM, rede e horário"

[[ "$(hostname)" == "$HOSTNAME" ]]
[[ "$(hostname -f)" == "$FQDN" ]]

ip -4 -o addr show "$IFACE" | grep -q "${CIDR}"
ip route | grep -q "^default via ${GW}"

if [[ -e "$SAMDB" ]]; then
    echo "A VM já possui ${SAMDB}."
    echo "Recrie a VM antes de executar este script."
    false
fi

cat >/etc/hosts <<EOF
127.0.0.1 localhost
${IP} ${FQDN} ${HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

mkdir -p /etc/systemd/timesyncd.conf.d

cat >/etc/systemd/timesyncd.conf.d/10-setec.conf <<EOF
[Time]
NTP=${NTP}
FallbackNTP=
EOF

timedatectl set-timezone "$TIMEZONE"

systemctl restart systemd-timesyncd

ping -c1 -W2 "$GW" >/dev/null
ping -c1 -W2 "$PIHOLE1" >/dev/null
ping -c1 -W2 "$PIHOLE2" >/dev/null

getent ahostsv4 deb.debian.org >/dev/null

# ============================================================
# 2. PACOTES
# ============================================================

ETAPA="INSTALAR_PACOTES"

status "2/10" "Instalando pré-requisitos"

export DEBIAN_FRONTEND=noninteractive

apt-get update

if [[ "$UPDATE_SYSTEM" == "yes" ]]; then
    apt-get -y full-upgrade
fi

PACOTES=(
    samba-ad-dc
    samba
    smbclient
    winbind
    libnss-winbind
    libpam-winbind
    krb5-user
    bind9-dnsutils
    ldb-tools
    acl
    attr
    python3-cryptography
    rsync
    tdb-tools
    openssh-client
    util-linux
)

apt-get install -y "${PACOTES[@]}"

dpkg --configure -a

unset DEBIAN_FRONTEND

for CMD in samba-tool samba smbclient wbinfo rsync tdbbackup host dig flock ssh; do
    command -v "$CMD" >/dev/null
done

# ============================================================
# 3. PREPARAR SERVIÇOS
# ============================================================

ETAPA="PREPARAR_SERVICOS"

status "3/10" "Preparando Samba, DNS e serviços"

systemctl stop samba-ad-dc 2>/dev/null || true
systemctl stop smbd 2>/dev/null || true
systemctl stop nmbd 2>/dev/null || true
systemctl stop winbind 2>/dev/null || true

systemctl disable smbd 2>/dev/null || true
systemctl disable nmbd 2>/dev/null || true
systemctl disable winbind 2>/dev/null || true

systemctl mask smbd 2>/dev/null || true
systemctl mask nmbd 2>/dev/null || true
systemctl mask winbind 2>/dev/null || true

systemctl disable --now systemd-resolved 2>/dev/null || true

rm -f /etc/resolv.conf
rm -f /etc/samba/smb.conf

# ============================================================
# DNS TEMPORÁRIO
# ============================================================

ETAPA="DNS_TEMPORARIO"

if [[ "$ROLE" == "PRIMARY" ]]; then

    cat >/etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${PIHOLE1}
nameserver ${PIHOLE2}
EOF

else

    cat >/etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${PRIMARY_IP}
EOF

    ping -c1 -W2 "$PRIMARY_IP" >/dev/null

    host -W3 -t A "$PRIMARY_FQDN" "$PRIMARY_IP" | grep -q "$PRIMARY_IP"

    host -W3 -t SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" "$PRIMARY_IP" | grep -qi "$PRIMARY_FQDN"

    host -W3 -t SRV "_kerberos._tcp.${DOMAIN}" "$PRIMARY_IP" | grep -qi "$PRIMARY_FQDN"

fi

chmod 644 /etc/resolv.conf

# ============================================================
# 4A. PRIMARY
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    ETAPA="PROVISIONAR_PRIMARY"

    status "4/10" "Provisionando primeiro controlador de domínio"

    umask 077

    ADPASS="Adm_$(openssl rand -hex 18)_Z9a"

    printf "%s\n" "$ADPASS" >"$ADMIN_PASSWORD_FILE"

    chmod 600 "$ADMIN_PASSWORD_FILE"

    samba-tool domain provision --server-role=dc --realm="$REALM" --domain="$NETBIOS" --dns-backend=SAMBA_INTERNAL --host-ip="$IP" --use-rfc2307 --adminpass="$ADPASS"

fi

# ============================================================
# 4B. SECONDARY
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="PREPARAR_PRIMARY"

    status "4/10" "Preparando acesso seguro ao ${PRIMARY_HOSTNAME}"

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    if [[ ! -f "$SYSVOL_KEY" ]]; then
        ssh-keygen -q -t ed25519 -N "" -f "$SYSVOL_KEY" -C "${HOSTNAME}-sysvol"
    fi

    ssh-keygen -R "$PRIMARY_IP" >/dev/null 2>&1 || true
    ssh-keygen -R "$PRIMARY_FQDN" >/dev/null 2>&1 || true

    if ! ssh -i "$SYSVOL_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@${PRIMARY_IP}" true >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get install -y sshpass

        unset DEBIAN_FRONTEND

        prompt_secret "Senha root de ${PRIMARY_HOSTNAME}: " PRIMARY_ROOT_PASS

        PUBKEY_B64="$(base64 -w0 <"${SYSVOL_KEY}.pub")"

        SSHPASS="$PRIMARY_ROOT_PASS" sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@${PRIMARY_IP}" "set -e; mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; KEY=\$(printf '%s' '${PUBKEY_B64}' | base64 -d); grep -qxF \"\$KEY\" /root/.ssh/authorized_keys || printf '%s\n' \"\$KEY\" >> /root/.ssh/authorized_keys"

        PRIMARY_ROOT_PASS=""

        apt-get purge -y sshpass >/dev/null 2>&1 || true

    fi

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "root@${PRIMARY_IP}" true

    # ------------------------------------------------------------
    # GARANTIR PRÉ-REQUISITOS NO PRIMARY
    # ------------------------------------------------------------

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" '
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

NEED=0

command -v rsync >/dev/null 2>&1 || NEED=1
command -v tdbbackup >/dev/null 2>&1 || NEED=1
command -v flock >/dev/null 2>&1 || NEED=1

if [[ "$NEED" == "1" ]]; then
    apt-get update
    apt-get install -y rsync tdb-tools util-linux
fi

unset DEBIAN_FRONTEND

command -v rsync >/dev/null
command -v tdbbackup >/dev/null
command -v flock >/dev/null

test -f /var/lib/samba/private/idmap.ldb
test -d /var/lib/samba/sysvol

systemctl is-active --quiet samba-ad-dc
'

    # ------------------------------------------------------------
    # OBTER CREDENCIAL DOMAIN ADMIN
    # ------------------------------------------------------------

    ADPASS="$(ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "cat '${ADMIN_PASSWORD_FILE}'" 2>/dev/null || true)"

    if [[ -z "$ADPASS" ]]; then
        prompt_secret "Senha Administrator do domínio: " ADPASS
    fi

    [[ -n "$ADPASS" ]]

    umask 077

    cat >"$AUTH_FILE" <<EOF
username = Administrator
password = ${ADPASS}
domain = ${NETBIOS}
EOF

    chmod 600 "$AUTH_FILE"

    ETAPA="JOIN_SECONDARY"

    status "5/10" "Ingressando ${HOSTNAME} como DC adicional"

    samba-tool domain join "$DOMAIN" DC -A "$AUTH_FILE" --dns-backend=SAMBA_INTERNAL

fi

# ============================================================
# 5/6. CONFIGURAR SAMBA
# ============================================================

ETAPA="CONFIGURAR_SAMBA"

if [[ "$ROLE" == "PRIMARY" ]]; then
    status "5/10" "Configurando DNS, Kerberos e Samba"
else
    status "6/10" "Configurando DNS, Kerberos e Samba"
fi

PIHOLE1="$PIHOLE1" PIHOLE2="$PIHOLE2" python3 - <<'PY'
import os
from pathlib import Path

path = Path("/etc/samba/smb.conf")

forwarders = f"{os.environ['PIHOLE1']} {os.environ['PIHOLE2']}"

lines = path.read_text().splitlines()

saida = []
global_section = False
gravado = False

for line in lines:
    s = line.strip().lower()

    if s == "[global]":
        global_section = True
        saida.append(line)
        continue

    if global_section and s.startswith("[") and s.endswith("]"):
        if not gravado:
            saida.append(f"\tdns forwarder = {forwarders}")
            gravado = True

        global_section = False

    if global_section and s.startswith("dns forwarder"):
        if not gravado:
            saida.append(f"\tdns forwarder = {forwarders}")
            gravado = True

        continue

    saida.append(line)

if global_section and not gravado:
    saida.append(f"\tdns forwarder = {forwarders}")

path.write_text("\n".join(saida) + "\n")
PY

testparm -s >/dev/null

cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

chmod 644 /etc/krb5.conf

# ============================================================
# SECONDARY - IDMAP + SYSVOL INICIAL
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="SINCRONIZAR_ARQUIVOS"

    status "7/10" "Sincronizando idmap.ldb e SYSVOL"

    REMOTE_IDMAP="${IDMAP}.setecsync"
    LOCAL_IDMAP="/root/idmap.ldb.setecsync"

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "rm -f '${REMOTE_IDMAP}'; tdbbackup -s .setecsync '${IDMAP}'; test -s '${REMOTE_IDMAP}'"

    rsync -a -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${REMOTE_IDMAP}" "$LOCAL_IDMAP"

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "rm -f '${REMOTE_IDMAP}'"

    test -s "$LOCAL_IDMAP"

    install -o root -g root -m 600 "$LOCAL_IDMAP" "$IDMAP"

    rm -f "$LOCAL_IDMAP"

    rsync -aAXH --numeric-ids --delete --delay-updates -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${SYSVOL}/" "${SYSVOL}/"

fi

# ============================================================
# INICIAR SAMBA
# ============================================================

ETAPA="INICIAR_SAMBA"

if [[ "$ROLE" == "PRIMARY" ]]; then
    status "6/10" "Iniciando Samba AD DC"
else
    status "8/10" "Iniciando Samba AD DC"
fi

if [[ "$ROLE" == "PRIMARY" ]]; then

    cat >/etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${PRIMARY_IP}
EOF

else

    cat >/etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${SECONDARY_IP}
nameserver ${PRIMARY_IP}
EOF

fi

chmod 644 /etc/resolv.conf

systemctl unmask samba-ad-dc 2>/dev/null || true

systemctl enable samba-ad-dc >/dev/null

systemctl restart samba-ad-dc

sleep 5

systemctl is-active --quiet samba-ad-dc

samba_dnsupdate >/dev/null 2>&1 || true

# ============================================================
# AUTH FILE NO PRIMARY
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    umask 077

    cat >"$AUTH_FILE" <<EOF
username = Administrator
password = ${ADPASS}
domain = ${NETBIOS}
EOF

    chmod 600 "$AUTH_FILE"

fi

# ============================================================
# DNS REVERSO
# ============================================================

ETAPA="DNS_REVERSO"

DNS_ADMIN_SERVER="$PRIMARY_IP"

if ! samba-tool dns zonelist "$DNS_ADMIN_SERVER" -A "$AUTH_FILE" 2>/dev/null | grep -qi "$REVERSE_ZONE"; then
    samba-tool dns zonecreate "$DNS_ADMIN_SERVER" "$REVERSE_ZONE" -A "$AUTH_FILE"
fi

if ! samba-tool dns query "$DNS_ADMIN_SERVER" "$REVERSE_ZONE" "$PTR_NAME" PTR -A "$AUTH_FILE" 2>/dev/null | grep -qi "$FQDN"; then
    samba-tool dns add "$DNS_ADMIN_SERVER" "$REVERSE_ZONE" "$PTR_NAME" PTR "$FQDN" -A "$AUTH_FILE"
fi

# ============================================================
# PRIMARY - SYSVOL ACL TIMER
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    ETAPA="CONFIGURAR_SYSVOL_PRIMARY"

    status "7/10" "Configurando verificação de SYSVOL"

    cat >/usr/local/sbin/samba-sysvol-acl-check <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

exec 9>/run/lock/samba-sysvol-acl-check.lock
flock -n 9 || exit 0

if ! samba-tool ntacl sysvolcheck >/dev/null 2>&1; then
    samba-tool ntacl sysvolreset >/dev/null
    samba-tool ntacl sysvolcheck >/dev/null
fi
EOF

    chmod 700 /usr/local/sbin/samba-sysvol-acl-check

    cat >/etc/systemd/system/samba-sysvol-acl-check.service <<EOF
[Unit]
Description=Validar ACL Samba SYSVOL
After=samba-ad-dc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-sysvol-acl-check
EOF

    cat >/etc/systemd/system/samba-sysvol-acl-check.timer <<EOF
[Unit]
Description=Validacao periodica ACL Samba SYSVOL

[Timer]
OnBootSec=60
OnUnitActiveSec=${SYSVOL_ACL_CHECK_SECONDS}
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now samba-sysvol-acl-check.timer >/dev/null

    systemctl start samba-sysvol-acl-check.service

fi

# ============================================================
# SECONDARY - SYSVOL + IDMAP CONTÍNUOS
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="CONFIGURAR_SYNCS"

    status "9/10" "Configurando sincronização contínua"

    net cache flush 2>/dev/null || true

    samba-tool ntacl sysvolreset

    samba-tool ntacl sysvolcheck

    # ------------------------------------------------------------
    # SYSVOL
    # ------------------------------------------------------------

    cat >/usr/local/sbin/samba-sysvol-sync <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

exec 9>/run/lock/samba-sysvol-sync.lock
flock -n 9 || exit 0

ssh -i "${SYSVOL_KEY}" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "root@${PRIMARY_IP}" true >/dev/null 2>&1 || exit 0

CHANGES="\$(rsync -aAXH --numeric-ids --delete-delay --delay-updates --itemize-changes --timeout=30 -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${SYSVOL}/" "${SYSVOL}/")"

if [[ -n "\$CHANGES" ]]; then
    samba-tool ntacl sysvolreset >/dev/null
fi

samba-tool ntacl sysvolcheck >/dev/null
EOF

    chmod 700 /usr/local/sbin/samba-sysvol-sync

    cat >/etc/systemd/system/samba-sysvol-sync.service <<EOF
[Unit]
Description=Sincronizar Samba SYSVOL de ${PRIMARY_HOSTNAME}
After=network-online.target samba-ad-dc.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-sysvol-sync
EOF

    cat >/etc/systemd/system/samba-sysvol-sync.timer <<EOF
[Unit]
Description=Sincronizacao Samba SYSVOL

[Timer]
OnBootSec=30
OnUnitActiveSec=${SYSVOL_SYNC_SECONDS}
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # ------------------------------------------------------------
    # IDMAP
    # ------------------------------------------------------------

    cat >/usr/local/sbin/samba-idmap-sync <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

exec 9>/run/lock/samba-idmap-sync.lock
flock -n 9 || exit 0

ssh -i "${SYSVOL_KEY}" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "root@${PRIMARY_IP}" true >/dev/null 2>&1 || exit 0

REMOTE="${IDMAP}.setecsync"
LOCAL="/root/idmap.ldb.setecsync"

ssh -i "${SYSVOL_KEY}" -o BatchMode=yes "root@${PRIMARY_IP}" "rm -f '\${REMOTE}'; tdbbackup -s .setecsync '${IDMAP}'; test -s '\${REMOTE}'"

rsync -a -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:\${REMOTE}" "\${LOCAL}"

ssh -i "${SYSVOL_KEY}" -o BatchMode=yes "root@${PRIMARY_IP}" "rm -f '\${REMOTE}'"

test -s "\${LOCAL}"

SOURCE_HASH="\$(sha256sum "\${LOCAL}" | awk '{print \$1}')"
LOCAL_HASH="\$(sha256sum "${IDMAP}" | awk '{print \$1}')"

if [[ "\$SOURCE_HASH" == "\$LOCAL_HASH" ]]; then
    rm -f "\${LOCAL}"
    exit 0
fi

systemctl stop samba-ad-dc

install -o root -g root -m 600 "\${LOCAL}" "${IDMAP}"

rm -f "\${LOCAL}"

net cache flush 2>/dev/null || true

systemctl start samba-ad-dc

sleep 5

samba-tool ntacl sysvolreset >/dev/null
samba-tool ntacl sysvolcheck >/dev/null
EOF

    chmod 700 /usr/local/sbin/samba-idmap-sync

    cat >/etc/systemd/system/samba-idmap-sync.service <<EOF
[Unit]
Description=Sincronizar Samba idmap.ldb de ${PRIMARY_HOSTNAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-idmap-sync
EOF

    cat >/etc/systemd/system/samba-idmap-sync.timer <<EOF
[Unit]
Description=Sincronizacao Samba idmap.ldb

[Timer]
OnBootSec=600
OnUnitActiveSec=${IDMAP_SYNC_SECONDS}
AccuracySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now samba-sysvol-sync.timer >/dev/null
    systemctl enable --now samba-idmap-sync.timer >/dev/null

    systemctl start samba-sysvol-sync.service

    # Primary passa a conhecer o Secondary como DNS alternativo.
    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "printf '%s\n' 'search ${DOMAIN}' 'nameserver ${PRIMARY_IP}' 'nameserver ${SECONDARY_IP}' > /etc/resolv.conf"

fi

# ============================================================
# AGUARDAR REPLICAÇÃO DNS NATURAL NO SECONDARY
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="AGUARDAR_REPLICACAO_DNS"

    WAITED=0
    DNS_REPLICATION_OK=0

    while (( WAITED < DNS_REPLICATION_WAIT_SECONDS )); do

        AD1_LOCAL="$(dig +time=2 +tries=1 +short @127.0.0.1 A "$PRIMARY_FQDN" | head -1 || true)"
        AD2_LOCAL="$(dig +time=2 +tries=1 +short @127.0.0.1 A "$SECONDARY_FQDN" | head -1 || true)"
        PTR1_LOCAL="$(dig +time=2 +tries=1 +short @127.0.0.1 -x "$PRIMARY_IP" | sed 's/\.$//' | head -1 || true)"
        PTR2_LOCAL="$(dig +time=2 +tries=1 +short @127.0.0.1 -x "$SECONDARY_IP" | sed 's/\.$//' | head -1 || true)"

        LDAP_LOCAL="$(dig +time=2 +tries=1 +short @127.0.0.1 SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" || true)"

        if [[ "$AD1_LOCAL" == "$PRIMARY_IP" &&
              "$AD2_LOCAL" == "$SECONDARY_IP" &&
              "${PTR1_LOCAL,,}" == "${PRIMARY_FQDN,,}" &&
              "${PTR2_LOCAL,,}" == "${SECONDARY_FQDN,,}" ]] &&
           grep -qi "${PRIMARY_FQDN}\.$" <<<"$LDAP_LOCAL" &&
           grep -qi "${SECONDARY_FQDN}\.$" <<<"$LDAP_LOCAL"; then

            DNS_REPLICATION_OK=1
            break

        fi

        sleep 5
        WAITED=$((WAITED + 5))

    done

    [[ "$DNS_REPLICATION_OK" == "1" ]]

fi

# ============================================================
# 10. AUDITORIA REAL PÓS-CONFIGURAÇÃO
# ============================================================

ETAPA="AUDITORIA_FINAL"

status "10/10" "Auditando estado real da infraestrutura"

declare -a CORE_REPORT=()
declare -a PIHOLE_REPORT=()

declare -a CORE_FAILURES=()
declare -a PIHOLE_FAILURES=()

audit_core() {
    local LABEL="$1"
    local EXPECTED="$2"
    local DETECTED="$3"
    local OK="$4"
    local LINE=""

    if [[ "$OK" == "1" ]]; then
        printf -v LINE "%-30s OK   | esperado: %-38s | detectado: %s" "$LABEL" "$EXPECTED" "${DETECTED:-<vazio>}"
    else
        printf -v LINE "%-30s ERRO | esperado: %-38s | detectado: %s" "$LABEL" "$EXPECTED" "${DETECTED:-<vazio>}"
        CORE_FAILURES+=("$LABEL")
    fi

    CORE_REPORT+=("$LINE")
}

audit_pihole() {
    local LABEL="$1"
    local EXPECTED="$2"
    local DETECTED="$3"
    local OK="$4"
    local LINE=""

    if [[ "$OK" == "1" ]]; then
        printf -v LINE "%-30s OK   | esperado: %-38s | detectado: %s" "$LABEL" "$EXPECTED" "${DETECTED:-<vazio>}"
    else
        printf -v LINE "%-30s ERRO | esperado: %-38s | detectado: %s" "$LABEL" "$EXPECTED" "${DETECTED:-<vazio>}"
        PIHOLE_FAILURES+=("$LABEL")
    fi

    PIHOLE_REPORT+=("$LINE")
}

# ============================================================
# IDENTIDADE REAL
# ============================================================

DETECTED_HOSTNAME="$(hostname)"
DETECTED_FQDN="$(hostname -f)"

DETECTED_IP="$(ip -4 -o addr show "$IFACE" | awk '{print $4; exit}')"
DETECTED_GW="$(ip route show default | awk '{print $3; exit}')"

[[ "$DETECTED_HOSTNAME" == "$HOSTNAME" ]] && OK=1 || OK=0
audit_core "HOSTNAME" "$HOSTNAME" "$DETECTED_HOSTNAME" "$OK"

[[ "$DETECTED_FQDN" == "$FQDN" ]] && OK=1 || OK=0
audit_core "FQDN" "$FQDN" "$DETECTED_FQDN" "$OK"

[[ "$DETECTED_IP" == "$CIDR" ]] && OK=1 || OK=0
audit_core "IPv4" "$CIDR" "$DETECTED_IP" "$OK"

[[ "$DETECTED_GW" == "$GW" ]] && OK=1 || OK=0
audit_core "GATEWAY" "$GW" "$DETECTED_GW" "$OK"

# ============================================================
# NTP REAL
# ============================================================

DETECTED_NTP="$(timedatectl timesync-status 2>/dev/null | awk '/Server:/ {print $2; exit}')"

[[ "$DETECTED_NTP" == "$NTP" ]] && OK=1 || OK=0
audit_core "NTP" "$NTP" "$DETECTED_NTP" "$OK"

# ============================================================
# SAMBA REAL
# ============================================================

DETECTED_SAMBA_VERSION="$(samba --version 2>/dev/null | sed 's/^Version //')"
DETECTED_SAMBA_SERVICE="$(systemctl is-active samba-ad-dc 2>/dev/null || true)"
DETECTED_SERVER_ROLE="$(testparm -s --parameter-name='server role' 2>/dev/null | xargs)"
DETECTED_REALM="$(testparm -s --parameter-name='realm' 2>/dev/null | xargs)"
DETECTED_NETBIOS="$(testparm -s --parameter-name='workgroup' 2>/dev/null | xargs)"

[[ -n "$DETECTED_SAMBA_VERSION" ]] && OK=1 || OK=0
audit_core "SAMBA VERSION" "versão detectável" "$DETECTED_SAMBA_VERSION" "$OK"

[[ "$DETECTED_SAMBA_SERVICE" == "active" ]] && OK=1 || OK=0
audit_core "SAMBA AD DC" "active" "$DETECTED_SAMBA_SERVICE" "$OK"

[[ "${DETECTED_SERVER_ROLE,,}" == *"active directory domain controller"* ]] && OK=1 || OK=0
audit_core "SERVER ROLE" "AD Domain Controller" "$DETECTED_SERVER_ROLE" "$OK"

[[ "${DETECTED_REALM^^}" == "${REALM^^}" ]] && OK=1 || OK=0
audit_core "REALM" "$REALM" "$DETECTED_REALM" "$OK"

[[ "${DETECTED_NETBIOS^^}" == "${NETBIOS^^}" ]] && OK=1 || OK=0
audit_core "NETBIOS" "$NETBIOS" "$DETECTED_NETBIOS" "$OK"

# ============================================================
# DOMAIN / FOREST LEVEL REAIS
# ============================================================

LEVEL_INFO="$(samba-tool domain level show 2>/dev/null || true)"

DETECTED_DOMAIN_LEVEL="$(printf "%s\n" "$LEVEL_INFO" | awk -F': ' '/Domain function level/ {print $2; exit}')"
DETECTED_FOREST_LEVEL="$(printf "%s\n" "$LEVEL_INFO" | awk -F': ' '/Forest function level/ {print $2; exit}')"

[[ -n "$DETECTED_DOMAIN_LEVEL" ]] && OK=1 || OK=0
audit_core "DOMAIN LEVEL" "detectável" "$DETECTED_DOMAIN_LEVEL" "$OK"

[[ -n "$DETECTED_FOREST_LEVEL" ]] && OK=1 || OK=0
audit_core "FOREST LEVEL" "detectável" "$DETECTED_FOREST_LEVEL" "$OK"

# ============================================================
# DNS CONFIGURADO NO DC
# ============================================================

DETECTED_NAMESERVERS="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf | paste -sd ' ' -)"

if [[ "$ROLE" == "PRIMARY" ]]; then

    if [[ "$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)" == "$PRIMARY_IP" ]]; then
        OK=1
    else
        OK=0
    fi

    audit_core "DNS DO DC" "$PRIMARY_IP primeiro" "$DETECTED_NAMESERVERS" "$OK"

else

    FIRST_NS="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"

    if [[ "$FIRST_NS" == "$SECONDARY_IP" && " $DETECTED_NAMESERVERS " == *" $PRIMARY_IP "* ]]; then
        OK=1
    else
        OK=0
    fi

    audit_core "DNS DO DC" "${SECONDARY_IP} + ${PRIMARY_IP}" "$DETECTED_NAMESERVERS" "$OK"

fi

# ============================================================
# FORWARDERS REAIS
# ============================================================

DETECTED_FORWARDERS="$(testparm -s --parameter-name='dns forwarder' 2>/dev/null | xargs)"

if [[ " $DETECTED_FORWARDERS " == *" $PIHOLE1 "* &&
      " $DETECTED_FORWARDERS " == *" $PIHOLE2 "* ]]; then
    OK=1
else
    OK=0
fi

audit_core "DNS FORWARDERS" "${PIHOLE1} ${PIHOLE2}" "$DETECTED_FORWARDERS" "$OK"

# ============================================================
# DNS DIRETO NO SAMBA
# ============================================================

DETECTED_AD1_A="$(dig +time=2 +tries=1 +short @127.0.0.1 A "$PRIMARY_FQDN" | grep -E '^[0-9.]+' | head -1 || true)"
DETECTED_AD2_A="$(dig +time=2 +tries=1 +short @127.0.0.1 A "$SECONDARY_FQDN" | grep -E '^[0-9.]+' | head -1 || true)"

[[ "$DETECTED_AD1_A" == "$PRIMARY_IP" ]] && OK=1 || OK=0
audit_core "SAMBA DNS -> AD01" "$PRIMARY_IP" "$DETECTED_AD1_A" "$OK"

SECONDARY_PRESENT=0

if [[ "$DETECTED_AD2_A" == "$SECONDARY_IP" ]]; then
    SECONDARY_PRESENT=1
fi

if [[ "$ROLE" == "SECONDARY" || "$SECONDARY_PRESENT" == "1" ]]; then

    [[ "$DETECTED_AD2_A" == "$SECONDARY_IP" ]] && OK=1 || OK=0
    audit_core "SAMBA DNS -> AD02" "$SECONDARY_IP" "$DETECTED_AD2_A" "$OK"

fi

# ============================================================
# ZONA / PTR DIRETO NO SAMBA
# ============================================================

DETECTED_REVERSE_SOA="$(dig +time=2 +tries=1 +short @127.0.0.1 SOA "$REVERSE_ZONE" | xargs || true)"

[[ -n "$DETECTED_REVERSE_SOA" ]] && OK=1 || OK=0
audit_core "ZONA REVERSA" "$REVERSE_ZONE disponível" "$DETECTED_REVERSE_SOA" "$OK"

DETECTED_AD1_PTR="$(dig +time=2 +tries=1 +short @127.0.0.1 -x "$PRIMARY_IP" | sed 's/\.$//' | head -1 || true)"

[[ "${DETECTED_AD1_PTR,,}" == "${PRIMARY_FQDN,,}" ]] && OK=1 || OK=0
audit_core "SAMBA PTR -> AD01" "$PRIMARY_FQDN" "$DETECTED_AD1_PTR" "$OK"

if [[ "$ROLE" == "SECONDARY" || "$SECONDARY_PRESENT" == "1" ]]; then

    DETECTED_AD2_PTR="$(dig +time=2 +tries=1 +short @127.0.0.1 -x "$SECONDARY_IP" | sed 's/\.$//' | head -1 || true)"

    [[ "${DETECTED_AD2_PTR,,}" == "${SECONDARY_FQDN,,}" ]] && OK=1 || OK=0
    audit_core "SAMBA PTR -> AD02" "$SECONDARY_FQDN" "$DETECTED_AD2_PTR" "$OK"

fi

# ============================================================
# LDAP SRV
# ============================================================

LDAP_RESULT="$(dig +time=2 +tries=1 +short @127.0.0.1 SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" || true)"

LDAP_OK=1

grep -qi "${PRIMARY_FQDN}\.$" <<<"$LDAP_RESULT" || LDAP_OK=0

if [[ "$ROLE" == "SECONDARY" || "$SECONDARY_PRESENT" == "1" ]]; then
    grep -qi "${SECONDARY_FQDN}\.$" <<<"$LDAP_RESULT" || LDAP_OK=0
fi

LDAP_DETECTED="$(printf "%s\n" "$LDAP_RESULT" | awk '{print $NF}' | sed 's/\.$//' | sort -u | tr '\n' ' ' | xargs)"

audit_core "LDAP SRV" "DCs registrados" "$LDAP_DETECTED" "$LDAP_OK"

# ============================================================
# KERBEROS SRV
# ============================================================

KERBEROS_RESULT="$(dig +time=2 +tries=1 +short @127.0.0.1 SRV "_kerberos._tcp.${DOMAIN}" || true)"

KERBEROS_OK=1

grep -qi "${PRIMARY_FQDN}\.$" <<<"$KERBEROS_RESULT" || KERBEROS_OK=0

if [[ "$ROLE" == "SECONDARY" || "$SECONDARY_PRESENT" == "1" ]]; then
    grep -qi "${SECONDARY_FQDN}\.$" <<<"$KERBEROS_RESULT" || KERBEROS_OK=0
fi

KERBEROS_DETECTED="$(printf "%s\n" "$KERBEROS_RESULT" | awk '{print $NF}' | sed 's/\.$//' | sort -u | tr '\n' ' ' | xargs)"

audit_core "KERBEROS SRV" "DCs registrados" "$KERBEROS_DETECTED" "$KERBEROS_OK"

# ============================================================
# DNS EXTERNO VIA SAMBA -> PI-HOLE
# ============================================================

DNS_EXTERNAL_RESULT="$(dig +time=3 +tries=1 +short @127.0.0.1 A debian.org | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

[[ -n "$DNS_EXTERNAL_RESULT" ]] && OK=1 || OK=0

audit_core "DNS EXTERNO VIA SAMBA" "IPv4 válido" "${DNS_EXTERNAL_RESULT:-sem resposta}" "$OK"

# ============================================================
# KERBEROS AUTH REAL
# ============================================================

KRB5CCNAME="/tmp/krb5cc_samba_ad_audit"

rm -f "$KRB5CCNAME"

if printf "%s\n" "$ADPASS" | KRB5CCNAME="$KRB5CCNAME" kinit Administrator >/dev/null 2>&1 &&
   KRB5CCNAME="$KRB5CCNAME" klist -s; then

    OK=1
    DETECTED="ticket obtido"

else

    OK=0
    DETECTED="falha ao obter ticket"

fi

KRB5CCNAME="$KRB5CCNAME" kdestroy >/dev/null 2>&1 || true
rm -f "$KRB5CCNAME"

audit_core "KERBEROS AUTH" "ticket válido" "$DETECTED" "$OK"

# ============================================================
# DATABASE REAL
# ============================================================

DBOUT="$(samba-tool dbcheck --cross-ncs 2>&1 || true)"
DBSUMMARY="$(printf "%s\n" "$DBOUT" | grep -E 'Checked .* objects' | tail -1)"

grep -Eq 'Checked .* objects \(0 errors\)' <<<"$DBOUT" && OK=1 || OK=0

audit_core "DATABASE" "0 errors" "${DBSUMMARY:-dbcheck sem resumo}" "$OK"

# ============================================================
# SYSVOL ACL REAL
# ============================================================

if samba-tool ntacl sysvolcheck >/dev/null 2>&1; then

    OK=1
    DETECTED="ACL válida"

else

    OK=0
    DETECTED="ACL inválida"

fi

audit_core "SYSVOL ACL" "ACL válida" "$DETECTED" "$OK"

# ============================================================
# FSMO REAL
# ============================================================

FSMO_INFO="$(samba-tool fsmo show 2>/dev/null || true)"

FSMO_TOTAL="$(printf "%s\n" "$FSMO_INFO" | grep -c ':' || true)"
FSMO_PRIMARY="$(printf "%s\n" "$FSMO_INFO" | grep -ic "$PRIMARY_HOSTNAME" || true)"

if [[ "$FSMO_TOTAL" -ge 5 && "$FSMO_PRIMARY" -eq "$FSMO_TOTAL" ]]; then

    OK=1
    DETECTED="${PRIMARY_HOSTNAME} possui ${FSMO_PRIMARY}/${FSMO_TOTAL}"

else

    OK=0
    DETECTED="$(printf "%s\n" "$FSMO_INFO" | tr '\n' ';' | cut -c1-250)"

fi

audit_core "FSMO" "$PRIMARY_HOSTNAME possui todos" "$DETECTED" "$OK"

# ============================================================
# REPLICAÇÃO AD REAL
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    LOCAL_DRS_RC=1
    REMOTE_DRS_RC=1

    if samba-tool drs showrepl --summary >/tmp/drs-local-audit.txt 2>&1; then
        LOCAL_DRS_RC=0
    fi

    if ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "samba-tool drs showrepl --summary" >/tmp/drs-primary-audit.txt 2>&1; then
        REMOTE_DRS_RC=0
    fi

    if [[ "$LOCAL_DRS_RC" == "0" && "$REMOTE_DRS_RC" == "0" ]]; then

        OK=1
        DETECTED="AD01=OK AD02=OK"

    else

        OK=0
        DETECTED="AD01_RC=${REMOTE_DRS_RC} AD02_RC=${LOCAL_DRS_RC}"

    fi

    audit_core "REPLICACAO AD" "AD01=OK AD02=OK" "$DETECTED" "$OK"

fi

# ============================================================
# SYSVOL SYNC REAL
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    ACL_TIMER="$(systemctl is-active samba-sysvol-acl-check.timer 2>/dev/null || true)"

    [[ "$ACL_TIMER" == "active" ]] && OK=1 || OK=0

    audit_core "SYSVOL ACL TIMER" "active" "$ACL_TIMER" "$OK"

else

    SYSVOL_TIMER="$(systemctl is-active samba-sysvol-sync.timer 2>/dev/null || true)"

    SYSVOL_RUN_RC=1

    if systemctl start samba-sysvol-sync.service >/dev/null 2>&1; then
        SYSVOL_RUN_RC=0
    fi

    SYSVOL_DIFF="$(rsync -nrc --delete -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${SYSVOL}/" "${SYSVOL}/" 2>/dev/null || true)"

    SYSVOL_INTERVAL="$(systemctl cat samba-sysvol-sync.timer 2>/dev/null | sed -n 's/^OnUnitActiveSec=//p' | tail -1)"

    if [[ "$SYSVOL_TIMER" == "active" &&
          "$SYSVOL_RUN_RC" == "0" &&
          -z "$SYSVOL_DIFF" ]]; then

        OK=1
        DETECTED="timer=active sync=OK diff=0 intervalo=${SYSVOL_INTERVAL}"

    else

        OK=0
        DETECTED="timer=${SYSVOL_TIMER} sync_rc=${SYSVOL_RUN_RC} diff=$([[ -z "$SYSVOL_DIFF" ]] && echo 0 || echo 1)"

    fi

    audit_core "SYSVOL SYNC" "timer ativo / diff=0" "$DETECTED" "$OK"

fi

# ============================================================
# IDMAP SYNC REAL
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    IDMAP_TIMER="$(systemctl is-active samba-idmap-sync.timer 2>/dev/null || true)"

    LOCAL_ADMIN_GID="$(wbinfo --sid-to-gid S-1-5-32-544 2>/dev/null || true)"

    PRIMARY_ADMIN_GID="$(ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "wbinfo --sid-to-gid S-1-5-32-544" 2>/dev/null || true)"

    IDMAP_INTERVAL="$(systemctl cat samba-idmap-sync.timer 2>/dev/null | sed -n 's/^OnUnitActiveSec=//p' | tail -1)"

    if [[ "$IDMAP_TIMER" == "active" &&
          -n "$LOCAL_ADMIN_GID" &&
          "$LOCAL_ADMIN_GID" == "$PRIMARY_ADMIN_GID" ]]; then

        OK=1
        DETECTED="GID=${LOCAL_ADMIN_GID} timer=active intervalo=${IDMAP_INTERVAL}"

    else

        OK=0
        DETECTED="AD01_GID=${PRIMARY_ADMIN_GID:-?} AD02_GID=${LOCAL_ADMIN_GID:-?} timer=${IDMAP_TIMER}"

    fi

    audit_core "IDMAP SYNC" "mesmo GID / timer ativo" "$DETECTED" "$OK"

fi

# ============================================================
# BASE DE COMPARAÇÃO PARA TESTES DOS PI-HOLE
#
# COMPARAMOS A RESPOSTA DO PI-HOLE COM A RESPOSTA DIRETA
# DO SAMBA, NÃO APENAS COM VARIÁVEIS DE ENTRADA.
# ============================================================

DIRECT_SOA="$(dig +time=2 +tries=1 +short @127.0.0.1 SOA "$DOMAIN" | xargs || true)"

DIRECT_LDAP_NORMALIZED="$(
    dig +time=2 +tries=1 +short @127.0.0.1 SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" |
    awk '{print $4}' |
    sed 's/\.$//' |
    tr '[:upper:]' '[:lower:]' |
    sort -u |
    tr '\n' ' ' |
    xargs
)"

# ============================================================
# TESTE REAL:
# DC -> PI-HOLE -> AD
# DC -> PI-HOLE -> INTERNET
# ============================================================

for DNS_SERVER in "$PIHOLE1" "$PIHOLE2"; do

    DNS_LABEL="PIHOLE ${DNS_SERVER}"

    # --------------------------------------------------------
    # SOA DA ZONA AD
    # --------------------------------------------------------

    PI_SOA="$(dig +time=3 +tries=1 +short @"$DNS_SERVER" SOA "$DOMAIN" | xargs || true)"

    if [[ -n "$DIRECT_SOA" && "$PI_SOA" == "$DIRECT_SOA" ]]; then
        OK=1
    else
        OK=0
    fi

    audit_pihole "${DNS_LABEL} -> SOA" "$DIRECT_SOA" "${PI_SOA:-sem resposta}" "$OK"

    # --------------------------------------------------------
    # AD01 A
    # --------------------------------------------------------

    PI_AD1="$(dig +time=3 +tries=1 +short @"$DNS_SERVER" A "$PRIMARY_FQDN" | grep -E '^[0-9.]+' | head -1 || true)"

    [[ "$PI_AD1" == "$PRIMARY_IP" ]] && OK=1 || OK=0

    audit_pihole "${DNS_LABEL} -> AD01 A" "$PRIMARY_IP" "${PI_AD1:-sem resposta}" "$OK"

    # --------------------------------------------------------
    # AD02 A
    # --------------------------------------------------------

    if [[ "$ROLE" == "SECONDARY" || "$SECONDARY_PRESENT" == "1" ]]; then

        PI_AD2="$(dig +time=3 +tries=1 +short @"$DNS_SERVER" A "$SECONDARY_FQDN" | grep -E '^[0-9.]+' | head -1 || true)"

        [[ "$PI_AD2" == "$SECONDARY_IP" ]] && OK=1 || OK=0

        audit_pihole "${DNS_LABEL} -> AD02 A" "$SECONDARY_IP" "${PI_AD2:-sem resposta}" "$OK"

    fi

    # --------------------------------------------------------
    # LDAP SRV
    # --------------------------------------------------------

    PI_LDAP_NORMALIZED="$(
        dig +time=3 +tries=1 +short @"$DNS_SERVER" SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" |
        awk '{print $4}' |
        sed 's/\.$//' |
        tr '[:upper:]' '[:lower:]' |
        sort -u |
        tr '\n' ' ' |
        xargs
    )"

    if [[ -n "$DIRECT_LDAP_NORMALIZED" &&
          "$PI_LDAP_NORMALIZED" == "$DIRECT_LDAP_NORMALIZED" ]]; then
        OK=1
    else
        OK=0
    fi

    audit_pihole "${DNS_LABEL} -> LDAP SRV" "$DIRECT_LDAP_NORMALIZED" "${PI_LDAP_NORMALIZED:-sem resposta}" "$OK"

    # --------------------------------------------------------
    # PTR AD01
    # --------------------------------------------------------

    PI_PTR1="$(dig +time=3 +tries=1 +short @"$DNS_SERVER" -x "$PRIMARY_IP" | sed 's/\.$//' | head -1 || true)"

    [[ "${PI_PTR1,,}" == "${PRIMARY_FQDN,,}" ]] && OK=1 || OK=0

    audit_pihole "${DNS_LABEL} -> PTR AD01" "$PRIMARY_FQDN" "${PI_PTR1:-sem resposta}" "$OK"

    # --------------------------------------------------------
    # PTR AD02
    # --------------------------------------------------------

    if [[ "$ROLE" == "SECONDARY" || "$SECONDARY_PRESENT" == "1" ]]; then

        PI_PTR2="$(dig +time=3 +tries=1 +short @"$DNS_SERVER" -x "$SECONDARY_IP" | sed 's/\.$//' | head -1 || true)"

        [[ "${PI_PTR2,,}" == "${SECONDARY_FQDN,,}" ]] && OK=1 || OK=0

        audit_pihole "${DNS_LABEL} -> PTR AD02" "$SECONDARY_FQDN" "${PI_PTR2:-sem resposta}" "$OK"

    fi

    # --------------------------------------------------------
    # INTERNET
    # --------------------------------------------------------

    PI_INTERNET="$(dig +time=3 +tries=1 +short @"$DNS_SERVER" A debian.org | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

    [[ -n "$PI_INTERNET" ]] && OK=1 || OK=0

    audit_pihole "${DNS_LABEL} -> INTERNET" "IPv4 válido" "${PI_INTERNET:-sem resposta}" "$OK"

done

# ============================================================
# RESULTADO GLOBAL
# ============================================================

if (( ${#CORE_FAILURES[@]} == 0 )); then
    CORE_STATUS="OK"
else
    CORE_STATUS="ERRO"
fi

if (( ${#PIHOLE_FAILURES[@]} == 0 )); then
    PIHOLE_STATUS="OK"
else
    PIHOLE_STATUS="ERRO"
fi

FINAL_STATUS="OK"

if [[ "$CORE_STATUS" == "ERRO" ]]; then
    FINAL_STATUS="ERRO"
elif [[ "$PIHOLE_STATUS" == "ERRO" && "$REQUIRE_PIHOLE_AUDIT" == "yes" ]]; then
    FINAL_STATUS="ERRO"
elif [[ "$PIHOLE_STATUS" == "ERRO" ]]; then
    FINAL_STATUS="OK - PIHOLE PENDENTE/ERRO"
fi

cleanup_secrets

trap - ERR

# ============================================================
# RELATÓRIO
# ============================================================

{
    echo "================================================================================================================"
    echo " ${HOSTNAME} - AUDITORIA PÓS-CONFIGURAÇÃO"
    echo "================================================================================================================"
    echo
    echo "STATUS FINAL......... ${FINAL_STATUS}"
    echo "SAMBA / AD........... ${CORE_STATUS}"
    echo "PI-HOLE.............. ${PIHOLE_STATUS}"
    echo
    echo "TESTES SAMBA / AD:"
    echo

    printf "%s\n" "${CORE_REPORT[@]}"

    echo
    echo "----------------------------------------------------------------------------------------------------------------"
    echo "TESTES PI-HOLE -> AD / INTERNET:"
    echo

    printf "%s\n" "${PIHOLE_REPORT[@]}"

    echo
    echo "----------------------------------------------------------------------------------------------------------------"

    if (( ${#CORE_FAILURES[@]} == 0 )); then
        echo "FALHAS SAMBA/AD...... nenhuma"
    else
        echo "FALHAS SAMBA/AD...... ${CORE_FAILURES[*]}"
    fi

    if (( ${#PIHOLE_FAILURES[@]} == 0 )); then
        echo "FALHAS PI-HOLE....... nenhuma"
    else
        echo "FALHAS PI-HOLE....... ${PIHOLE_FAILURES[*]}"
    fi

    echo
    echo "LOG.................. ${LOG}"

    if [[ "$ROLE" == "PRIMARY" ]]; then
        echo "SENHA ADMIN.......... ${ADMIN_PASSWORD_FILE}"
    fi

    echo "================================================================================================================"

} >"$RESULT"

exec 1>&3 2>&4

clear 2>/dev/null || true

cat "$RESULT"

if [[ "$FINAL_STATUS" == "ERRO" ]]; then
    exit 1
fi

exit 0
