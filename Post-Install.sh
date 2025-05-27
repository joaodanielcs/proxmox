#!/bin/bash


# Backup do sources.list.d atual
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak 2>/dev/null

# Comenta o repositório enterprise (se existir)
sed -i 's|^deb https://enterprise.proxmox.com|#deb https://enterprise.proxmox.com|' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null

# Adiciona o repositório sem assinatura (no-subscription)
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Remove repositórios Ceph enterprise se existirem
rm -f /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak 2>/dev/null

# Adiciona repositório livre (no-subscription)
echo "deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription" > /etc/apt/sources.list.d/ceph.list
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" > /etc/apt/sources.list.d/ceph.list
echo "deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription" > /etc/apt/sources.list.d/ceph.list

# Mensagens de status
msg_info()   { echo -e "\033[36mℹ️\033[0m $1"; }
msg_ok()     { echo -e "\033[32m✅\033[0m $1"; }
msg_error()  { echo -e "\033[31m❌\033[0m $1"; }
# Verificar se a CPU é Intel
cpu_vendor=$(lscpu | grep -i 'Vendor ID' | awk '{print $3}')
if ! echo "$cpu_vendor" | grep -qi 'intel'; then
    msg_error "CPU não é Intel. Abortando."
    exit 1
fi
clear
# Instalar iucode-tool (útil para carregamento de microcódigo manual)
msg_info "Instalando dependência: iucode-tool..."
apt-get update -qq &>/dev/null
apt-get install -y iucode-tool &>/dev/null
msg_ok "iucode-tool instalado."
# Buscar e instalar o pacote mais recente do microcódigo Intel
msg_info "Buscando a versão mais recente do microcódigo Intel..."
intel_pkg=$(curl -fsSL "https://ftp.debian.org/debian/pool/non-free-firmware/i/intel-microcode/" | \
    grep -oP 'intel-microcode_[^"]+_amd64.deb' | \
    sort -V | \
    tail -n 1)
if [ -z "$intel_pkg" ]; then
    msg_error "Não foi possível localizar o pacote de microcódigo Intel."
    exit 1
fi
msg_info "Baixando o pacote $intel_pkg..."
wget -q "https://ftp.debian.org/debian/pool/non-free-firmware/i/intel-microcode/$intel_pkg"
msg_info "Instalando o pacote..."
dpkg -i "$intel_pkg" &>/dev/null
msg_ok "Pacote instalado com sucesso."
msg_info "Removendo o arquivo .deb baixado..."
rm -f "$intel_pkg"
msg_ok "Arquivo removido."
msg_info "Reiniciando serviço de microcódigo..."
systemctl restart microcode.service &>/dev/null || true
msg_ok "Serviço reiniciado (se aplicável)."

# Função para corrigir repositórios do Proxmox VE
corrigir_repositorios() {
    msg_info "Corrigindo repositórios do Proxmox VE..."
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
    echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' > /etc/apt/apt.conf.d/no-bookworm-firmware.conf
    msg_ok "Repositórios corrigidos."
}

# Função para desabilitar o repositório 'pve-enterprise'
desabilitar_pve_enterprise() {
    msg_info "Desabilitando repositório 'pve-enterprise'..."
    local FILE="/etc/apt/sources.list.d/pve-enterprise.list"
    if [[ -f "$FILE" ]]; then
        mv "$FILE" "$FILE.bak"
        msg_ok "Repositório 'pve-enterprise' desabilitado."
    else
        msg_info "'pve-enterprise.list' não encontrado. Nenhuma ação necessária."
    fi
}

# Função para corrigir repositórios do Ceph
corrigir_repositorios_ceph() {
    msg_info "Corrigindo repositórios do Ceph..."
    cat >/etc/apt/sources.list.d/ceph.list <<EOF
deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription
EOF
    msg_ok "Repositórios do Ceph corrigidos."
}

# Função para desabilitar o aviso de assinatura
desabilitar_avisos_assinatura() {
    msg_info "Removendo aviso de assinatura da interface web (no nag)..."
    local JS_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

    if [ -f "$JS_FILE" ]; then
        cp "$JS_FILE" "${JS_FILE}.bak"

        sed -i.bak -E "s/(!)?(data\.status\.subscription)/\2/" "$JS_FILE"
        sed -i -E "s/Proxmox VE Subscription/Proxmox VE No-Subscription/" "$JS_FILE"

        msg_ok "Aviso removido com sucesso (limpe o cache do navegador)."
    else
        msg_error "Arquivo JavaScript não encontrado: $JS_FILE"
    fi
}


# Função para atualizar o Proxmox VE
atualizar_proxmox() {
    msg_info "Atualizando Proxmox VE...(Paciência)"
    apt-get update &>/dev/null
    apt-get -y dist-upgrade &>/dev/null
    msg_ok "Proxmox VE atualizado."
}

# Função para reiniciar o sistema
reiniciar_sistema() {
    msg_info "Reiniciando o sistema..."
    history -c
    reboot
}

# Função para ocultar avisos
ocultar_avisos() {
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet mitigations=off"/' /etc/default/grub
    sed -i 's/root=ZFS=rpool\/ROOT\/pve-1 boot=zfs/root=ZFS=rpool\/ROOT\/pve-1 boot=zfs mitigations=off/' /etc/kernel/cmdline
    proxmox-boot-tool refresh > /dev/null 2>&1
}

# Ajustar iDRAC7
iDRAC7() {
    cd ~
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" -O Dell-iDRACTools-Web-LX.tar.gz "https://dl.dell.com/FOLDER09667202M/1/Dell-iDRACTools-Web-LX-11.1.0.0-5294_A00.tar.gz" &>/dev/null
    tar -xvf Dell-iDRACTools-Web-LX.tar.gz &>/dev/null
    cd iDRACTools/racadm/RHEL8/x86_64
    apt install -y alien &>/dev/null
    alien srvadmin-*.rpm &>/dev/null
    dpkg -i *.deb &>/dev/null
    rm -f /usr/local/bin/racadm
    ln -s /opt/dell/srvadmin/bin/idracadm7 /usr/local/bin/racadm &>/dev/null
    cd ~
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" -O Dell-iDRACTools-Web-LX-11.3.0.0-609_A00.tar.gz "https://dl.dell.com/FOLDER12236395M/1/Dell-iDRACTools-Web-LX-11.3.0.0-609_A00.tar.gz" &>/dev/null
    tar -xvf Dell-iDRACTools-Web-LX-11.3.0.0-609_A00.tar.gz &>/dev/null
    cd iDRACTools/racadm/RHEL8/x86_64
    alien srvadmin-*.rpm &>/dev/null
    dpkg -i *.deb &>/dev/null
    rm -f /usr/local/bin/racadm
    ln -s /opt/dell/srvadmin/bin/idracadm7 /usr/local/bin/racadm &>/dev/null
    cd ~
    cd iDRACTools/racadm/UBUNTU22/x86_64
    alien srvadmin-*.rpm &>/dev/null
    dpkg -i *.deb &>/dev/null
    rm -f /usr/local/bin/racadm
    ln -s /opt/dell/srvadmin/bin/idracadm7 /usr/local/bin/racadm &>/dev/null
}

# Execução das funções
corrigir_repositorios
desabilitar_pve_enterprise
corrigir_repositorios_ceph
desabilitar_avisos_assinatura
atualizar_proxmox
ocultar_avisos
#iDRAC7
reiniciar_sistema
