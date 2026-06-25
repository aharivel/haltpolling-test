#!/usr/bin/env bash
# setup-vm.sh — download CS9 cloud image, create halt-test VM (8 vCPU, 4G RAM)
# Run as root on panther04.
set -euo pipefail

IMG_DIR=/var/lib/libvirt/images
IMG_NAME=cs9-halttest.qcow2
IMG_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
VM=halt-test

# ---------- download image ----------
if [[ ! -f "$IMG_DIR/$IMG_NAME" ]]; then
  echo "Downloading CentOS Stream 9 cloud image..."
  curl -L -o "$IMG_DIR/$IMG_NAME" "$IMG_URL"
  # resize to 10G (cloud images are tiny by default)
  qemu-img resize "$IMG_DIR/$IMG_NAME" 10G
else
  echo "Image already exists: $IMG_DIR/$IMG_NAME"
fi

# ---------- cloud-init ISO (set root password, enable SSH) ----------
CI_DIR=$(mktemp -d)
cat > "$CI_DIR/meta-data" <<'EOF'
instance-id: halt-test
local-hostname: halt-test
EOF

cat > "$CI_DIR/user-data" <<'EOF'
#cloud-config
password: halttest
chpasswd:
  expire: false
ssh_pwauth: true
disable_root: false
# Disable guest-side halt-poll cpuidle driver (§5 ground rule 5)
bootcmd:
  - echo 1 > /sys/module/cpuidle_haltpoll/parameters/force || true
runcmd:
  - echo "cpuidle_haltpoll.force=0" >> /etc/default/grub
  - grub2-mkconfig -o /boot/grub2/grub.cfg || true
EOF

CI_ISO="$IMG_DIR/halt-test-cidata.iso"
genisoimage -output "$CI_ISO" -volid cidata -joliet -rock \
  "$CI_DIR/user-data" "$CI_DIR/meta-data" 2>/dev/null \
  || mkisofs -output "$CI_ISO" -volid cidata -joliet -rock \
  "$CI_DIR/user-data" "$CI_DIR/meta-data"
rm -rf "$CI_DIR"

# ---------- define VM ----------
virt-install \
  --name "$VM" \
  --memory 4096 \
  --vcpus 8 \
  --cpu host-passthrough \
  --disk "path=$IMG_DIR/$IMG_NAME,format=qcow2,bus=virtio" \
  --disk "path=$CI_ISO,device=cdrom" \
  --network network=default,model=virtio \
  --os-variant centos-stream9 \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole \
  --import

echo ""
echo "VM '$VM' created and starting."
echo "Wait ~60s for cloud-init, then: virsh console $VM  (root / halttest)"
echo ""
echo "After boot, apply pinning (8 vCPUs on node0 isolated cores):"
echo "  virsh vcpupin $VM 0 2"
echo "  virsh vcpupin $VM 1 4"
echo "  virsh vcpupin $VM 2 6"
echo "  virsh vcpupin $VM 3 8"
echo "  virsh vcpupin $VM 4 10"
echo "  virsh vcpupin $VM 5 12"
echo "  virsh vcpupin $VM 6 14"
echo "  virsh vcpupin $VM 7 18"
echo "  virsh emulatorpin $VM 3,5,7       # node1 isolated"
echo "  virsh numatune $VM --mode strict --nodeset 0"
echo ""
echo "Verify guest cpuidle driver:"
echo "  ssh root@\$(virsh domifaddr $VM | grep -oE '([0-9]+\.){3}[0-9]+') cat /sys/devices/system/cpu/cpuidle/current_driver"
