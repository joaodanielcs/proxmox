#!/bin/bash

# Mensagens de status
msg_info()   { echo -e "\033[36mℹ️\033[0m $1"; }
msg_ok()     { echo -e "\033[32m✅\033[0m $1"; }
msg_error()  { echo -e "\033[31m❌\033[0m $1"; }

read -s -p "Digite a senha do iDRAC: " IDRAC_PASSWORD

if [ -z "$IDRAC_PASSWORD" ]; then
  msg_error "Erro: variável de ambiente IDRAC_PASSWORD não definida."
  exit 1
fi
# Verificar se a CPU é Intel
cpu_vendor=$(lscpu | grep -i 'Vendor ID' | awk '{print $3}')
if ! echo "$cpu_vendor" | grep -qi 'intel'; then
    msg_error "CPU não é Intel. Abortando."
    exit 1
fi

# Backup do sources.list.d atual
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak 2>/dev/null
# Comenta o repositório enterprise (se existir)
sed -i 's|^deb https://enterprise.proxmox.com|#deb https://enterprise.proxmox.com|' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null
# Adiciona o repositório sem assinatura (no-subscription)
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
# Remove repositórios Ceph enterprise se existirem
rm -f /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak 2>/dev/null
clear
# Instalar iucode-tool (útil para carregamento de microcódigo manual)
msg_info "Instalando dependência: iucode-tool..."
apt-get update -qq &>/dev/null
apt-get install -y iucode-tool &>/dev/null
msg_ok "iucode-tool instalado."
echo " "
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
echo " "
rm -f "$intel_pkg"
msg_info "Reiniciando serviço de microcódigo..."
systemctl restart microcode.service &>/dev/null || true
msg_ok "Serviço reiniciado (se aplicável)."
echo " "
HOSTNAME=$(hostname)
case "$HOSTNAME" in
      pve01) SRV_IP="192.168.0.31"; SRV_NET="192.168.0.31/21"; BOND2_CIDR="172.31.163.1/28"; STATE="MASTER"; PRIORITY="100"; UNICAST_PEER1="192.168.0.32"; UNICAST_PEER2="192.168.0.33" ;;
      pve02) SRV_IP="192.168.0.32"; SRV_NET="192.168.0.32/21"; BOND2_CIDR="172.31.163.2/28"; STATE="BACKUP"; PRIORITY="99"; UNICAST_PEER1="192.168.0.31"; UNICAST_PEER2="192.168.0.33" ;;
      pve03) SRV_IP="192.168.0.33"; SRV_NET="192.168.0.33/21"; BOND2_CIDR="172.31.163.3/28"; STATE="BACKUP"; PRIORITY="98"; UNICAST_PEER1="192.168.0.31"; UNICAST_PEER2="192.168.0.32" ;;
esac

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
    cat > /etc/apt/sources.list.d/ceph.list <<EOF
deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription
EOF
      msg_ok "Repositórios do Ceph corrigidos."
}

# Função para desabilitar o aviso de assinatura
desabilitar_avisos_assinatura() {
    msg_info "Removendo aviso de assinatura da interface web (no nag)..."
    echo "DPkg::Post-Invoke { \"dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ \$? -eq 1 ]; then { echo 'Removendo banner de assinatura do UI...'; sed -i '/data.status/{s/\!//;s/Active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi\"; };" > /etc/apt/apt.conf.d/no-nag-script
    apt --reinstall install proxmox-widget-toolkit &>/dev/null
    msg_ok "Aviso removido com sucesso (limpe o cache do navegador)."
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
    cat /dev/null > ~/.bash_history
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
    msg_info "Instalando iDRAC-Tools"
    cd ~
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" -O Dell-iDRACTools-Web-LX.tar.gz "https://dl.dell.com/FOLDER09667202M/1/Dell-iDRACTools-Web-LX-11.1.0.0-5294_A00.tar.gz" &>/dev/null
    tar -xvf Dell-iDRACTools-Web-LX.tar.gz &>/dev/null
    cd iDRACTools/racadm/RHEL8/x86_64
    apt install -y alien &>/dev/null
    alien srvadmin-*.rpm &>/dev/null
    dpkg -i *.deb &>/dev/null
    rm -f /usr/local/bin/racadm
    ln -s /opt/dell/srvadmin/bin/idracadm7 /usr/local/bin/racadm &>/dev/null
    msg_info "Atualizando iDRAC-Tools..."
    cd ~
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" -O Dell-iDRACTools-Web-LX-11.3.0.0-609_A00.tar.gz "https://dl.dell.com/FOLDER12236395M/1/Dell-iDRACTools-Web-LX-11.3.0.0-609_A00.tar.gz" &>/dev/null
    tar -xvf Dell-iDRACTools-Web-LX-11.3.0.0-609_A00.tar.gz &>/dev/null
    cd iDRACTools/racadm/RHEL8/x86_64
    alien srvadmin-*.rpm &>/dev/null
    dpkg -i *.deb &>/dev/null
    rm -f /usr/local/bin/racadm
    ln -s /opt/dell/srvadmin/bin/idracadm7 /usr/local/bin/racadm &>/dev/null
    msg_info "Habilitando CLI 'racadm'"
    cd ~
    cd iDRACTools/racadm/UBUNTU22/x86_64
    alien srvadmin-*.rpm &>/dev/null
    dpkg -i *.deb &>/dev/null
    rm -f /usr/local/bin/racadm
    ln -s /opt/dell/srvadmin/bin/idracadm7 /usr/local/bin/racadm &>/dev/null
    cd ~
    msg_ok "iDRAC instalada."
    racadm set System.ServerOS.HostName $(hostname -s)
    racadm set System.ServerOS.OSName "Proxmox VE $(pveversion | cut -d'/' -f2)"
    racadm set iDRAC.Users.2.Password $IDRAC_PASSWORD
}

