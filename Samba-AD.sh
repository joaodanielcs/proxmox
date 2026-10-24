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

SYSVOL_SYNC_SECONDS="${SYSVOL_SYNC_SECONDS:-60}"
IDMAP_SYNC_SECONDS="${IDMAP_SYNC_SECONDS:-3600}"
SYSVOL_ACL_CHECK_SECONDS="${SYSVOL_ACL_CHECK_SECONDS:-300}"

UPDATE_SYSTEM="${UPDATE_SYSTEM:-yes}"


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

SAMDB="/var/lib/samba/private/sam.ldb"
IDMAP="/var/lib/samba/private/idmap.ldb"
SYSVOL="/var/lib/samba/sysvol"

SYSVOL_KEY="/root/.ssh/id_ed25519_sysvol"

DOMAIN_DN="$(python3 -c 'import sys; print(",".join("DC="+x for x in sys.argv[1].split(".")))' "$DOMAIN")"
CONFIG_DN="CN=Configuration,${DOMAIN_DN}"
SCHEMA_DN="CN=Schema,${CONFIG_DN}"
DOMAIN_DNS_DN="DC=DomainDnsZones,${DOMAIN_DN}"
FOREST_DNS_DN="DC=ForestDnsZones,${DOMAIN_DN}"

ETAPA="INICIO"
ERRO=""

ADPASS=""

exec 3>&1 4>&2

: >"$LOG"

exec >"$LOG" 2>&1


# ============================================================
# FUNÇÕES
# ============================================================

