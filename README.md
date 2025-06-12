bash -c "$(wget -qLO - https://raw.githubusercontent.com/joaodanielcs/proxmox/refs/heads/main/Post-Install.sh)"

#1. Criar ou inserir no cluster;

#2. Instalar e configurar o CEPH;

#3. Shell:   systemctl enable keepalived &>/dev/null && systemctl start keepalived &>/dev/null 

Dica para o erro de multiplos IPs com o CEPH:Add commentMore actions

pve01: pveceph mon create --mon-address 192.168.0.31

pve02: pveceph mon create --mon-address 192.168.0.32

pve03: pveceph mon create --mon-address 192.168.0.33
