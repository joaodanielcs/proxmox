#!/bin/bash

# Mensagens de status
msg_info() { echo -e "\033[33m[INFO]\033[0m $1"; }
msg_ok()   { echo -e "\033[32m[OK]\033[0m $1"; }
msg_error(){ echo -e "\033[31m[ERROR]\033[0m $1"; }
# Verificar se a CPU é Intel
cpu_vendor=$(lscpu | grep -oP 'Vendor ID:\s*\K\S+')
if [[ "$cpu_vendor" != "GenuineIntel" ]]; then
    msg_error "CPU não é Intel. Abortando."
    exit 1
fi
# Instalar iucode-tool (útil para carregamento de microcódigo manual)
msg_info "Instalando dependência: iucode-tool..."
apt-get update -qq
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
msg_info "Atualização concluída. É recomendável reiniciar o sistema."