falha() {
    RC=$?

    trap - ERR

    ADPASS=""

    exec 1>&3 2>&4

    clear

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
# VALIDAR VM LIMPA
# ============================================================

ETAPA="VALIDAR_VM_LIMPA"

[[ "$(hostname)" == "$HOSTNAME" ]]
[[ "$(hostname -f)" == "$FQDN" ]]

ip -4 -o addr show eth0 | grep -q "${CIDR}"
ip route | grep -q "^default via ${GW}"

if [[ -e "$SAMDB" ]]; then
    echo "ERRO: ${SAMDB} já existe."
    echo "Use uma VM limpa."
    false
fi


# ============================================================
# /etc/hosts
# ============================================================

ETAPA="CONFIGURAR_HOSTS"

cat >/etc/hosts <<EOF
127.0.0.1 localhost
${IP} ${FQDN} ${HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF


# ============================================================
# NTP
# ============================================================

ETAPA="CONFIGURAR_NTP"

mkdir -p /etc/systemd/timesyncd.conf.d

cat >/etc/systemd/timesyncd.conf.d/10-setec.conf <<EOF
[Time]
NTP=${NTP}
FallbackNTP=
EOF

timedatectl set-timezone America/Sao_Paulo

systemctl restart systemd-timesyncd

NTP_OK=0

for _ in $(seq 1 30); do
    if timedatectl timesync-status 2>/dev/null | grep -q "$NTP"; then
        NTP_OK=1
        break
    fi

    sleep 2
done

[[ "$NTP_OK" == "1" ]]


# ============================================================
# REDE
# ============================================================

ETAPA="VALIDAR_REDE"

ping -c1 -W2 "$GW" >/dev/null
ping -c1 -W2 "$PIHOLE1" >/dev/null
ping -c1 -W2 "$PIHOLE2" >/dev/null

getent ahostsv4 deb.debian.org >/dev/null


# ============================================================
# PACOTES
# ============================================================

ETAPA="INSTALAR_PACOTES"

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

command -v samba-tool >/dev/null
command -v samba >/dev/null
command -v smbclient >/dev/null
command -v wbinfo >/dev/null
command -v rsync >/dev/null
command -v tdbbackup >/dev/null
command -v host >/dev/null
command -v flock >/dev/null


# ============================================================
# SERVIÇOS
# ============================================================

ETAPA="PREPARAR_SERVICOS"

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
# PRIMARY
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    ETAPA="GERAR_CREDENCIAL_AD"

    umask 077

    ADPASS="Adm_$(openssl rand -hex 18)_Z9a"

    printf '%s\n' "$ADPASS" >"$ADMIN_PASSWORD_FILE"

    chmod 600 "$ADMIN_PASSWORD_FILE"


    ETAPA="PROVISIONAR_DOMINIO"

    samba-tool domain provision --server-role=dc --realm="$REALM" --domain="$NETBIOS" --dns-backend=SAMBA_INTERNAL --host-ip="$IP" --use-rfc2307 --adminpass="$ADPASS"

fi


# ============================================================
# SECONDARY - SSH PARA PRIMARY
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="PREPARAR_SSH_PRIMARY"

    mkdir -p /root/.ssh

    chmod 700 /root/.ssh

    ssh-keygen -R "$PRIMARY_IP" >/dev/null 2>&1 || true
    ssh-keygen -R "$PRIMARY_FQDN" >/dev/null 2>&1 || true

    if [[ ! -f "$SYSVOL_KEY" ]]; then
        ssh-keygen -q -t ed25519 -N "" -f "$SYSVOL_KEY" -C "${HOSTNAME}-sysvol"
    fi

    if ! ssh -i "$SYSVOL_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@${PRIMARY_IP}" true >/dev/null 2>&1; then

        exec 1>&3 2>&4

        echo
        echo "Informe a senha ROOT de ${PRIMARY_HOSTNAME} quando solicitado:"
        echo

        ssh-copy-id -i "${SYSVOL_KEY}.pub" -o StrictHostKeyChecking=accept-new "root@${PRIMARY_IP}"

        exec >"$LOG" 2>&1

    fi

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "root@${PRIMARY_IP}" true


    # ============================================================
    # GARANTIR DEPENDÊNCIAS NO PRIMARY
    # ============================================================

    ETAPA="PREPARAR_PRIMARY"

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


    # ============================================================
    # CREDENCIAL DOMAIN ADMIN
    # ============================================================

    ETAPA="OBTER_CREDENCIAL_AD"

    ADPASS="$(ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "cat '${ADMIN_PASSWORD_FILE}'")"

    [[ -n "$ADPASS" ]]


    # ============================================================
    # JOIN
    # ============================================================

    ETAPA="JOIN_DOMINIO"

    samba-tool domain join "$DOMAIN" DC -U "Administrator%${ADPASS}" --dns-backend=SAMBA_INTERNAL

fi


# ============================================================
# DNS FORWARDERS
# ============================================================

ETAPA="CONFIGURAR_FORWARDERS"

PIHOLE1="$PIHOLE1" PIHOLE2="$PIHOLE2" python3 - <<'PY'
import os
from pathlib import Path

path = Path("/etc/samba/smb.conf")

forwarders = f"{os.environ['PIHOLE1']} {os.environ['PIHOLE2']}"

lines = path.read_text().splitlines()

result = []
inside = False
written = False

for line in lines:
    s = line.strip().lower()

    if s == "[global]":
        inside = True
        result.append(line)
        continue

    if inside and s.startswith("[") and s.endswith("]"):
        if not written:
            result.append(f"\tdns forwarder = {forwarders}")
            written = True

        inside = False

    if inside and s.startswith("dns forwarder"):
        if not written:
            result.append(f"\tdns forwarder = {forwarders}")
            written = True

        continue

    result.append(line)

if inside and not written:
    result.append(f"\tdns forwarder = {forwarders}")

path.write_text("\n".join(result) + "\n")
PY

testparm -s >/dev/null


# ============================================================
# KERBEROS
# ============================================================

ETAPA="CONFIGURAR_KERBEROS"

cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

chmod 644 /etc/krb5.conf


# ============================================================
# SECONDARY - IDMAP E SYSVOL ANTES DE SUBIR O SERVIÇO
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="SYNC_IDMAP_INICIAL"

    REMOTE_IDMAP="${IDMAP}.setecsync"
    LOCAL_IDMAP="/root/idmap.ldb.setecsync"

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "rm -f '${REMOTE_IDMAP}'; tdbbackup -s .setecsync '${IDMAP}'; test -s '${REMOTE_IDMAP}'"

    rsync -a -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${REMOTE_IDMAP}" "$LOCAL_IDMAP"

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "rm -f '${REMOTE_IDMAP}'"

    test -s "$LOCAL_IDMAP"

    install -o root -g root -m 600 "$LOCAL_IDMAP" "$IDMAP"

    rm -f "$LOCAL_IDMAP"


    ETAPA="SYNC_SYSVOL_INICIAL"

    rsync -aAXH --numeric-ids --delete --delay-updates -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${SYSVOL}/" "${SYSVOL}/"

fi


# ============================================================
# DNS LOCAL DO DC
# ============================================================

ETAPA="DNS_LOCAL_DC"

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


# ============================================================
# INICIAR SAMBA
# ============================================================

ETAPA="INICIAR_SAMBA"

systemctl unmask samba-ad-dc 2>/dev/null || true

systemctl enable samba-ad-dc >/dev/null

systemctl restart samba-ad-dc

sleep 5

systemctl is-active --quiet samba-ad-dc


# ============================================================
# SECONDARY - DRS EXPLÍCITO
#
# NÃO EXECUTA samba-tool drs kcc
# ============================================================

DRS_STATUS="N/A"

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="SINCRONIZAR_DRS"

    NCS=(
        "$DOMAIN_DN"
        "$CONFIG_DN"
        "$SCHEMA_DN"
        "$DOMAIN_DNS_DN"
        "$FOREST_DNS_DN"
    )

    for NC in "${NCS[@]}"; do
        samba-tool drs replicate "$SECONDARY_FQDN" "$PRIMARY_FQDN" "$NC" -U "Administrator%${ADPASS}"
    done

    for NC in "${NCS[@]}"; do
        samba-tool drs replicate "$PRIMARY_FQDN" "$SECONDARY_FQDN" "$NC" -U "Administrator%${ADPASS}"
    done

    DRS_STATUS="OK"

fi


# ============================================================
# ZONA REVERSA
# ============================================================

ETAPA="DNS_REVERSO"

if [[ "$ROLE" == "PRIMARY" ]]; then

    if ! samba-tool dns zonelist 127.0.0.1 -U "Administrator%${ADPASS}" 2>/dev/null | grep -qi "$REVERSE_ZONE"; then
        samba-tool dns zonecreate 127.0.0.1 "$REVERSE_ZONE" -U "Administrator%${ADPASS}"
    fi

else

    REVERSE_OK=0

    for _ in $(seq 1 30); do

        if samba-tool dns zonelist 127.0.0.1 -U "Administrator%${ADPASS}" 2>/dev/null | grep -qi "$REVERSE_ZONE"; then
            REVERSE_OK=1
            break
        fi

        sleep 2

    done

    [[ "$REVERSE_OK" == "1" ]]

fi

if ! samba-tool dns query 127.0.0.1 "$REVERSE_ZONE" "$PTR_NAME" PTR -U "Administrator%${ADPASS}" 2>/dev/null | grep -qi "$FQDN"; then
    samba-tool dns add 127.0.0.1 "$REVERSE_ZONE" "$PTR_NAME" PTR "$FQDN" -U "Administrator%${ADPASS}"
fi


# ============================================================
# PRIMARY - ACL SYSVOL
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    ETAPA="CONFIGURAR_SYSVOL_PRIMARY"

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
# SECONDARY - SYSVOL TIMER
# ============================================================

SYSVOL_STATUS="MASTER"
IDMAP_STATUS="MASTER"

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="FINALIZAR_SYSVOL_INICIAL"

    net cache flush 2>/dev/null || true

    samba-tool ntacl sysvolreset

    samba-tool ntacl sysvolcheck


    ETAPA="CONFIGURAR_SYSVOL_TIMER"

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


    # ============================================================
    # SECONDARY - IDMAP TIMER
    # ============================================================

    ETAPA="CONFIGURAR_IDMAP_TIMER"

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
OnBootSec=300
OnUnitActiveSec=${IDMAP_SYNC_SECONDS}
AccuracySec=30
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now samba-sysvol-sync.timer >/dev/null

    systemctl enable --now samba-idmap-sync.timer >/dev/null

    systemctl start samba-sysvol-sync.service

    SYSVOL_STATUS="OK / ${SYSVOL_SYNC_SECONDS}s"
    IDMAP_STATUS="OK / ${IDMAP_SYNC_SECONDS}s"

fi


# ============================================================
# SECONDARY - ATUALIZAR DNS DO PRIMARY
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="ATUALIZAR_DNS_PRIMARY"

    ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "printf '%s\n' 'search ${DOMAIN}' 'nameserver ${PRIMARY_IP}' 'nameserver ${SECONDARY_IP}' > /etc/resolv.conf"

fi


# ============================================================
# KERBEROS
# ============================================================

ETAPA="VALIDAR_KERBEROS"

KRB5CCNAME="/tmp/krb5cc_setec_test"

rm -f "$KRB5CCNAME"

printf '%s\n' "$ADPASS" | KRB5CCNAME="$KRB5CCNAME" kinit Administrator

KRB5CCNAME="$KRB5CCNAME" klist -s

KRB5CCNAME="$KRB5CCNAME" kdestroy 2>/dev/null || true

rm -f "$KRB5CCNAME"


# ============================================================
# VALIDAÇÕES
# ============================================================

ETAPA="VALIDAR_AD"

systemctl is-active --quiet samba-ad-dc

SAMBA_VERSION="$(samba --version | sed 's/^Version //')"

DOMAIN_INFO="$(samba-tool domain info 127.0.0.1)"

grep -qi "$DOMAIN" <<<"$DOMAIN_INFO"

LEVEL_INFO="$(samba-tool domain level show)"

FSMO_INFO="$(samba-tool fsmo show)"

grep -qi "$PRIMARY_HOSTNAME" <<<"$FSMO_INFO"

DBOUT="$(samba-tool dbcheck --cross-ncs 2>&1)"

grep -Eq 'Checked .* objects \(0 errors\)' <<<"$DBOUT"

samba-tool ntacl sysvolcheck

wbinfo --ping-dc >/dev/null

host -W2 -t A "$FQDN" 127.0.0.1 | grep -q "$IP"

host -W2 -t SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" 127.0.0.1 | grep -qi "$DOMAIN"

host -W2 -t SRV "_kerberos._tcp.${DOMAIN}" 127.0.0.1 | grep -qi "$DOMAIN"

host -W2 -t PTR "$IP" 127.0.0.1 | grep -qi "$FQDN"

host -W3 deb.debian.org 127.0.0.1 | grep -qi "has address"

FORWARDERS="$(testparm -s --parameter-name='dns forwarder' 2>/dev/null)"

[[ "$FORWARDERS" == *"$PIHOLE1"* ]]
[[ "$FORWARDERS" == *"$PIHOLE2"* ]]

timedatectl timesync-status | grep -q "$NTP"


# ============================================================
# VALIDAR REPLICAÇÃO SECONDARY
# ============================================================

if [[ "$ROLE" == "SECONDARY" ]]; then

    ETAPA="VALIDAR_DRS_BIDIRECIONAL"

    NCS=(
        "$DOMAIN_DN"
        "$CONFIG_DN"
        "$SCHEMA_DN"
        "$DOMAIN_DNS_DN"
        "$FOREST_DNS_DN"
    )

    for NC in "${NCS[@]}"; do
        samba-tool drs replicate "$SECONDARY_FQDN" "$PRIMARY_FQDN" "$NC" -U "Administrator%${ADPASS}" >/dev/null
    done

    for NC in "${NCS[@]}"; do
        samba-tool drs replicate "$PRIMARY_FQDN" "$SECONDARY_FQDN" "$NC" -U "Administrator%${ADPASS}" >/dev/null
    done

    host -W2 -t A "$PRIMARY_FQDN" 127.0.0.1 | grep -q "$PRIMARY_IP"

    host -W2 -t A "$SECONDARY_FQDN" 127.0.0.1 | grep -q "$SECONDARY_IP"

    systemctl is-active --quiet samba-sysvol-sync.timer

    systemctl is-active --quiet samba-idmap-sync.timer

    systemctl start samba-sysvol-sync.service

    samba-tool ntacl sysvolcheck

    SYSVOL_DIFF="$(rsync -nrc --delete -e "ssh -i ${SYSVOL_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes" "root@${PRIMARY_IP}:${SYSVOL}/" "${SYSVOL}/")"

    [[ -z "$SYSVOL_DIFF" ]]

    LOCAL_ADMIN_GID="$(wbinfo --sid-to-gid S-1-5-32-544)"

    PRIMARY_ADMIN_GID="$(ssh -i "$SYSVOL_KEY" -o BatchMode=yes "root@${PRIMARY_IP}" "wbinfo --sid-to-gid S-1-5-32-544")"

    [[ "$LOCAL_ADMIN_GID" == "$PRIMARY_ADMIN_GID" ]]

fi


# ============================================================
# PRIMARY
# ============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then

    systemctl is-active --quiet samba-sysvol-acl-check.timer

    DRS_STATUS="AGUARDANDO SECONDARY"

fi


# ============================================================
# RESULTADO
# ============================================================

ETAPA="RESULTADO"

DOMAIN_LEVEL="$(printf '%s\n' "$LEVEL_INFO" | awk -F': ' '/Domain function level/ {print $2; exit}')"

FOREST_LEVEL="$(printf '%s\n' "$LEVEL_INFO" | awk -F': ' '/Forest function level/ {print $2; exit}')"

CHECKED="$(printf '%s\n' "$DBOUT" | grep -Ei 'Checked .* objects' | tail -1)"

ADPASS=""

cat >"$RESULT" <<EOF
============================================================
 ${HOSTNAME} - RESULTADO
============================================================

STATUS............. OK
ROLE............... ${ROLE}

HOSTNAME........... ${HOSTNAME}
FQDN............... ${FQDN}
IP................. ${CIDR}
GATEWAY............ ${GW}
NTP................ ${NTP}

SAMBA.............. ${SAMBA_VERSION}
AD DC.............. ACTIVE

DOMINIO............ ${DOMAIN}
REALM.............. ${REALM}
NETBIOS............ ${NETBIOS}

PRIMARY............ ${PRIMARY_HOSTNAME} / ${PRIMARY_IP}
SECONDARY.......... ${SECONDARY_HOSTNAME} / ${SECONDARY_IP}

DOMAIN LEVEL....... ${DOMAIN_LEVEL:-OK}
FOREST LEVEL....... ${FOREST_LEVEL:-OK}

DNS LOCAL.......... ${IP}
DNS PEER........... ${PEER_IP}
FORWARDER 1........ ${PIHOLE1}
FORWARDER 2........ ${PIHOLE2}

ZONA REVERSA....... ${REVERSE_ZONE}

DNS A.............. OK
PTR................ OK
LDAP SRV........... OK
KERBEROS SRV....... OK
KERBEROS AUTH...... OK
DNS EXTERNO........ OK

DATABASE........... ${CHECKED:-OK}
REPLICACAO AD...... ${DRS_STATUS}

SYSVOL ACL......... OK
SYSVOL SYNC........ ${SYSVOL_STATUS}
IDMAP SYNC......... ${IDMAP_STATUS}

CLIENTES DNS....... ${PIHOLE1} / ${PIHOLE2}
FLUXO.............. CLIENTE -> PIHOLE -> AD/INTERNET

LOG................ ${LOG}
============================================================
EOF

if [[ "$ROLE" == "PRIMARY" ]]; then
    sed -i "/LOG/i SENHA ADMIN........ ${ADMIN_PASSWORD_FILE}" "$RESULT"
fi


# ============================================================
# SAÍDA FINAL
# ============================================================

trap - ERR

exec 1>&3 2>&4

clear

cat "$RESULT"
