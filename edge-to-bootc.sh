#!/bin/bash
set -euox pipefail

# --------------------------------------------------------------------------
# NOTE: This script runs on a host VM (provisioned by Testing Farm)
# and creates a nested guest VM where the image is installed and validated.
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# edge-to-bootc: verify the in-place migration of a CentOS Stream 9
# edge-commit deployment to a CentOS Stream 10 bootc image.
#
# Flow:
#   1. Build a CentOS Stream 9 edge-commit via osbuild-composer and install
#      it on a UEFI guest VM via PXE and kickstart (same method as ostree.sh).
#   2. Build the CentOS Stream 10 bootc image from files/edge-bootc/Containerfile.
#   3. Layer bootc (and podman if needed) onto the edge deployment.
#   4. Load the bootc image into the guest container storage and switch the
#      deployment to it via "bootc switch".
#   5. Validate the migrated system: the deployment origin, the running
#      services, and UID/GID drift in the mutable filesystem.
# --------------------------------------------------------------------------

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# This test only supports CentOS Stream 9 on x86_64: the edge deployment is
# built from the CentOS Stream 9 repositories and the bootc target image is
# CentOS Stream 10 (see files/edge-bootc/Containerfile).
if [[ "${ID}-${VERSION_ID}" != "centos-9" ]]; then
    echo "unsupported distro: ${ID}-${VERSION_ID}, this test only supports centos-9"
    exit 1
fi

if [[ "${ARCH}" != "x86_64" ]]; then
    echo "unsupported arch: ${ARCH}, this test only supports x86_64"
    exit 1
fi

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="edge-to-bootc-${TEST_UUID}"
GUEST_ADDRESS=192.168.100.50
SSH_USER="admin"
OS_NAME="rhel-edge"
IMAGE_TYPE=edge-commit
OSTREE_REF="centos/9/${ARCH}/edge"
OS_VARIANT="centos-stream9"
# UEFI boot with secure boot disabled.
BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"

# The bootc migration target image.
BOOTC_IMAGE="localhost/edge-bootc:stream10"
BOOTC_CONTAINERFILE_DIR="files/edge-bootc"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

