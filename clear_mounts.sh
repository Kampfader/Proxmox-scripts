#!/bin/bash
# Proxmox Samba Manager inkl. zuverlässigem Unmount
# Nutzt whiptail für eine einfache GUI im Terminal

SMB_CONF="/etc/samba/smb.conf"
FSTAB_FILE="/etc/fstab"
STORAGE_CFG="/etc/pve/storage.cfg"

delete_samba_share() {
    if [ ! -f "$SMB_CONF" ]; then
        whiptail --msgbox "Keine smb.conf gefunden unter $SMB_CONF" 10 60
        return
    fi

    # Liste der Shares aus smb.conf
    SHARE_LIST=$(grep "^\[" "$SMB_CONF" | sed 's/^\[\(.*\)\]$/\1/' | grep -v "^global$")
    if [ -z "$SHARE_LIST" ]; then
        whiptail --msgbox "Keine Samba-Shares gefunden." 10 60
        return
    fi

    # Auswahlmenü
    SHARE_TO_DELETE=$(whiptail --title "Samba-Share löschen" --menu "Wähle ein Share:" 25 80 15 \
        $(for i in $SHARE_LIST; do echo "$i -"; done) 3>&1 1>&2 2>&3)

    if [ -n "$SHARE_TO_DELETE" ]; then
        whiptail --yesno "Bist du sicher, dass du den Samba-Share '$SHARE_TO_DELETE' löschen willst?" 10 60
        if [ $? -eq 0 ]; then
            MSG=""

            # 1️⃣ Mountpfad aus fstab oder storage.cfg ermitteln
            MOUNTPOINT=""
            if [ -f "$FSTAB_FILE" ]; then
                MOUNTPOINT=$(grep -i "$SHARE_TO_DELETE" "$FSTAB_FILE" | awk '{print $2}')
            fi
            # Falls nicht in fstab, aus storage.cfg ermitteln (dir: <ShareName> -> path Zeile)
            if [ -z "$MOUNTPOINT" ] && [ -f "$STORAGE_CFG" ]; then
                MOUNTPOINT=$(awk -v share="$SHARE_TO_DELETE" '
                    BEGIN {mp=""}
                    $0 ~ "^[^[:space:]]" && $0 ~ "dir: "share {found=1; next}
                    found && $1=="path" {mp=$2; found=0}
                    END {print mp}
                ' "$STORAGE_CFG")
            fi

            # 2️⃣ Unmount durchführen, falls Mountpunkt gefunden
            if [ -n "$MOUNTPOINT" ]; then
                umount "$MOUNTPOINT" 2>/dev/null
                if [ $? -eq 0 ]; then
                    MSG="Unmount erfolgreich ($MOUNTPOINT)."
                else
                    # Alternative: Lazy unmount
                    umount -l "$MOUNTPOINT" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        MSG="Lazy Unmount erfolgreich ($MOUNTPOINT)."
                    else
                        MSG="Unmount fehlgeschlagen ($MOUNTPOINT)."
                    fi
                fi
            fi

            # 3️⃣ fstab-Einträge löschen
            if [ -f "$FSTAB_FILE" ]; then
                if grep -q "$SHARE_TO_DELETE" "$FSTAB_FILE"; then
                    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%F_%T)"
                    sed -i "/$SHARE_TO_DELETE/d" "$FSTAB_FILE"
                    MSG="$MSG\nfstab-Eintrag entfernt."
                fi
            fi

            # 4️⃣ smb.conf bearbeiten
            cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%F_%T)"
            awk -v share="[$SHARE_TO_DELETE]" '
                BEGIN {skip=0}
                /^\[.*\]/ {skip=($0==share)?1:0}
                skip==0 {print}
            ' "$SMB_CONF" > "${SMB_CONF}.tmp" && mv "${SMB_CONF}.tmp" "$SMB_CONF"
            MSG="$MSG\nSamba-Share gelöscht."

            # 5️⃣ storage.cfg Block löschen (dir: <ShareName> + eingerückte Zeilen)
            if [ -f "$STORAGE_CFG" ]; then
                cp "$STORAGE_CFG" "${STORAGE_CFG}.bak.$(date +%F_%T)"
                awk -v share="$SHARE_TO_DELETE" '
                    BEGIN {skip=0}
                    {
                        if ($0 ~ "^[^[:space:]]" && $0 ~ "dir: "share) {skip=1; next}  # Blockstart
                        else if ($0 ~ "^[^[:space:]]") {skip=0}                        # Neue Zeile ohne Einrückung → Blockende
                        if (skip==0) print
                    }
                ' "$STORAGE_CFG" > "${STORAGE_CFG}.tmp" && mv "${STORAGE_CFG}.tmp" "$STORAGE_CFG"
                MSG="$MSG\nstorage.cfg-Block entfernt (dir: $SHARE_TO_DELETE)."
            fi

            # 6️⃣ Samba Dienste neu starten
            systemctl restart smbd nmbd samba 2>/dev/null
            MSG="$MSG\nSamba-Dienste neu gestartet."

            whiptail --msgbox "$MSG" 20 70
        fi
    fi
}

while true; do
    CHOICE=$(whiptail --title "Proxmox Samba Manager" --menu "Wähle eine Option:" 25 60 10 \
        "1" "Samba-Share löschen" \
        "0" "Beenden" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) delete_samba_share ;;
        0) exit ;;
        *) exit ;;
    esac
done
