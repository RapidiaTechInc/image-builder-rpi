#!/bin/bash
set -ex

KEYSERVER="ha.pool.sks-keyservers.net"

function clean_print(){
  local fingerprint="${2}"
  local func="${1}"

  nospaces=${fingerprint//[:space:]/}
  tolowercase=${nospaces,,}
  KEYID_long=${tolowercase:(-16)}
  KEYID_short=${tolowercase:(-8)}
  if [[ "${func}" == "fpr" ]]; then
    echo "${tolowercase}"
  elif [[ "${func}" == "long" ]]; then
    echo "${KEYID_long}"
  elif [[ "${func}" == "short" ]]; then
    echo "${KEYID_short}"
  elif [[ "${func}" == "print" ]]; then
    if [[ "${fingerprint}" != "${nospaces}" ]]; then
      printf "%-10s %50s\n" fpr: "${fingerprint}"
    fi
    # if [[ "${nospaces}" != "${tolowercase}" ]]; then
    #   printf "%-10s %50s\n" nospaces: $nospaces
    # fi
    if [[ "${tolowercase}" != "${KEYID_long}" ]]; then
      printf "%-10s %50s\n" lower: "${tolowercase}"
    fi
    printf "%-10s %50s\n" long: "${KEYID_long}"
    printf "%-10s %50s\n" short: "${KEYID_short}"
    echo ""
  else
    echo "usage: function {print|fpr|long|short} GPGKEY"
  fi
}


function get_gpg(){
  GPG_KEY="${1}"
  KEY_URL="${2}"

  clean_print print "${GPG_KEY}"
  GPG_KEY=$(clean_print fpr "${GPG_KEY}")

  if [[ "${KEY_URL}" =~ ^https?://* ]]; then
    echo "loading key from url"
    KEY_FILE=temp.gpg.key
    wget -q -O "${KEY_FILE}" "${KEY_URL}"
  elif [[ -z "${KEY_URL}" ]]; then
    echo "no source given try to load from key server"
#    gpg --keyserver "${KEYSERVER}" --recv-keys "${GPG_KEY}"
    apt-key adv --keyserver "${KEYSERVER}" --recv-keys "${GPG_KEY}"
    return $?
  else
    echo "keyfile given"
    KEY_FILE="${KEY_URL}"
  fi

  FINGERPRINT_OF_FILE=$(gpg --with-fingerprint --with-colons "${KEY_FILE}" | grep fpr | rev |cut -d: -f2 | rev)

  if [[ ${#GPG_KEY} -eq 16 ]]; then
    echo "compare long keyid"
    CHECK=$(clean_print long "${FINGERPRINT_OF_FILE}")
  elif [[ ${#GPG_KEY} -eq 8 ]]; then
    echo "compare short keyid"
    CHECK=$(clean_print short "${FINGERPRINT_OF_FILE}")
  else
    echo "compare fingerprint"
    CHECK=$(clean_print fpr "${FINGERPRINT_OF_FILE}")
  fi

  if [[ "${GPG_KEY}" == "${CHECK}" ]]; then
    echo "key OK add to apt"
    apt-key add "${KEY_FILE}"
    rm -f "${KEY_FILE}"
    return 0
  else
    echo "key invalid"
    exit 1
  fi
}

## examples:
# clean_print {print|fpr|long|short} {GPGKEYID|FINGERPRINT}
# get_gpg {GPGKEYID|FINGERPRINT} [URL|FILE]

# device specific settings
HYPRIOT_DEVICE="Raspberry Pi"

# set up /etc/resolv.conf
DEST=$(readlink -m /etc/resolv.conf)
export DEST
mkdir -p "$(dirname "${DEST}")"
echo "nameserver 8.8.8.8" > "${DEST}"

# set up Docker CE repository
DOCKERREPO_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKERREPO_KEY_URL=https://download.docker.com/linux/raspbian/gpg
get_gpg "${DOCKERREPO_FPR}" "${DOCKERREPO_KEY_URL}"

echo "deb [arch=armhf] https://download.docker.com/linux/raspbian buster $DOCKER_CE_CHANNEL" > /etc/apt/sources.list.d/docker.list

c_rehash

RPI_ORG_FPR=CF8A1AF502A2AA2D763BAE7E82B129927FA3303E RPI_ORG_KEY_URL=http://archive.raspberrypi.org/debian/raspberrypi.gpg.key
get_gpg "${RPI_ORG_FPR}" "${RPI_ORG_KEY_URL}"

echo 'deb http://archive.raspberrypi.org/debian/ buster main' | tee /etc/apt/sources.list.d/raspberrypi.list

# reload package sources
apt-get update
apt-get -o "Acquire::https::Verify-Peer=false" upgrade -y

# install WiFi firmware packages (same as in Raspbian)
apt-get install -y \
  --no-install-recommends \
  firmware-atheros \
  firmware-brcm80211 \
  firmware-libertas \
  firmware-misc-nonfree \
  firmware-realtek

# install kernel- and firmware-packages
apt-get install -y \
  --no-install-recommends \
  raspberrypi-bootloader \
  libraspberrypi0 \
  libraspberrypi-bin \
  raspi-config

# install special Docker enabled kernel
if [ -z "${KERNEL_URL}" ]; then
  apt-get install -y \
    --no-install-recommends \
    "raspberrypi-kernel"
else
  curl -L -o /tmp/kernel.deb "${KERNEL_URL}"
  dpkg -i /tmp/kernel.deb
  rm /tmp/kernel.deb
fi

# enable serial console
printf "# Spawn a getty on Raspberry Pi serial line\nT0:23:respawn:/sbin/getty -L ttyAMA0 115200 vt100\n" >> /etc/inittab

# boot/cmdline.txt
echo "dwc_otg.lpm_enable=0 console=serial0,115200 console=tty1 root=PARTUUID=${IMAGE_PARTUUID_PREFIX}-02 rootfstype=ext4 cgroup_enable=cpuset cgroup_enable=memory swapaccount=1 elevator=deadline fsck.repair=yes rootwait quiet init=/usr/lib/raspi-config/init_resize.sh" > /boot/cmdline.txt

# create a default boot/config.txt file (details see http://elinux.org/RPiconfig)
echo "
hdmi_force_hotplug=1
enable_uart=0
" > boot/config.txt

echo "# camera settings, see http://elinux.org/RPiconfig#Camera
start_x=0
disable_camera_led=1
gpu_mem=16
" >> boot/config.txt

# /etc/modules
echo "snd_bcm2835
" >> /etc/modules

# create /etc/fstab
echo "
proc /proc proc defaults 0 0
PARTUUID=${IMAGE_PARTUUID_PREFIX}-01 /boot vfat defaults 0 0
PARTUUID=${IMAGE_PARTUUID_PREFIX}-02 / ext4 defaults,noatime 0 1
" > /etc/fstab

# as the Pi does not have a hardware clock we need a fake one
apt-get install -y \
  --no-install-recommends \
  fake-hwclock

# install packages for managing wireless interfaces
apt-get install -y \
  --no-install-recommends \
  wpasupplicant \
  wireless-tools \
  crda \
  raspberrypi-net-mods

# add firmware and packages for managing bluetooth devices
apt-get install -y \
  --no-install-recommends \
  pi-bluetooth

# ensure compatibility with Docker install.sh, so `raspbian` will be detected correctly
apt-get install -y \
  --no-install-recommends \
  lsb-release \
  gettext

# install cloud-init
apt-get install -y \
  --no-install-recommends \
  cloud-init \
  ssh-import-id

# Link cloud-init config to VFAT /boot partition
mkdir -p /var/lib/cloud/seed/nocloud-net
ln -s /boot/user-data /var/lib/cloud/seed/nocloud-net/user-data
ln -s /boot/meta-data /var/lib/cloud/seed/nocloud-net/meta-data
ln -s /boot/network-config /var/lib/cloud/seed/nocloud-net/network-config

mv /etc/fake-hwclock.data /boot/fake-hwclock.data
ln -s /boot/fake-hwclock.data /etc/fake-hwclock.data
mkdir -p /etc/systemd/system/fake-hwclock.service.d
cat <<EOM |tee /etc/systemd/system/fake-hwclock.service.d/override.conf
[Unit]
Before=systemd-fsck-root.service
#Wants=boot.mount
#Requires=boot.mount
EOM
systemctl daemon-reload

# Fix duplicate IP address for eth0, remove file from os-rootfs
rm -f /etc/network/interfaces.d/eth0

# Disable dhcpcd - it has a conflict with cloud-init network config
systemctl mask dhcpcd

# Fix /etc/network/interfaces so the cloud-init network config is used
echo "source /etc/network/interfaces.d/*" > /etc/network/interfaces

# Install resolvconf ...
apt-get install -y \
  resolvconf

# and disable systemd-resolved - it doesn't work with cloud-init network config
systemctl mask systemd-resolved

# install docker-machine
curl -sSL -o /usr/local/bin/docker-machine "https://github.com/docker/machine/releases/download/v${DOCKER_MACHINE_VERSION}/docker-machine-Linux-armhf"
chmod +x /usr/local/bin/docker-machine

# install bash completion for Docker Machine
curl -sSL "https://raw.githubusercontent.com/docker/machine/v${DOCKER_MACHINE_VERSION}/contrib/completion/bash/docker-machine.bash" -o /etc/bash_completion.d/docker-machine

# install docker-compose
apt-get install -y \
  --no-install-recommends \
  python3 python3-pip python3-setuptools
update-alternatives --install /usr/bin/python python /usr/bin/python3.7 2
pip3 install "docker-compose==${DOCKER_COMPOSE_VERSION}"

# install bash completion for Docker Compose
curl -sSL "https://raw.githubusercontent.com/docker/compose/${DOCKER_COMPOSE_VERSION}/contrib/completion/bash/docker-compose" -o /etc/bash_completion.d/docker-compose

# install docker-ce (w/ install-recommends)
apt-get install -y --force-yes \
  --no-install-recommends \
  "docker-ce-cli=${DOCKER_CE_VERSION}" \
  "docker-ce=${DOCKER_CE_VERSION}"

# install bash completion for Docker CLI
curl -sSL https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/bash/docker -o /etc/bash_completion.d/docker

echo "Installing rpi-serial-console script"
wget -q https://raw.githubusercontent.com/lurch/rpi-serial-console/master/rpi-serial-console -O usr/local/bin/rpi-serial-console
chmod +x usr/local/bin/rpi-serial-console

# fix eth0 interface name
ln -s /dev/null /etc/systemd/network/99-default.link

# Install Samba
echo "samba-common samba-common/workgroup string  WORKGROUP" | debconf-set-selections
echo "samba-common samba-common/dhcp boolean true" | debconf-set-selections
echo "samba-common samba-common/do_debconf boolean true" | debconf-set-selections
apt-get install -y samba samba-common-bin

# Install Node
curl -sL https://deb.nodesource.com/setup_14.x | bash -
apt-get install -y nodejs jq
npm config set unsafe-perm true
npm install -g typescript ts-node nodemon

# cleanup APT cache and lists
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# set device label and version number
echo "HYPRIOT_DEVICE=\"$HYPRIOT_DEVICE\"" >> /etc/os-release
echo "HYPRIOT_IMAGE_VERSION=\"$HYPRIOT_IMAGE_VERSION\"" >> /etc/os-release
cp /etc/os-release /boot/os-release