interfaces_bond() {
    msg_info "Criando Interfaces bonding"
    cp /etc/network/interfaces /etc/network/interfaces.bak
  # Criando um novo arquivo de configuração
  cat >/etc/network/interfaces.new <<EOF
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet manual

auto eno2
iface eno2 inet manual

auto eno3
iface eno3 inet manual

auto eno4
iface eno4 inet manual

auto enp68s0f0
iface enp68s0f0 inet manual

auto enp68s0f1
iface enp68s0f1 inet manual

auto bond0

iface bond0 inet manual
        bond-slaves eno1 eno2 eno3 eno4
        bond-miimon 100
        bond-mode 802.3ad
        bond-lacp-rate 1
        comment Balanceamento
#Balanceamento

auto bond2
iface bond2 inet static
        address $BOND2_CIDR
        bond-slaves enp68s0f0 enp68s0f1
        bond-miimon 100
        bond-mode active-backup
        bond-primary enp68s0f0
#Cluster

auto vmbr0
iface vmbr0 inet static
        address $SRV_NET
        gateway 192.168.0.2
        bridge-ports bond0
        bridge-stp off
        bridge-fd 0
EOF
  mv /etc/network/interfaces.new /etc/network/interfaces
  systemctl restart networking
  msg_ok "Configuração de bonding aplicada com sucesso no servidor $HOSTNAME!"
}

install_keepalive() {
  msg_info "Instalando o KeepAlive..."
  apt update  &>/dev/null
  apt --fix-broken install -y  &>/dev/null
  apt install -y keepalived  &>/dev/null
  msg_info "Configurando o KeepAlive..."

  cat  >/etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_1 {
    state $STATE 
    interface vmbr0
    virtual_router_id 55
    priority $PRIORITY
    advert_int 1
    unicast_src_ip $SRV_IP
    unicast_peer {
        $UNICAST_PEER1
        $UNICAST_PEER2
    }
    authentication {
        auth_type PASS
        auth_pass Dr753M0ç
    }
    virtual_ipaddress {
        192.168.0.30/21
    }
}
EOF

  #systemctl enable keepalived &>/dev/null
  #systemctl start keepalived &>/dev/null
  systemctl disable keepalived &>/dev/null
  systemctl stop keepalived &>/dev/null
  msg_ok "KeepAlive instalado com sucesso."
}

montar_NAS() {
  mkdir -p /mnt/nas
  echo "192.168.0.42:/nfs/Backups/PVE-Cluster /mnt/nas nfs defaults,_netdev 0 0" | tee -a /etc/fstab
  systemctl daemon-reload
  mount -a
}
# Execução das funções
corrigir_repositorios
echo " "
desabilitar_pve_enterprise
echo " "
corrigir_repositorios_ceph
echo " "
atualizar_proxmox
echo " "
ocultar_avisos
desabilitar_avisos_assinatura
echo " "
iDRAC7
echo " "
interfaces_bond
echo " "
install_keepalive
echo " "
montar_NAS
reiniciar_sistema