# Web server paths.
HTTPD_PATH="/var/www/html"
KS_FILE=${HTTPD_PATH}/ks.cfg
GRUB_CFG=${HTTPD_PATH}/httpboot/EFI/BOOT/grub.cfg
# Path depth of the CentOS Stream compose URL for the wget mirror below.
CUT_DIRS=6

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Compare rpm package version.
function nvrGreaterOrEqual {
    local rpm_name=$1
    local min_version=$2

    set +e

    rpm_version=$(rpm -q --qf "%{version}" "${rpm_name}")
    rpmdev-vercmp "${rpm_version}" "${min_version}" 1>&2
    if [ "$?" != "12" ]; then
        # 0 - rpm_version == min_version
        # 11 - rpm_version > min_version
        # 12 - rpm_version < min_version
        set -e
        return
    fi

    set -e
    false
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-${COMPOSE_ID}.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    sudo tar -xf "$TARBALL" -C "${TEMPDIR}"
    sudo rm -f "$TARBALL"

    # Move the JSON file into place.
    sudo cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Build ostree image.
build_image() {
    blueprint_file=$1
    blueprint_name=$2

    # Prepare the blueprint for the compose.
    greenprint "📋 Preparing blueprint"
    sudo composer-cli blueprints push "$blueprint_file"
    sudo composer-cli blueprints depsolve "$blueprint_name"

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!

    # Start the compose.
    greenprint "🚀 Starting compose"
    sudo composer-cli --json compose start "$blueprint_name" "${IMAGE_TYPE}" | tee "$COMPOSE_START"

    if nvrGreaterOrEqual "weldr-client" "35.6"; then
        COMPOSE_ID=$(jq -r '.[0].body.build_id' "$COMPOSE_START")
    else
        COMPOSE_ID=$(jq -r '.body.build_id' "$COMPOSE_START")
    fi

    # Wait for the compose to finish.
    greenprint "⏱️ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null

        if nvrGreaterOrEqual "weldr-client" "35.6"; then
            COMPOSE_STATUS=$(jq -r '.[0].body.queue_status' "$COMPOSE_INFO")
        else
            COMPOSE_STATUS=$(jq -r '.body.queue_status' "$COMPOSE_INFO")
        fi

        # Is the compose finished?
        if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
            break
        fi

        # Wait 5 seconds and try again.
        sleep 5
    done

    # Capture the compose logs from osbuild.
    greenprint "💬 Getting compose log and metadata"
    get_compose_log "$COMPOSE_ID"
    get_compose_metadata "$COMPOSE_ID"

    # Did the compose finish with success?
    if [[ $COMPOSE_STATUS != FINISHED ]]; then
        echo "Something went wrong with the compose. 😢"
        exit 1
    fi

    # Stop watching the worker journal.
    sudo pkill -P ${WORKER_JOURNAL_PID}
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Dump guest state to help debug failures.
dump_diagnostics () {
    greenprint "🔧 Dumping diagnostics"
    sudo virsh domstate "${IMAGE_KEY}" || true
    if sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'true' 2>/dev/null; then
        sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'cat /etc/os-release' || true
        sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo bootc status' || true
        sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo rpm-ostree status' || true
        sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'systemctl --failed' || true
        sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo journalctl -b -p err --no-pager | tail -50' || true
        sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo journalctl -b -u greenboot-healthcheck --no-pager | tail -30' || true
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"
    sudo virsh destroy "${IMAGE_KEY}"
    sudo virsh undefine "${IMAGE_KEY}" --nvram
    # Remove qcow2 file.
    sudo virsh vol-delete --pool images "${IMAGE_KEY}.qcow2"
    # Remove "remote" repo.
    sudo rm -rf "${HTTPD_PATH}"/{httpboot,repo,compose.json,ks.cfg}
    # Remove tmp dir.
    sudo rm -rf "$TEMPDIR"
    # Stop httpd
    sudo systemctl disable httpd --now
}

# Test result checking
check_result () {
    greenprint "Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        greenprint "💚 Success"
    else
        greenprint "❌ Failure"
        dump_diagnostics
        clean_up
        exit 1
    fi
}

##################################################
##
## Deploy a CentOS Stream 9 edge-commit guest VM
##
##################################################

# Write a blueprint for the ostree image. The admin user and its SSH key are
# baked into the commit itself (CentOS Stream 9 edge images support user
# customization in the blueprint).
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "ostree"
description = "A base ostree image"
version = "0.0.1"
modules = []
groups = []
[[packages]]
name = "python3"
version = "*"
[[packages]]
name = "sssd"
version = "*"
[[customizations.user]]
name = "${SSH_USER}"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
home = "/home/${SSH_USER}/"
groups = ["wheel"]
EOF

# Build installation image.
build_image "$BLUEPRINT_FILE" ostree

# Download the image and extract tar into web server root folder.
greenprint "📥 Downloading and extracting the image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
IMAGE_FILENAME="${COMPOSE_ID}-commit.tar"
sudo tar -xf "${IMAGE_FILENAME}" -C "${HTTPD_PATH}"
sudo rm -f "$IMAGE_FILENAME"

# Clean compose and blueprints.
greenprint "Clean up osbuild-composer"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete ostree > /dev/null

# Resolve the current CentOS Stream 9 production compose. Do not use the
# latest link but the compose ID URL to work around issue
# https://bugzilla.redhat.com/show_bug.cgi?id=2065708
CURRENT_COMPOSE_CS9=$(curl -s "https://composes.stream.centos.org/production/" | grep -ioE ">CentOS-Stream-9-.*/<" | tr -d '>/<' | tail -1)
BOOT_LOCATION="https://composes.stream.centos.org/production/${CURRENT_COMPOSE_CS9}/compose/BaseOS/x86_64/os/"

# Download HTTP boot required files.
greenprint "📥 Download HTTP boot required files"
sudo rm -rf "${HTTPD_PATH}/httpboot"
sudo mkdir -p "${HTTPD_PATH}/httpboot"
REQUIRED_FOLDERS=( "EFI" "images" )
for i in "${REQUIRED_FOLDERS[@]}"
do
    sudo wget -q --inet4-only -r --no-parent -e robots=off -nH --cut-dirs="$CUT_DIRS" --reject "index.html*" --reject "boot.iso" "${BOOT_LOCATION}${i}/" -P "${HTTPD_PATH}/httpboot/"
done

# Update grub.cfg to work with HTTP boot.
greenprint "📝 Update grub.cfg to work with HTTP boot"
sudo tee -a "${GRUB_CFG}" > /dev/null << EOF
menuentry 'Install Red Hat Enterprise Linux for Edge' --class fedora --class gnu-linux --class gnu --class os {
        linuxefi /httpboot/images/pxeboot/vmlinuz inst.stage2=http://192.168.100.1/httpboot inst.ks=http://192.168.100.1/ks.cfg inst.text console=ttyS0,115200
        initrdefi /httpboot/images/pxeboot/initrd.img
}
EOF
sudo sed -i 's/timeout=60/timeout=10/' "${GRUB_CFG}"
# The grub default menuentry has to point at our custom entry. A FIPS
# menuentry was added upstream, shifting the position of our custom entry.
# https://github.com/virt-s1/rhel-edge/issues/9968
sudo sed -i 's/default="1"/default="4"/' "${GRUB_CFG}"

# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt-install"
LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}.qcow2
sudo qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH}" 20G

