## ---------------------------------------------
## Scritp to install arch-linux on LUKS encrypted btrfs drive
## Features (hopefully): 
##	FIDO2 LUKS unlock
##	FIDO2 PAM for paswordless sudo
##	Install fully configured system with Sway and dotfiles
##
## TODO:
##	Everything, man!
##	Configurable via cmdline options?
## WONTDO:
##	Different partitioning schemes
##	Different WM and so on
##	Non-UEFI install (don't even try, script wont work!)
##
## Auhtor: Jan Hrubes, 2021
## ----------------------------------------------


## Some control variables
## True/false control flow
FIDO2_DISABLE=false
IPV6_DISABLE=true				## For those of us who have borked ipv6... (-_-)
SKIP_CREATE_FS=false
SKIP_MOUNT_FS=false
SKIP_PACSTRAP=false

## must be set here
CHROOT_PREFIX="arch-chroot /mnt"
KEYMAP="cz-qwertz" 				

USERSW="networkmanager vim git openssh"
BASICUTILS="btrfs-progs man-db man-pages texinfo libfido2 grub efibootmgr sudo"
INSTALLSW="${USERSW} ${BASICUTILS}"

## Script will ask if empty
INSTALL_PARTITION="/dev/nvme0n1"
USERNAME="jhrubes"
HOSTNAME="jhrubes-NTB"

## ----------------------------------------------

## End on error - DEBUG
trap exit 1 ERR

## Some utility functions
get_valid_input (){

	echo ${1} ${2} >&2
	Prompt=$( ${1} | tee /dev/tty)
	Input="?"

	while ! [[ $(grep ${Input} <<< ${Prompt} 2>/dev/null) ]]; do
		echo "Please set "${2} >&2
		read Input
		[[ $(grep ${Input} <<< ${Prompt} 2>/dev/null) ]] || echo "Wrong "${2} >&2
	done

	echo ${Input}
}

get_confirmed_input () {

	Confirm=""
	while ! [[ ${Confirm} == "y" ]]; do
		echo "Please set $1:" >&2
		read Input
		echo "is "${Input}" correct? y/n" >&2
		read Confirm
	done

	echo ${Input}
}

get_install_partition () {

    ## show lsblk, select where to partition
    [[ -z $INSTALL_PARTITION ]] && INSTALL_PARTITION="/dev/"$(get_valid_input "lsblk -d" "block device to install")
    CRYPT_PARTITION=${INSTALL_PARTITION}p2
    BOOT_PARTITION=${INSTALL_PARTITION}p1
}
## ----------------------------------------------

## Main functions

## Check connection, if not online, try to connect to wi-fi.
## (We presume that we have wireless card working)
net_connect () {

    if [[ ${IPV6_DISABLE} = true ]]; then sysctl net.ipv6.conf.all.disable_ipv6=1; fi	## Disable IPv6 on demand before checking and setting internet connection

    Tries=0
    while ! [[ $(ping -c2 -q archlinux.org 2>/dev/null) ]]; do
	    echo "Internet connection not available, trying to connect to wi-fi"

	    WLAN=$(get_valid_input "iwctl device list" "wlan device name")

	    SSID=$(get_valid_input "iwctl station $WLAN get-networks" "SSID")

	    iwctl station ${WLAN} connect ${SSID}
	    sleep 1

	    let "Tries++"
	    if [[ $Tries -gt 3 ]]; then
	    echo "Cannot connect, please fix internet connection and run script again."
	    exit 1
	    fi
    done
}

## Prepare filesystems - partition disk, create cryptroot, format EFI partition
## and prepare btrfs with subvolumes. Then mount all.
create_filesystem () {

    ## Partition disk, i dont care about other partitioning schemes or encrypted boot. Swapping to a swapfile.
    parted ${INSTALL_PARTITION} mklabel gpt
    parted ${INSTALL_PARTITION} mkpart EFI fat32 0% 512MB
    parted ${INSTALL_PARTITION} set 1 esp on
    parted ${INSTALL_PARTITION} mkpart LUKS 512MB 100%

    ## Prepare LUKS2 encrypted root
    echo "Preparing encrypted volume"
    if ! [[ ${FIDO2_DISABLE} = true ]]; then echo "No need to set strong passphrase, it will later be replaced by FIDO2 token and recovery key"; fi
    cryptsetup luksFormat ${CRYPT_PARTITION}
    cryptsetup open ${CRYPT_PARTITION} cryptroot

    ## format root partition, prepare btrfs subvolumes
    mkfs.btrfs -L root /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@pacman_cache
    btrfs subvolume create /mnt/@swap
    umount /mnt

    ## Format /boot partition
    mkfs.fat -F 32 ${BOOT_PARTITION}
}

## For now fully hardcoded
mount_filesystem () {

    [[ -e /dev/mapper/cryptroot ]] || cryptsetup open ${CRYPT_PARTITION} cryptroot

    ## Mount all prepared partitions
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/boot
    mount ${BOOT_PARTITION} /mnt/boot
    mkdir -p /mnt/home
    mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
    mkdir -p /mnt/.snapshots
    mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
    mkdir -p /mnt/var/cache/pacman/pkg
    mount -o subvol=@pacman_cache /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
    mkdir -p /mnt/swap
    mount -o subvol=@swap /dev/mapper/cryptroot /mnt/swap

}

