#!/usr/bin/env bash

########################################################################
#
# Copyright (C) 2015 Martin Wimpress <code@ubuntu-mate.org>
# Copyright (C) 2015 Rohith Madhavan <rohithmadhavan@gmail.com>
# Copyright (C) 2015 Ryan Finnie <ryan@finnie.org>
# Copyright (C) 2016-2018 Simon Stuerz <simon.stuerz@guh.io>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
########################################################################

set -e

#------------------------------------------------------------------------------------------
# Set the relase
TITLE="ubuntu"
RELEASE="xenial"
VERSION="16.04.4"

# Image configs
HOSTNAME="nymea"
USERNAME="nymea"
TZDATA="Europe/Vienna"

#------------------------------------------------------------------------------------------
# Directorys

SCRIPTDIR=$(pwd)
BASEDIR=${SCRIPTDIR}/image-rpi3-build
BUILDDIR=${BASEDIR}/${TITLE}
MOUNTDIR=$BUILDDIR/mount
BASE_R=${BASEDIR}/base
DEVICE_R=${BUILDDIR}/pi3
DESKTOP_R=${BUILDDIR}/desktop
ARCH=$(uname -m)
export TZ=${TZDATA}

IMAGE_NAME="$(date +%Y-%m-%d)-nymea-${TITLE}-${RELEASE}-${VERSION}-armhf-raspberry-pi-3"
TARBALL="${IMAGE_NAME}-rootfs.tar.bz2"
IMAGE="${IMAGE_NAME}.img"

# Image config
FS_TYPE="ext4"

# Size of the image in GB
FS_SIZE=2

# Either 0 or 1.
# - 0 don't make generic rootfs tarball
# - 1 make a generic rootfs tarball
MAKE_TARBALL=0

#------------------------------------------------------------------------------------------
# Settings

COLORS=true

#------------------------------------------------------------------------------------------
function usage() {
  cat <<EOF
Usage: $(basename $0) [OPTIONS]

OPTIONS:
  -n, --no-colors         Disable colorfull output
  -h, --help              Show this message

EOF
}


#------------------------------------------------------------------------------------------
# bash colors
BASH_GREEN="\e[1;32m"
BASH_RED="\e[1;31m"
BASH_NORMAL="\e[0m"

printGreen() {
    if ${COLORS}; then
        echo -e "${BASH_GREEN}[+] $1${BASH_NORMAL}"
    else
        echo -e "[+] $1"
    fi
}

printRed() {
    if ${COLORS}; then
        echo -e "${BASH_RED}[+] $1${BASH_NORMAL}"
    else
        echo -e "[+] $1"
    fi
}

#------------------------------------------------------------------------------------------
# check root
if [ ${UID} -ne 0 ]; then
    printRed "Please start the script as root."
    exit 1
fi


#------------------------------------------------------------------------------------------
# Mount host system
function mount_system() {
    printGreen "Mount system..."
    # In case this is a re-run move the cofi preload out of the way
    if [ -e $R/etc/ld.so.preload ]; then
        mv -v $R/etc/ld.so.preload $R/etc/ld.so.preload.disable
    fi
    mount -t proc none $R/proc
    mount -t sysfs none $R/sys
    mount -o bind /dev $R/dev
    mount -o bind /dev/pts $R/dev/pts
    echo "nameserver 8.8.8.8" > $R/etc/resolv.conf
}

#------------------------------------------------------------------------------------------
# Unmount host system
function umount_system() {
    printGreen "Umount system..."
    umount -l $R/sys || true
    umount -l $R/proc || true
    umount -l $R/dev/pts || true
    umount -l $R/dev || true
    echo "" > $R/etc/resolv.conf || true
}

#------------------------------------------------------------------------------------------
function sync_to() {
    printGreen "Sync ${1}..."
    local TARGET="${1}"
    if [ ! -d "${TARGET}" ]; then
        mkdir -p "${TARGET}"
    fi
    rsync -a --progress --delete ${R}/ ${TARGET}/
}

#------------------------------------------------------------------------------------------
# Base debootstrap
function bootstrap() {
    printGreen "Bootstrap..."
    # Required tools
    apt-get -y install binfmt-support debootstrap f2fs-tools \
    qemu-user-static rsync ubuntu-keyring wget whois

    # Use the same base system for all flavours.
    if [ ! -f "${R}/tmp/.bootstrap" ]; then
        if [ "${ARCH}" == "armv7l" ]; then
            debootstrap --verbose $RELEASE $R http://ports.ubuntu.com/
        else
            qemu-debootstrap --verbose --arch=armhf $RELEASE $R http://ports.ubuntu.com/
        fi
        touch "$R/tmp/.bootstrap"
    else
        printGreen "Bootstrap already created. Continue..."
    fi
}