# Write kickstart file for ostree image installation. The admin user comes
# from the blueprint (baked into the commit), so the kickstart does not need
# user/sshkey commands.
greenprint "Generate kickstart file"
sudo tee "$KS_FILE" > /dev/null << STOPHERE
text
lang en_US.UTF-8
keyboard us
timezone --utc Etc/UTC
selinux --enforcing
rootpw --lock --iscrypted locked
bootloader --timeout=1 --append="net.ifnames=0 modprobe.blacklist=vc4"
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
ostreesetup --nogpg --osname=${OS_NAME} --remote=${OS_NAME} --url=http://192.168.100.1/repo/ --ref=${OSTREE_REF}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for SSH user
echo -e '${SSH_USER}\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
# Remove any persistent NIC rules generated by udev
rm -vf /etc/udev/rules.d/*persistent-net*.rules
# And ensure that we will do DHCP on eth0 on startup
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
PERSISTENT_DHCLIENT="yes"
EOF
%end
STOPHERE

# Ensure SELinux is happy with our new images.
greenprint "👿 Running restorecon on image directory"
sudo restorecon -Rv /var/lib/libvirt/images/

# Install ostree image via anaconda on UEFI guest VM.
greenprint "Install ostree image via anaconda"
sudo virt-install  --name="${IMAGE_KEY}"\
                   --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                   --ram 4096 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --pxe \
                   --boot "${BOOT_ARGS}" \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${IMAGE_KEY}"

# Verify install: UEFI guest VM is reachable via SSH after installation.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Verify reboot: UEFI guest VM is reachable via SSH after reboot (/sysroot RO activation).
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

# Record the pre-migration UID/GID drift baseline. This is informational
# only; the enforced check runs after the migration.
greenprint "🔎 Recording pre-migration UID/GID drift baseline"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" \
    'sudo find /etc /var -xdev \( -nouser -o -nogroup \) -print' | tee "${TEMPDIR}/drift-baseline.txt" || true

##################################################
##
## Build the CentOS Stream 10 bootc image
##
##################################################

greenprint "🚀 Building the bootc image from the Containerfile"
sudo podman build \
    --cap-add=all \
    --security-opt label=type:container_runtime_t \
    --device /dev/fuse \
    -t "${BOOTC_IMAGE}" \
    "${BOOTC_CONTAINERFILE_DIR}"

##################################################
##
## Migrate the edge deployment to the bootc image
##
##################################################

# Layer bootc onto the edge deployment. Also layer podman when the edge base
# image does not ship it; podman is needed to load the bootc image into the
# guest container storage.
LAYERED_PACKAGES="bootc"
if ! sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'command -v podman' >/dev/null 2>&1; then
    LAYERED_PACKAGES="${LAYERED_PACKAGES} podman"
fi

greenprint "📦 Layering ${LAYERED_PACKAGES} onto the edge deployment"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" "sudo rpm-ostree install ${LAYERED_PACKAGES}"

# Reboot into the layered deployment.
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10

greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check layering result
check_result

# Transfer the bootc image into the guest container storage (no registry
# needed) so bootc can switch to it directly.
greenprint "📤 Transferring the bootc image to the guest"
sudo podman save "${BOOTC_IMAGE}" | sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo podman load'

greenprint "🔀 Switching the deployment to the bootc image"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" "sudo bootc switch --transport containers-storage ${BOOTC_IMAGE}"

# Reboot into the bootc deployment.
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10

greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# If the bootc deployment fails to boot, greenboot rolls back to the edge
# deployment and SSH comes back up on the old system instead. Detect that
# case distinctly so the failure reason is clear.
greenprint "🕵️ Checking which deployment is booted"
GUEST_VERSION_ID=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" '. /etc/os-release && echo "${VERSION_ID}"')
if [[ "${GUEST_VERSION_ID}" != "10" ]]; then
    greenprint "❌ The bootc deployment did not boot; the guest is still CentOS Stream ${GUEST_VERSION_ID}"
    greenprint "Checking greenboot rollback evidence:"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo journalctl -b -u greenboot-healthcheck --no-pager | tail -30' || true
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo journalctl -b -1 -u greenboot-healthcheck --no-pager | tail -30' || true
    RESULTS=0
    check_result
fi
greenprint "💚 The guest booted the CentOS Stream 10 bootc deployment"

##################################################
##
## Validate the migrated system
##
##################################################

RESULTS=1

# bootc status reports the target image as the booted deployment.
greenprint "🛃 Validating bootc status"
if sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo bootc status' | grep -q "${BOOTC_IMAGE}"; then
    greenprint "💚 bootc status reports the booted image ${BOOTC_IMAGE}"
else
    greenprint "❌ bootc status does not report the booted image ${BOOTC_IMAGE}"
    RESULTS=0
fi

# rpm-ostree status shows the deployment origin switched to the bootc image.
greenprint "🛃 Validating rpm-ostree status"
if sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo rpm-ostree status' | grep -q "edge-bootc"; then
    greenprint "💚 rpm-ostree status shows the bootc image as deployment origin"
else
    greenprint "❌ rpm-ostree status does not show the bootc image as deployment origin"
    RESULTS=0
fi

# No failed units after the migration. A broken migration typically shows up
# as a systemd-sysusers failure cascading into failed services.
greenprint "🛃 Validating system services"
FAILED_UNITS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'systemctl --failed --no-legend' || true)
if [[ -z "${FAILED_UNITS}" ]]; then
    greenprint "💚 No failed systemd units"
else
    greenprint "❌ Failed systemd units:"
    echo "${FAILED_UNITS}"
    RESULTS=0
fi

# systemd-sysusers must have completed successfully on the migrated system.
SYSUSERS_RESULT=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'systemctl show systemd-sysusers.service -p Result --value' || echo "ssh-failed")
if [[ "${SYSUSERS_RESULT}" == "success" ]]; then
    greenprint "💚 systemd-sysusers completed successfully"
else
    greenprint "❌ systemd-sysusers result: ${SYSUSERS_RESULT}"
    RESULTS=0
fi

# greenboot health checks must have passed on the migrated deployment.
GREENBOOT_RESULT=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'systemctl show greenboot-healthcheck.service -p Result --value' || echo "ssh-failed")
if [[ "${GREENBOOT_RESULT}" == "success" ]]; then
    greenprint "💚 greenboot health checks passed"
else
    greenprint "❌ greenboot-healthcheck result: ${GREENBOOT_RESULT}"
    RESULTS=0
fi

# The expected long-running services from the edge package set.
for service in sshd NetworkManager firewalld auditd chronyd; do
    if sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" "systemctl is-active ${service}" | grep -q "^active$"; then
        greenprint "💚 ${service} is active"
    else
        greenprint "❌ ${service} is not active"
        RESULTS=0
    fi
done

# Scan the mutable filesystem for UID/GID drift: files owned by a user or
# group that has no entry in passwd/group.
greenprint "🛃 Scanning for UID/GID drift"
DRIFT_FILES=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo find /etc /var -xdev \( -nouser -o -nogroup \) -print' || true)
if [[ -z "${DRIFT_FILES}" ]]; then
    greenprint "💚 No UID/GID drift detected in /etc and /var"
else
    greenprint "❌ UID/GID drift detected, files with missing user or group ownership:"
    echo "${DRIFT_FILES}"
    RESULTS=0
fi

# Verify the user and group databases are internally consistent. Stale
# shadow entries here are what crashes systemd-sysusers after a migration
# that assembled passwd/group files by hand.
greenprint "🛃 Validating user and group databases"
if sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo pwck -r'; then
    greenprint "💚 pwck reports no errors"
else
    greenprint "❌ pwck reported errors"
    RESULTS=0
fi

if sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo grpck -r'; then
    greenprint "💚 grpck reports no errors"
else
    greenprint "❌ grpck reported errors"
    RESULTS=0
fi

# Check migration result
check_result

# Final success clean up
clean_up

exit 0
