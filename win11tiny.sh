#!/bin/bash

# === Konfiguration ===
VMID=110
VMNAME="win11tiny"
ISOFILE="tiny11x64_23H2.iso"
VIRTIOISO="virtio-win.iso"
STORAGE="BigSSD"
CORES=4
RAM=8192
DISK_SIZE="30"
MACADDR="02:09:26:15:A1:3A"
BRIDGE="vmbr0"

# === Vorabprüfungen ===
echo "🔍 Prüfe, ob VM $VMID bereits existiert..."
if qm status $VMID &>/dev/null; then
  echo "⚠️ VM $VMID existiert bereits. Abbruch."
  exit 1
fi

echo "📁 Prüfe ISO-Dateien im Storage '$STORAGE'..."
ISO_CONTENT=$(pvesh get /nodes/$(hostname)/storage/$STORAGE/content)
if ! echo "$ISO_CONTENT" | grep -q "$ISOFILE"; then
  echo "❌ Windows-ISO '$ISOFILE' nicht gefunden im Storage '$STORAGE'."
  exit 1
fi
if ! echo "$ISO_CONTENT" | grep -q "$VIRTIOISO"; then
  echo "❌ VirtIO-ISO '$VIRTIOISO' nicht gefunden im Storage '$STORAGE'."
  exit 1
fi

# === VM erstellen ===
echo "📦 Erstelle VM $VMID ($VMNAME)..."
qm create $VMID \
  --name $VMNAME \
  --memory $RAM \
  --cores $CORES \
  --net0 virtio=${MACADDR},bridge=${BRIDGE} \
  --ostype win11 \
  --machine q35 \
  --bios ovmf \
  --cpu host \
  --boot order=ide2

# === Systemdisk an virtio0 anhängen ===
echo "💾 Erstelle Systemdisk (${DISK_SIZE}G)..."
qm set $VMID --virtio0 ${STORAGE}:${DISK_SIZE},format=qcow2,discard=on

# === EFI-Disk erstellen ===
echo "🔐 Erstelle EFI-Disk..."
qm set $VMID \
  --efidisk0 ${STORAGE}:0,format=qcow2,efitype=4m,pre-enrolled-keys=1

# === Windows-ISO einbinden ===
echo "💿 Binde Windows-ISO ein..."
qm set $VMID \
  --ide2 ${STORAGE}:iso/${ISOFILE},media=cdrom

# === VirtIO-Treiber-ISO einbinden ===
echo "🧩 Binde VirtIO-Treiber-ISO ein..."
qm set $VMID \
  --ide3 ${STORAGE}:iso/${VIRTIOISO},media=cdrom

# === Fertig ===
echo "✅ VM $VMID ($VMNAME) ist bereit. Starte mit:"
echo "qm start $VMID"
