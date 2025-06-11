bash -c "$(wget -qLO - https://raw.githubusercontent.com/joaodanielcs/proxmox/refs/heads/main/Post-Install.sh)"

Dica para o erro de multiplos IPs com o CEPH:Add commentMore actions

pve01: pveceph mon create --mon-address 192.168.0.31
pve02: pveceph mon create --mon-address 192.168.0.32
pve03: pveceph mon create --mon-address 192.168.0.33
