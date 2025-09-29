#!/bin/bash

GREEN='\e[32m'
RED='\e[31m'
NC='\e[0m'

# Prüfen ob whiptail installiert ist
if ! command -v whiptail &> /dev/null; then
    echo -e "${RED}❌ whiptail ist nicht installiert. Bitte mit 'apt install whiptail' nachinstallieren.${NC}"
    exit 1
fi

# Partitionen sammeln
PARTITIONS=($(lsblk -lnp -o NAME | grep -E '/dev/sd|/dev/nvme|/dev/vd'))
MENU_OPTIONS=()
for PART in "${PARTITIONS[@]}"; do
    UUID=$(blkid -s UUID -o value "$PART")
    FSTYPE=$(blkid -s TYPE -o value "$PART")
    LABEL=$(blkid -s LABEL -o value "$PART")
    SIZE=$(lsblk -bno SIZE "$PART" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
    DESC="${PART} | ${SIZE} | ${FSTYPE:-—} | ${LABEL:-—} | ${UUID:-—}"
    MENU_OPTIONS+=("$PART" "$DESC")
done

# GUI Auswahlmenü
SELECTED=$(whiptail --title "Partition auswählen" --menu "Wähle eine Partition zum Mounten:" 20 78 10 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
if [[ -z "$SELECTED" ]]; then
    echo -e "${RED}❌ Keine Partition ausgewählt. Abbruch.${NC}"
    exit 1
fi

# UUID und FSTYPE erneut ermitteln
UUID=$(blkid -s UUID -o value "$SELECTED")
FSTYPE=$(blkid -s TYPE -o value "$SELECTED")
if [[ -z "$UUID" || -z "$FSTYPE" ]]; then
    whiptail --msgbox "UUID oder Dateisystemtyp konnte nicht ermittelt werden. Bitte prüfen, ob die Partition formatiert ist." 10 60
    exit 1
fi

# Mountpfad abfragen
MOUNTPOINT=$(whiptail --inputbox "Gib den gewünschten Mountpfad ein (z. B. /mnt/BackupSSD):" 10 60 "/mnt/$(basename "$SELECTED")" 3>&1 1>&2 2>&3)
if [[ -z "$MOUNTPOINT" || "$MOUNTPOINT" != /* ]]; then
    whiptail --msgbox "Ungültiger Pfad. Muss mit '/' beginnen." 10 60
    exit 1
fi

# Prüfen ob bereits gemountet
if mount | grep -q "$MOUNTPOINT"; then
    whiptail --msgbox "Bereits gemountet unter: $MOUNTPOINT" 10 60
    exit 0
fi

mkdir -p "$MOUNTPOINT"

# Mount-Test
mount UUID="$UUID" "$MOUNTPOINT" 2>/dev/null
if [[ $? -ne 0 ]]; then
    whiptail --msgbox "Mount-Test fehlgeschlagen. Kein fstab-Eintrag wird geschrieben." 10 60
    exit 1
fi
umount "$MOUNTPOINT"

# fstab sichern und ergänzen
cp /etc/fstab /etc/fstab.backup
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNTPOINT $FSTYPE defaults,nofail,x-systemd.device-timeout=5 0 2" >> /etc/fstab
fi

systemctl daemon-reexec
mount -a

if mount | grep -q "$MOUNTPOINT"; then
    whiptail --msgbox "✅ Mount erfolgreich: $MOUNTPOINT" 10 60
else
    whiptail --msgbox "❌ Mount fehlgeschlagen. Prüfe /etc/fstab." 10 60
    exit 1
fi

# Samba-Freigabe
if whiptail --yesno "Möchtest du eine Samba-Freigabe für $MOUNTPOINT erstellen?" 10 60; then
    SHARE_NAME=$(basename "$MOUNTPOINT")
    echo -e "\n[$SHARE_NAME]
   path = $MOUNTPOINT
   browseable = yes
   read only = no
   guest ok = yes
   force user = root" >> /etc/samba/smb.conf
    systemctl restart smbd
    whiptail --msgbox "✅ Samba-Freigabe [$SHARE_NAME] erstellt." 10 60
fi

# Proxmox storage.cfg
if whiptail --yesno "Soll dieser Mount auch in Proxmox storage.cfg eingetragen werden?" 10 60; then
    STORAGE_NAME=$(basename "$MOUNTPOINT")
    if grep -q "$MOUNTPOINT" /etc/pve/storage.cfg; then
        whiptail --msgbox "Mountpoint bereits in storage.cfg vorhanden." 10 60
    else
        echo -e "\ndir: $STORAGE_NAME
    path $MOUNTPOINT
    content iso,backup,vztmpl
    maxfiles 3
    is_mountpoint 1" >> /etc/pve/storage.cfg
        whiptail --msgbox "✅ Eintrag in storage.cfg hinzugefügt als 'dir: $STORAGE_NAME'" 10 60
    fi
fi
