#!/bin/bash

GREEN='\u001B[0;32m'
RED='\u001B[0;31m'
NC='\u001B[0m'

echo -e "${GREEN}📦 Verfügbare Partitionen:${NC}"
PARTITIONS=($(lsblk -lnp -o NAME | grep -E '/dev/sd|/dev/nvme|/dev/vd'))
echo ""
printf "%-3s %-20s %-10s %-10s %-36s %-20s\n" "Nr" "Gerät" "Größe" "Typ" "UUID" "Label"
echo "-----------------------------------------------------------------------------------------------"

i=1
for PART in "${PARTITIONS[@]}"; do
    UUID=$(blkid -s UUID -o value "$PART")
    if [[ -z "$UUID" ]]; then
        UUID=$(ls -l /dev/disk/by-uuid | grep $(basename "$PART") | awk '{print $9}')
    fi
    FSTYPE=$(blkid -s TYPE -o value "$PART")
    if [[ -z "$FSTYPE" ]]; then
        FSTYPE=$(lsblk -no FSTYPE "$PART")
    fi
    LABEL=$(blkid -s LABEL -o value "$PART")
    SIZE=$(lsblk -bno SIZE "$PART" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
    printf "%-3s %-20s %-10s %-10s %-36s %-20s\n" "$i" "$PART" "$SIZE" "${FSTYPE:-—}" "${UUID:-—}" "${LABEL:-—}"
    i=$((i+1))
done

echo ""
read -p "🔧 Gib die Nummer der Partition ein, die du mounten möchtest: " CHOICE
SELECTED="${PARTITIONS[$((CHOICE-1))]}"

UUID=$(blkid -s UUID -o value "$SELECTED")
FSTYPE=$(blkid -s TYPE -o value "$SELECTED")
if [[ -z "$UUID" || -z "$FSTYPE" ]]; then
    echo -e "${RED}❌ UUID oder Dateisystemtyp konnte nicht ermittelt werden. Bitte überprüfe, ob die Partition formatiert ist.${NC}"
    exit 1
fi

echo ""
read -e -p "📁 Gib den gewünschten Mountpfad ein (z. B. /mnt/BackupSSD): " MOUNTPOINT
if [[ -z "$MOUNTPOINT" || "$MOUNTPOINT" != /* ]]; then
    echo -e "${RED}❌ Ungültiger Pfad. Muss mit '/' beginnen.${NC}"
    exit 1
fi

if mount | grep -q "$MOUNTPOINT"; then
    echo -e "${GREEN}ℹ️ Bereits gemountet unter:${NC} $MOUNTPOINT"
    exit 0
fi

mkdir -p "$MOUNTPOINT"

echo -e "${GREEN}🔍 Teste Mountbarkeit ...${NC}"
mount UUID="$UUID" "$MOUNTPOINT"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ Mount-Test fehlgeschlagen. Kein fstab-Eintrag wird geschrieben.${NC}"
    exit 1
fi
umount "$MOUNTPOINT"

cp /etc/fstab /etc/fstab.backup

if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNTPOINT $FSTYPE defaults,nofail,x-systemd.device-timeout=5 0 2" >> /etc/fstab
    echo -e "${GREEN}✅ Eintrag in /etc/fstab hinzugefügt:${NC} $MOUNTPOINT"
else
    echo -e "${GREEN}ℹ️ UUID bereits in /etc/fstab vorhanden.${NC}"
fi

systemctl daemon-reexec
mount -a
if mount | grep -q "$MOUNTPOINT"; then
    echo -e "${GREEN}✅ Mount erfolgreich:${NC} $MOUNTPOINT"
else
    echo -e "${RED}❌ Mount fehlgeschlagen. Prüfe /etc/fstab Eintrag und führe ggf. 'cat /etc/fstab' aus.${NC}"
    exit 1
fi

# Samba-Freigabe anbieten
echo ""
read -p "📡 Möchtest du eine Samba-Freigabe für $MOUNTPOINT erstellen? (j/n): " SAMBA
if [[ "$SAMBA" == "j" || "$SAMBA" == "J" ]]; then
    SHARE_NAME=$(basename "$MOUNTPOINT")
    echo -e "\n[$SHARE_NAME]
   path = $MOUNTPOINT
   browseable = yes
   read only = no
   guest ok = yes
   force user = root" >> /etc/samba/smb.conf

    systemctl restart smbd
    echo -e "${GREEN}✅ Samba-Freigabe [$SHARE_NAME] erstellt und smbd neu gestartet.${NC}"
fi

# Proxmox storage.cfg aktualisieren
echo ""
read -p "🧩 Soll dieser Mount auch in Proxmox storage.cfg eingetragen werden? (j/n): " STORAGE
if [[ "$STORAGE" == "j" || "$STORAGE" == "J" ]]; then
    STORAGE_NAME=$(basename "$MOUNTPOINT")
    if grep -q "$MOUNTPOINT" /etc/pve/storage.cfg; then
        echo -e "${GREEN}ℹ️ Mountpoint bereits in storage.cfg vorhanden.${NC}"
    else
        echo -e "\ndir: $STORAGE_NAME
    path $MOUNTPOINT
    content iso,backup,vztmpl
    maxfiles 3
    is_mountpoint 1" >> /etc/pve/storage.cfg
        echo -e "${GREEN}✅ Eintrag in storage.cfg hinzugefügt als 'dir: $STORAGE_NAME'${NC}"
    fi
fi