#------------------------------------------------------------------------------------------
function generate_locale() {
    printGreen "Generate locale..."
    for LOCALE in $(chroot $R locale | cut -d'=' -f2 | grep -v : | sed 's/"//g' | uniq); do
        if [ -n "${LOCALE}" ]; then
            chroot $R locale-gen $LOCALE
        fi
    done
    # Set default LC_ALL and LANGUAGE
    echo -e "LC_ALL=en_US.UTF-8\nLANGUAGE=en_US.UTF-8" >> $R/etc/default/locale
}

#------------------------------------------------------------------------------------------
function configure_timezone() {
    printGreen "Setup timezone ${TZDATA}..."
    # Set time zone
    echo ${TZDATA} > $R/etc/timezone
    chroot $R dpkg-reconfigure -f noninteractive tzdata
}

#------------------------------------------------------------------------------------------
# Set up initial sources.list
function apt_sources() {
    printGreen "Add source lists..."
    cat <<EOM >$R/etc/apt/sources.list
deb http://ports.ubuntu.com/ ${RELEASE} main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${RELEASE} main restricted universe multiverse

deb http://ports.ubuntu.com/ ${RELEASE}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${RELEASE}-updates main restricted universe multiverse

deb http://ports.ubuntu.com/ ${RELEASE}-security main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${RELEASE}-security main restricted universe multiverse

deb http://ports.ubuntu.com/ ${RELEASE}-backports main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${RELEASE}-backports main restricted universe multiverse
EOM
}

#------------------------------------------------------------------------------------------
function apt_upgrade() {
    printGreen "Upgrade..."
    chroot $R apt-get update
    chroot $R apt-get -y -u dist-upgrade
}

#------------------------------------------------------------------------------------------
function apt_clean() {
    printGreen "Clean packages..."
    chroot $R apt-get -y autoremove
    chroot $R apt-get clean
}

#------------------------------------------------------------------------------------------
# Install Ubuntu
function install_ubuntu() {
    printGreen "Install ubuntu..."
    chroot $R apt-get -y install f2fs-tools software-properties-common
    if [ ! -f "${R}/tmp/.ubuntu" ]; then
        chroot $R apt-get -y install ubuntu-standard
        touch "${R}/tmp/.ubuntu"
    else
        printGreen "Ubuntu already installed. Continue..."
    fi
}

#------------------------------------------------------------------------------------------
function create_groups() {
    printGreen "Create groups..."
    chroot $R groupadd -f --system gpio
    chroot $R groupadd -f --system i2c
    chroot $R groupadd -f --system input
    chroot $R groupadd -f --system spi

    # Create adduser hook
    cp -v ${SCRIPTDIR}/files/adduser.local $R/usr/local/sbin/
    chmod +x $R/usr/local/sbin/adduser.local
}

#------------------------------------------------------------------------------------------
# Create default user
function create_user() {
    printGreen "Create nymea user..."
    local DATE=$(date +%m%H%M%S)
    local PASSWD=$(mkpasswd -m sha-512 ${USERNAME} ${DATE})

    chroot $R adduser --gecos "nymea user" --add_extra_groups --disabled-password ${USERNAME}
    chroot $R usermod -a -G sudo -p ${PASSWD} ${USERNAME}
}


#------------------------------------------------------------------------------------------
function configure_ssh() {
    printGreen "Configure ssh..."
    chroot $R apt-get -y install openssh-server sshguard
    cp -v ${SCRIPTDIR}/files/sshdgenkeys.service $R/etc/systemd/system/
    mkdir -p $R/etc/systemd/system/ssh.service.wants

    chroot $R /bin/systemctl enable sshdgenkeys.service
    chroot $R /bin/systemctl enable ssh.service
    chroot $R /bin/systemctl enable sshguard.service
}

#------------------------------------------------------------------------------------------
function configure_network() {
    printGreen "Set hostename ${HOSTNAME}..."

    # Set up hosts
    echo ${HOSTNAME} >$R/etc/hostname
    cat <<EOM >$R/etc/hosts
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       ${HOSTNAME}
EOM

    # Set up interfaces
    printGreen "Configure network..."
    cat <<EOM >$R/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

# The loopback network interface
auto lo
iface lo inet loopback

# This will be handled by network-manager
#auto eth0
#iface eth0 inet dhcp
EOM

}

