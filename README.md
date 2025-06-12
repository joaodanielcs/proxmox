bash -c "$(wget -qLO - https://raw.githubusercontent.com/joaodanielcs/proxmox/refs/heads/main/Post-Install.sh)"

#1. Criar ou inserir no cluster;

#2. Instalar o CEPH;

    # Info: Version: 19.2     Repository: No-Subscription

    # instalation: y

    # Configuration: Public: 192.168.... Cluster: 172.31.....

    # Monitor: Manager > Create > seleciona o host... Monitor > Create > seleciona o host.... 

    # CephFS: Metadata > Create > seleciona o host...

    # OSD: Create OSD > Disk: Seleciona > Wall Disk: Seleciona o SSD

    # Pools: (se não existir) Create > Name: Tank
  
#3. Shell:   systemctl enable keepalived &>/dev/null && systemctl start keepalived &>/dev/null && history -c

Dica para o erro de multiplos IPs com o CEPH:Add commentMore actions

pve01: pveceph mon create --mon-address 192.168.0.31

pve02: pveceph mon create --mon-address 192.168.0.32

pve03: pveceph mon create --mon-address 192.168.0.33