## Create swap file
create_swapfile () {

	chmod 700 /mnt/swap
	truncate -s 0 /mnt/swap/swapfile
	chattr +C /mnt/swap/swapfile
	btrfs property set /mnt/swap/swapfile compression none
	fallocate -l $(free | awk 'NR == 2 {print $2}') /mnt/swap/swapfile
	chmod 600 /mnt/swap/swapfile
	mkswap /mnt/swap/swapfile
	swapon /mnt/swap/swapfile	
	echo "wm.swappiness=10" > /mnt/etc/sysctl.d/99-swappiness.conf

}

enable_hibernate () {
	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/s/\"$/ resume=UUID=$(findmnt -no UUID -T /mnt/swap/swapfile)\"/" /mnt/etc/default/grub
	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/s/\"$/ resume_offset=$(Arch_install/btrfs_map_physical /mnt/swap/swapfile | awk 'NR == 2 {print $9}')\"/" /mnt/etc/default/grub
}
## ----------------------------------------------

## Main script flow

## make sure we are in the correct directory
cd /root

## Keymap for instalation ISO - mainly for passphrases
loadkeys ${KEYMAP}

net_connect

## Set time via ntp
timedatectl set-ntp true

get_install_partition
[[ $SKIP_CREATE_FS = true ]] || create_filesystem
[[ $SKIP_MOUNT_FS = true ]] || mount_filesystem
create_swapfile

## Install base system + defined utils
[[ $SKIP_PACSTRAP = true ]] || pacstrap /mnt base linux linux-firmware ${INSTALLSW}


## we can create fstab now
## TODO - run olny once
genfstab -U /mnt >> /mnt/etc/fstab

## ---------------------------------------------
## Chroot to new install
## (we cannot chroot, so we will use ${CHROOT_PREFIX}
## ---------------------------------------------

## Enroll fido2 key to cryptsetup (if we are using one)
if ! [[ ${FIDO2_DISABLE} = true ]]; then ${CHROOT_PREFIX} systemd-cryptenroll --fido2-device=auto ${CRYPT_PARTITION}; fi
## and generate recovery key
if ! [[ ${FIDO2_DISABLE} = true ]]; then ${CHROOT_PREFIX} systemd-cryptenroll --recovery-key ${CRYPT_PARTITION}; fi
echo "Make sure you dont lose this!!! Press any key to continue."
read -rsn 1

## Settimezone and hwclock
${CHROOT_PREFIX} ln -sf /usr/shaze/zoneinfo/Europe/Prague /etc/localtime
${CHROOT_PREFIX} hwclock --systohc

## set locales and keymap
## TODO: for locale in locases add... 
sed -i 's/^#cs_CZ.UTF-8 UTF-8/cs_CZ.UTF-8 UTF-8/ ; s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
${CHROOT_PREFIX} locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP="${KEYMAP} > /mnt/etc/vconsole.conf

## set hosntame
if [[ -z ${HOSTNAME} ]]; then
	HOSTNAME=$(get_confirmed_input "hostname")
fi
echo ${HOSTNAME} > /mnt/etc/hostname

## update /etc/mkinitcpio.conf - add hooks
sed -i 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf

## create /etc/crypttab.initramfs , add cryptrrot by UUID
cp /mnt/etc/crypttab /mnt/etc/crypttab.initramfs
echo "cryptroot	/dev/nvme0n1p2	-	fido2-device=auto" >> /mnt/etc/crypttab.initramfs

## make initramfs
${CHROOT_PREFIX} mkinitcpio -P

## disable splash (DEBUG??)
sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/ config//' /mnt/etc/default/grub
enable_hibernate

## install grub, config grub
${CHROOT_PREFIX} grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
${CHROOT_PREFIX} grub-mkconfig -o /boot/grub/grub.cfg

## TODO - Skip if sudo group already exists
${CHROOT_PREFIX} groupadd sudo
echo "%sudo ALL=(ALL) ALL" >> /mnt/etc/sudoers

## TODO - Ask to skip if superuser already exists
## Create user - ask for username (if not provided in variable) and password
echo "We need to create non-root user."
if [[ -z ${USERNAME} ]]; then
	USERNAME=$(get_confirmed_input "username") 
fi
${CHROOT_PREFIX} useradd -m -G sudo -S /BIN/BASH ${username}
echo "Set password for "${USERNAME}
${CHROOT_PREFIX} passwd ${USERNAME}

## Enable networkmanager
## TODO - check if networkmanager exists? 
systemctl enable NetworkManager.service

## before reboot, make sure to remove old passphrase from cryptroot if using FIDO2 token.
## not yet, debuugign and token doesnt work in arch live iso... 
## DEBUG
# if ! [[ ${FIDO2_DISABLE} = true ]]; then cryptsetup luksRemoveKey ${CRYPT_PARTITION}; fi

## We should have working system, lets try to go for it. = D
reboot 