#------------------------------------------------------------------------------------------
function configure_hardware() {
    printGreen "Configure hardware..."
    local FS="${1}"

    chroot $R apt-get -y update

    # gdebi-core used for installing copies-and-fills and omxplayer
    chroot $R apt-get -y install gdebi-core
    local COFI="http://archive.raspberrypi.org/debian/pool/main/r/raspi-copies-and-fills/raspi-copies-and-fills_0.5-1_armhf.deb"

    printGreen "Install ubuntu-pi-flavour-makers PPA"
    # Install the RPi PPA
    chroot $R apt-add-repository -y ppa:ubuntu-pi-flavour-makers/ppa
    chroot $R apt-get update

    printGreen "Install kernel and firmware..."
    # Firmware Kernel installation
    chroot $R apt-get -y install libraspberrypi-bin libraspberrypi-dev libraspberrypi-doc libraspberrypi0 raspberrypi-bootloader rpi-update raspi-config
    chroot $R apt-get -y install bluez-firmware linux-firmware pi-bluetooth

    # Raspberry Pi 3 WiFi firmware. Package this
    printGreen "Install brcm firmware..."
    cp -v firmware/* $R/lib/firmware/brcm/
    chown root:root $R/lib/firmware/brcm/*

    # Welcome message
    cp -v lib/motd $R/etc/

    # Hardware - Create a fake HW clock and add rng-tools
    chroot $R apt-get -y install fake-hwclock fbset i2c-tools rng-tools raspi-gpio

    # Install Raspberry Pi system tweaks
    chroot $R apt-get -y install raspberrypi-sys-mods

    # Disable TLP
    if [ -f $R/etc/default/tlp ]; then
        sed -i s'/TLP_ENABLE=1/TLP_ENABLE=0/' $R/etc/default/tlp
    fi

    # copies-and-fills
    # Create /spindel_install so cofi doesn't segfault when chrooted via qemu-user-static
    touch $R/spindle_install
    wget -c "${COFI}" -O $R/tmp/cofi.deb
    chroot $R gdebi -n /tmp/cofi.deb

    # Set up fstab
    cat <<EOM >$R/etc/fstab
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               ${FS}   defaults,noatime  0       1
/dev/mmcblk0p1  /boot/          vfat    defaults          0       2
EOM

    # Set boot cmdline.txt
    echo "net.ifnames=0 biosdevname=0 fsck.repair=yes dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=${FS} elevator=deadline rootwait quiet splash init=/usr/lib/raspi-config/init_resize.sh" > $R/boot/cmdline.txt

    # Enable autoresize filesystem at first boot
    cp -v ${SCRIPTDIR}/files/resize2fs_once $R/etc/init.d/resize2fs_once
    chmod +x $R/etc/init.d/resize2fs_once
    cp -v ${SCRIPTDIR}/files/resize-fs.service $R/lib/systemd/system/resize-fs.service
    chroot $R /bin/systemctl enable resize-fs.service

    # Enable i2c
    echo "i2c-dev" >> $R/etc/modules
    echo "dtparam=i2c_arm=on" >> $R/boot/config.txt

    # Save the clock
    chroot $R fake-hwclock save

    printGreen "Add aliases to bashrc..."
    echo -e "\n# Custom alias for nice bash experience\n" >> $R/etc/bash.bashrc
    echo "alias ls='ls --color=auto'" >> $R/etc/bash.bashrc
    echo "alias ll='ls -lah'" >> $R/etc/bash.bashrc
}

#------------------------------------------------------------------------------------------
function install_software() {
    printGreen "Add nymea repository..."

    cat <<EOM >$R/etc/apt/sources.list.d/nymea.list
## nymea repo
deb http://repository.nymea.io ${RELEASE} main
deb-src http://repository.nymea.io ${RELEASE} main
EOM

    # Add the nymea repository key
    chroot $R apt-key adv --keyserver keyserver.ubuntu.com --recv-key A1A19ED6

    printGreen "Update..."
    chroot $R apt-get update

    printGreen "Install extra packages..."
    chroot $R apt-get -y install htop nano avahi-utils snapd network-manager bluez bluez-tools

    printGreen "Install nymea packages..."
    chroot $R apt-get -y install nymea nymea-cli libnymea1-dev nymea-plugins nymea-plugins-maker

    printGreen "Enable nymead autostart..."
    chroot $R systemctl enable nymead
    chroot $R systemctl enable network-manager
}

#------------------------------------------------------------------------------------------
function clean_up() {
    printGreen "Clean up..."
    rm -f $R/etc/apt/*.save || true
    rm -f $R/etc/apt/sources.list.d/*.save || true
    rm -f $R/etc/resolvconf/resolv.conf.d/original
    rm -f $R/run/*/*pid || true
    rm -f $R/run/*pid || true
    rm -f $R/run/cups/cups.sock || true
    rm -f $R/run/uuidd/request || true
    rm -f $R/etc/*-
    rm -rf $R/tmp/*
    rm -f $R/var/crash/*
    rm -f $R/var/lib/urandom/random-seed

    # Build cruft
    rm -f $R/var/cache/debconf/*-old || true
    rm -f $R/var/lib/dpkg/*-old || true
    rm -f $R/var/cache/bootstrap.log || true
    truncate -s 0 $R/var/log/lastlog || true
    truncate -s 0 $R/var/log/faillog || true

    # SSH host keys
    rm -f $R/etc/ssh/ssh_host_*key
    rm -f $R/etc/ssh/ssh_host_*.pub

    # Clean up old Raspberry Pi firmware and modules
    rm -f $R/boot/.firmware_revision || true
    rm -rf $R/boot.bak || true
    rm -rf $R/lib/modules.bak || true

    # Potentially sensitive.
    rm -f $R/root/.bash_history
    rm -f $R/root/.ssh/known_hosts

    # Remove bogus home directory
    rm -rf $R/home/${SUDO_USER} || true

    # Machine-specific, so remove in case this system is going to be
    # cloned.  These will be regenerated on the first boot.
    rm -f $R/etc/udev/rules.d/70-persistent-cd.rules
    rm -f $R/etc/udev/rules.d/70-persistent-net.rules
    rm -f $R/etc/NetworkManager/system-connections/*
    [ -L $R/var/lib/dbus/machine-id ] || rm -f $R/var/lib/dbus/machine-id
    echo '' > $R/etc/machine-id

    # Enable cofi
    if [ -e $R/etc/ld.so.preload.disabled ]; then
        mv -v $R/etc/ld.so.preload.disabled $R/etc/ld.so.preload
    fi

    rm -rf $R/tmp/.bootstrap || true
    rm -rf $R/tmp/.minimal || true
    rm -rf $R/tmp/.standard || true
}

#------------------------------------------------------------------------------------------
function make_raspi3_image() {
    printGreen "Create image..."

    # Build the image file
    local FS="${1}"
    local SIZE_IMG="${2}"
    local SIZE_BOOT="64MiB"

    # Create an empty file.
    dd if=/dev/zero of="${BASEDIR}/${IMAGE}" bs=1MB count=1
    dd if=/dev/zero of="${BASEDIR}/${IMAGE}" bs=1MB count=0 seek=$(( ${SIZE_IMG} * 1000 ))

    # Initialising boot patition: msdos
    parted -s ${BASEDIR}/${IMAGE} mktable msdos
    printGreen "Creating /boot partition"
    parted -a optimal -s ${BASEDIR}/${IMAGE} mkpart primary fat32 1 "${SIZE_BOOT}"
    printGreen "Creating /root partition"
    parted -a optimal -s ${BASEDIR}/${IMAGE} mkpart primary ext4 "${SIZE_BOOT}" 100%

    PARTED_OUT=$(parted -s ${BASEDIR}/${IMAGE} unit b print)
    BOOT_OFFSET=$(echo "${PARTED_OUT}" | grep -e '^ 1'| xargs echo -n \
    | cut -d" " -f 2 | tr -d B)
    BOOT_LENGTH=$(echo "${PARTED_OUT}" | grep -e '^ 1'| xargs echo -n \
    | cut -d" " -f 4 | tr -d B)

    ROOT_OFFSET=$(echo "${PARTED_OUT}" | grep -e '^ 2'| xargs echo -n \
    | cut -d" " -f 2 | tr -d B)
    ROOT_LENGTH=$(echo "${PARTED_OUT}" | grep -e '^ 2'| xargs echo -n \
    | cut -d" " -f 4 | tr -d B)

    BOOT_LOOP=$(losetup --show -f -o ${BOOT_OFFSET} --sizelimit ${BOOT_LENGTH} ${BASEDIR}/${IMAGE})
    ROOT_LOOP=$(losetup --show -f -o ${ROOT_OFFSET} --sizelimit ${ROOT_LENGTH} ${BASEDIR}/${IMAGE})
    printGreen "/boot: offset ${BOOT_OFFSET}, length ${BOOT_LENGTH}"
    printGreen "/:     offset ${ROOT_OFFSET}, length ${ROOT_LENGTH}"

    mkfs.vfat -n PI_BOOT -S 512 -s 16 -v "${BOOT_LOOP}"
    mkfs.ext4 -L PI_ROOT -m 0 -O ^huge_file "${ROOT_LOOP}"

    MOUNTDIR="${BUILDDIR}/mount"
    mkdir -p "${MOUNTDIR}"
    mount -v "${ROOT_LOOP}" "${MOUNTDIR}" -t "${FS}"
    mkdir -p "${MOUNTDIR}/boot"
    mount -v "${BOOT_LOOP}" "${MOUNTDIR}/boot" -t vfat
    rsync -aHAXx "$R/" "${MOUNTDIR}/"
    sync
    umount -l "${MOUNTDIR}/boot"
    umount -l "${MOUNTDIR}"
    losetup -d "${ROOT_LOOP}"
    losetup -d "${BOOT_LOOP}"
}

#------------------------------------------------------------------------------------------
function make_tarball() {
    if [ ${MAKE_TARBALL} -eq 1 ]; then
        printGreen "Create tarball..."
        rm -f "${BASEDIR}/${TARBALL}" || true
        tar -cSf "${BASEDIR}/${TARBALL}" $R
    fi
}

#------------------------------------------------------------------------------------------
function stage_01_base() {
    printGreen "================================================"
    printGreen "Stage 1 - Base system"
    printGreen "================================================"

    R="${BASE_R}"
    bootstrap
    mount_system
    generate_locale
    configure_timezone
    apt_sources
    apt_upgrade
    install_ubuntu
    apt_clean
    umount_system
    sync_to ${DESKTOP_R}
}

#------------------------------------------------------------------------------------------
function stage_02_desktop() {
    printGreen "================================================"
    printGreen "Stage 2 - Configuration"
    printGreen "================================================"

    R="${DESKTOP_R}"
    mount_system

    create_groups
    create_user
    configure_ssh
    configure_network
    apt_upgrade
    apt_clean
    umount_system
    clean_up
    sync_to ${DEVICE_R}
    make_tarball
}

#------------------------------------------------------------------------------------------
function stage_03_raspi3() {
    printGreen "================================================"
    printGreen "Stage 3 - Create image"
    printGreen "================================================"

    R="${DEVICE_R}"
    mount_system
    configure_hardware ${FS_TYPE}
    install_software
    apt_upgrade
    apt_clean
    clean_up
    umount_system
    make_raspi3_image ${FS_TYPE} ${FS_SIZE}
}

#------------------------------------------------------------------------------------------
function trapCallback() {
    errorCode="$?"

    if [ "${errorCode}" != "0" ]; then
        printRed "Error occured: exit status ${errorCode}"
        printRed "Clean up and umount possible mounted paths"
        for R in $BASE_R $DESKTOP_R $DEVICE_R; do
            umount -l $R/proc || true
            umount -l $R/sys || true
            umount -l $R/dev/pts || true
            umount -l $R/dev || true
        done
    fi
    exit ${errorCode}
}

#------------------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------------------

while [ "$1" != "" ]; do
    case $1 in
        -n | --no-colors )
            COLORS=false;;
        -h | --help )
            usage && exit 0;;
        * )
            usage && exit 1;;
    esac
    shift
done

#------------------------------------------------------------------------------------------
# check root
if [ ${UID} -ne 0 ]; then
    printRed "Please start the script as root."
    exit 1
fi

trap trapCallback EXIT

startTime=$(date +%s)

stage_01_base
stage_02_desktop
stage_03_raspi3

printGreen "Compress ${IMAGE} ..."
cd ${BASEDIR}/
zip ${IMAGE_NAME}.zip ${IMAGE}
xz -z ${IMAGE}

mv -v ${IMAGE}.xz ..
mv -v ${IMAGE_NAME}.zip ..

# calculate process time
endTime=$(date +%s)
dt=$((endTime - startTime))
ds=$((dt % 60))
dm=$(((dt / 60) % 60))
dh=$((dt / 3600))

echo -e "${BASH_GREEN}"
echo -e "-------------------------------------------------------"
printf '\tTotal time: %02d:%02d:%02d\n' ${dh} ${dm} ${ds}
echo -e "-------------------------------------------------------"
echo -e "${BASH_NORMAL}"

