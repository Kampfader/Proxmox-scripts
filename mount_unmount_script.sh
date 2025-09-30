#!/bin/bash
# Proxmox Mount- & Samba-Manager
# Funktionen: Partition mounten + Samba/Proxmox hinzufügen, Shares wieder löschen (inkl. Unmount)
# Nutzt whiptail für einfache GUI im Terminal

GREEN='\e[32m'
RED='\e[31m'
NC='\e[0m'

SMB_CONF="/etc/samba/smb.conf"
FSTAB_FILE="/etc/fstab"
STORAGE_CFG="/etc/pve/storage.cfg"

#########################################
# Funktion: Partition mounten & hinzufügen
#########################################
add_mount_share() {
    # Partitionen sammeln (nur mit UUID)
    PARTITIONS=($(lsblk -lnp -o NAME | grep -E '/dev/sd|/dev/nvme|/dev/vd'))
    MENU_OPTIONS=()
    for PART in "${PARTITIONS[@]}"; do
        UUID=$(blkid -s UUID -o value "$PART")
        [[ -z "$UUID" ]] && continue   # nur Partitionen mit UUID

        FSTYPE=$(blkid -s TYPE -o value "$PART")
        LABEL=$(blkid -s LABEL -o value "$PART")
        SIZE=$(lsblk -bno SIZE "$PART" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
        DESC="${PART} | ${SIZE} | ${FSTYPE:-—} | ${LABEL:-—} | ${UUID}"
        MENU_OPTIONS+=("$PART" "$DESC")
    done

    if [ ${#MENU_OPTIONS[@]} -eq 0 ]; then
        whiptail --msgbox "Keine Partitionen mit UUID gefunden." 10 60
        return
    fi

    # Auswahlmenü
    SELECTED=$(whiptail --title "Partition auswählen" --menu "Wähle eine Partition zum Mounten:" 20 78 10 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
    [ -z "$SELECTED" ] && return

    # UUID & Typ
    UUID=$(blkid -s UUID -o value "$SELECTED")
    FSTYPE=$(blkid -s TYPE -o value "$SELECTED")

    # Mountpfad abfragen
    MOUNTPOINT=$(whiptail --inputbox "Gib den gewünschten Mountpfad ein (z. B. /mnt/BackupSSD):" 10 60 "/mnt/$(basename "$SELECTED")" 3>&1 1>&2 2>&3)
    [[ -z "$MOUNTPOINT" || "$MOUNTPOINT" != /* ]] && return

    # Mount testen
    mkdir -p "$MOUNTPOINT"
    mount UUID="$UUID" "$MOUNTPOINT" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        whiptail --msgbox "Mount-Test fehlgeschlagen." 10 60
        return
    fi
    umount "$MOUNTPOINT"

    # fstab ergänzen
    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%F_%T)"
    if ! grep -q "$UUID" "$FSTAB_FILE"; then
        echo "UUID=$UUID $MOUNTPOINT $FSTYPE defaults,nofail,x-systemd.device-timeout=5 0 2" >> "$FSTAB_FILE"
    fi

    systemctl daemon-reexec
    mount -a

    if mount | grep -q "$MOUNTPOINT"; then
        whiptail --msgbox "✅ Mount erfolgreich: $MOUNTPOINT" 10 60
    else
        whiptail --msgbox "❌ Mount fehlgeschlagen. Prüfe /etc/fstab." 10 60
        return
    fi

    # Samba-Freigabe optional
    if whiptail --yesno "Möchtest du eine Samba-Freigabe für $MOUNTPOINT erstellen?" 10 60; then
        SHARE_NAME=$(basename "$MOUNTPOINT")
        cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%F_%T)"
        echo -e "\n[$SHARE_NAME]
   path = $MOUNTPOINT
   browseable = yes
   read only = no
   guest ok = yes
   force user = root" >> "$SMB_CONF"
        systemctl restart smbd
        whiptail --msgbox "✅ Samba-Freigabe [$SHARE_NAME] erstellt." 10 60
    fi

    # Proxmox storage.cfg optional
    if whiptail --yesno "Soll dieser Mount auch in Proxmox storage.cfg eingetragen werden?" 10 60; then
        STORAGE_NAME=$(basename "$MOUNTPOINT")
        if grep -q "$MOUNTPOINT" "$STORAGE_CFG"; then
            whiptail --msgbox "Bereits in storage.cfg vorhanden." 10 60
        else
            cp "$STORAGE_CFG" "${STORAGE_CFG}.bak.$(date +%F_%T)"
            echo -e "\ndir: $STORAGE_NAME
    path $MOUNTPOINT
    content iso,backup,vztmpl
    maxfiles 3
    is_mountpoint 1" >> "$STORAGE_CFG"
            whiptail --msgbox "✅ Eintrag in storage.cfg hinzugefügt als 'dir: $STORAGE_NAME'" 10 60
        fi
    fi
}

#########################################
# Funktion: Samba-Share löschen + Unmount
#########################################
delete_samba_share() {
    if [ ! -f "$SMB_CONF" ]; then
        whiptail --msgbox "Keine smb.conf gefunden unter $SMB_CONF" 10 60
        return
    fi

    SHARE_LIST=$(grep "^\[" "$SMB_CONF" | sed 's/^\[\(.*\)\]$/\1/' | grep -v "^global$")
    [ -z "$SHARE_LIST" ] && { whiptail --msgbox "Keine Samba-Shares gefunden." 10 60; return; }

    SHARE_TO_DELETE=$(whiptail --title "Samba-Share löschen" --menu "Wähle ein Share:" 25 80 15 \
        $(for i in $SHARE_LIST; do echo "$i -"; done) 3>&1 1>&2 2>&3)
    [ -z "$SHARE_TO_DELETE" ] && return

    whiptail --yesno "Bist du sicher, dass du den Samba-Share '$SHARE_TO_DELETE' löschen willst?" 10 60 || return

    MSG=""

    # Mountpoint aus fstab oder storage.cfg ermitteln
    MOUNTPOINT=""
    if [ -f "$FSTAB_FILE" ]; then
        MOUNTPOINT=$(grep -i "$SHARE_TO_DELETE" "$FSTAB_FILE" | awk '{print $2}')
    fi
    if [ -z "$MOUNTPOINT" ] && [ -f "$STORAGE_CFG" ]; then
        MOUNTPOINT=$(awk -v share="$SHARE_TO_DELETE" '
            BEGIN {mp=""}
            $0 ~ "^[^[:space:]]" && $0 ~ "dir: "share {found=1; next}
            found && $1=="path" {mp=$2; found=0}
            END {print mp}
        ' "$STORAGE_CFG")
    fi

    # Unmount
    if [ -n "$MOUNTPOINT" ]; then
        umount "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null
        [ $? -eq 0 ] && MSG="Unmount erfolgreich ($MOUNTPOINT)." || MSG="Unmount fehlgeschlagen ($MOUNTPOINT)."
    fi

    # fstab bereinigen
    if [ -f "$FSTAB_FILE" ] && grep -q "$SHARE_TO_DELETE" "$FSTAB_FILE"; then
        cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%F_%T)"
        sed -i "/$SHARE_TO_DELETE/d" "$FSTAB_FILE"
        MSG="$MSG\nfstab-Eintrag entfernt."
    fi

    # smb.conf bearbeiten
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%F_%T)"
    awk -v share="[$SHARE_TO_DELETE]" '
        BEGIN {skip=0}
        /^\[.*\]/ {skip=($0==share)?1:0}
        skip==0 {print}
    ' "$SMB_CONF" > "${SMB_CONF}.tmp" && mv "${SMB_CONF}.tmp" "$SMB_CONF"
    MSG="$MSG\nSamba-Share gelöscht."

    # storage.cfg bereinigen
    if [ -f "$STORAGE_CFG" ]; then
        cp "$STORAGE_CFG" "${STORAGE_CFG}.bak.$(date +%F_%T)"
        awk -v share="$SHARE_TO_DELETE" '
            BEGIN {skip=0}
            {
                if ($0 ~ "^[^[:space:]]" && $0 ~ "dir: "share) {skip=1; next}
                else if ($0 ~ "^[^[:space:]]") {skip=0}
                if (skip==0) print
            }
        ' "$STORAGE_CFG" > "${STORAGE_CFG}.tmp" && mv "${STORAGE_CFG}.tmp" "$STORAGE_CFG"
        MSG="$MSG\nstorage.cfg-Block entfernt (dir: $SHARE_TO_DELETE)."
    fi

    # Samba neu starten
    systemctl restart smbd nmbd samba 2>/dev/null
    MSG="$MSG\nSamba-Dienste neu gestartet."

    whiptail --msgbox "$MSG" 20 70
}

#########################################
# Hauptmenü
#########################################
while true; do
    CHOICE=$(whiptail --title "Proxmox Mount- & Samba-Manager" --menu "Wähle eine Option:" 25 70 10 \
        "1" "Partition mounten & hinzufügen" \
        "2" "Samba-Share löschen" \
        "0" "Beenden" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) add_mount_share ;;
        2) delete_samba_share ;;
        0) exit ;;
        *) exit ;;
    esac
done