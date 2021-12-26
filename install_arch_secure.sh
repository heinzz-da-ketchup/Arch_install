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


## Colors! pretty, pretty colors! = )
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

## Some control variables
## True/false control flow
FIDO2_DISABLE=false
IPV6_DISABLE=true				## For those of us who have borked ipv6... (-_-)
SKIP_CREATE_FS=false
SKIP_MOUNT_FS=false
SKIP_PACSTRAP=false
SKIP_SWAPFILE=false
SKIP_HIBERNATE=false
SKIP_SECUREBOOT=false
ONLY_MOUNT=false

## must be set here
CHROOT_PREFIX="arch-chroot /mnt"
KEYMAP="cz-qwertz" 				

USERSW="networkmanager vim git openssh"
BASICUTILS="btrfs-progs man-db man-pages texinfo libfido2 grub efibootmgr sudo sbsigntools"
INSTALLSW="${USERSW} ${BASICUTILS}"

## Script will ask or use defaults if empty
INSTALL_PARTITION=""		## As a full path, eg. "/dev/sdb"
USERNAME=""
HOSTNAME=""
BUILDDIR=""			## Path in install environment, eg "/mnt/path/to/file"
MOKDIR=""			## ---------------------- // ------------------------
SWAPFILE=""			## ---------------------- // ------------------------

## ----------------------------------------------
## Set some sane defaults if needed

if [[ -z ${BUILDDIR} ]]; then
	BUILDDIR="/mnt/home/${USERNAME}/builds"
	BUILDDIR_CHROOT="/home/${USERNAME}/builds"
else
	BUILDDIR_CHROOT=$(sed 's|/mnt||' <<< ${BUILDDIR})
fi

if [[ -z ${MOKDIR} ]]; then
	MOKDIR="/mnt/home/${USERNAME}/.mok"
	MOKDIR_CHROOT="/home/${USERNAME}/.mok"
else
	MOKDIR_CHROOT=$(sed 's|/mnt||' <<< ${MOKDIR})
fi

if [[ -z ${SWAPFILE} ]]; then
	SWAPFILE="/mnt/swap/swapfile"
fi
SWAPDIR=$(grep -o '.*/'<<< ${SWAPFILE})

## ----------------------------------------------

## End on error - DEBUG
trap exit 1 ERR

## Some utility functions
notify () {

    printf ${GREEN}
    printf "##############################\n"
    printf "$1\n"
    printf "##############################\n\n"
    printf ${NC}
}

notify_wait () {

    printf ${GREEN}
    printf "##############################\n"
    printf "$1\n"
    printf "\nPress any key to continue\n"
    printf "##############################\n\n"
    printf ${NC}
    read -rsn 1
}

warn () {

    printf ${YELLOW}
    printf "##############################\n"
    printf "$1\n"
    printf "##############################\n\n"
    printf ${NC}
}

warn_wait () {

    printf ${YELLOW}
    printf "##############################\n"
    printf "$1\n"
    printf "\nPress any key to continue\n"
    printf "##############################\n\n"
    printf ${NC}
    read -rsn 1
}

error () {

    printf ${RED}
    printf "##############################\n"
    printf "$1\n"
    printf "##############################\n\n"
    printf ${NC}
    exit 1
}

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

set_variables () {

    notify_wait "We need to set some basic variables"

    ## show lsblk, select where to partition
    [[ -z $INSTALL_PARTITION ]] && INSTALL_PARTITION="/dev/"$(get_valid_input "lsblk -d" "block device to install")
    CRYPT_PARTITION=${INSTALL_PARTITION}p2
    BOOT_PARTITION=${INSTALL_PARTITION}p1

    if [[ -z ${USERNAME} ]]; then
	    USERNAME=$(get_confirmed_input "username") 
    fi

    if [[ -z ${HOSTNAME} ]]; then
	    HOSTNAME=$(get_confirmed_input "hostname")
    fi
}
## ----------------------------------------------

## Main functions

## Check connection, if not online, try to connect to wi-fi.
## (We presume that we have wireless card working)
net_connect () {

    if [[ ${IPV6_DISABLE} = true ]]; then sysctl net.ipv6.conf.all.disable_ipv6=1 >/dev/null; notify "IPv6 Disabled"; fi	## Disable IPv6 on demand before checking and setting internet connection

    Tries=0
    while ! [[ $(ping -c2 -q archlinux.org 2>/dev/null) ]]; do
	    warn "Internet connection not available, trying to connect to wi-fi"

	    WLAN=$(get_valid_input "iwctl device list" "wlan device name")

	    SSID=$(get_valid_input "iwctl station $WLAN get-networks" "SSID")

	    iwctl station ${WLAN} connect ${SSID}
	    sleep 1

	    let "Tries++"
	    if [[ $Tries -gt 3 ]]; then
	    error "Cannot connect, please fix internet connection and run script again."
	    fi
    done
}

## Prepare filesystems - partition disk, create cryptroot, format EFI partition
## and prepare btrfs with subvolumes. 
create_filesystem () {

    ## Partition disk, i dont care about other partitioning schemes or encrypted boot. Swapping to a swapfile.
    notify "Partitioning device"
    parted ${INSTALL_PARTITION} mklabel gpt
    parted ${INSTALL_PARTITION} mkpart EFI fat32 0% 512MB
    parted ${INSTALL_PARTITION} set 1 esp on
    parted ${INSTALL_PARTITION} mkpart LUKS 512MB 100%

    ## Prepare LUKS2 encrypted root
    notify "Preparing encrypted volume"
    if ! [[ ${FIDO2_DISABLE} = true ]]; then warn_wait "No need to set strong passphrase, it will later be replaced by FIDO2 token and recovery key"; fi
    cryptsetup luksFormat ${CRYPT_PARTITION}
    notify "Encrypted volume created, please unlock it"
    cryptsetup open ${CRYPT_PARTITION} cryptroot

    ## format root partition, prepare btrfs subvolumes
    notify "Creating btfrs filesystem"
    mkfs.btrfs -L root /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@pacman_cache
    btrfs subvolume create /mnt/@swap
    umount /mnt

    ## Format /boot partition
    notify "Formating boot partition"
    mkfs.fat -F 32 ${BOOT_PARTITION}
}

## For now fully hardcoded
mount_filesystem () {

    if ! [[ -e /dev/mapper/cryptroot ]]; then
	notify "please unlock cryptroot"
	cryptsetup open ${CRYPT_PARTITION} cryptroot
    fi

    # Create all needed mountpoints
    mkdir -p /mnt/boot
    mkdir -p /mnt/home
    mkdir -p /mnt/.snapshots
    mkdir -p /mnt/var/cache/pacman/pkg
    mkdir -p ${SWAPDIR}

    ## Mount all prepared partitions
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mount ${BOOT_PARTITION} /mnt/boot
    mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
    mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
    mount -o subvol=@pacman_cache /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
    mount -o subvol=@swap /dev/mapper/cryptroot ${SWAPDIR}
}

## Create swap file
create_swapfile () {

	notify "Preparing swap file at ${SWAPFILE}"
	chmod 700 ${SWAPDIR}
	truncate -s 0 ${SWAPFILE}
	chattr +C ${SWAPFILE}
	btrfs property set ${SWAPFILE} compression none
	fallocate -l $(free -h | awk 'NR == 2 {print $2}' | sed 's/i//' ) ${SWAPFILE}
	chmod 600 ${SWAPFILE}
	mkswap ${SWAPFILE}
	swapon ${SWAPFILE}	

}

enable_hibernate () {

	notify "Configuring hibernation to swapfile"
	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/s/\"$/ resume=UUID=$(findmnt -no UUID -T ${SWAPFILE})\"/" /mnt/etc/default/grub
	SWAPFILE_PHYSICAL=$(Arch_install/btrfs_map_physical ${SWAPFILE} | awk 'NR == 2 {print $9}')
	PAGESIZE=$(${CHROOT_PREFIX} getconf PAGESIZE)
	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/s/\"$/ resume_offset=$(expr $SWAPFILE_PHYSICAL / $PAGESIZE)\"/" /mnt/etc/default/grub
}

secure_boot () {

	## --- Install  basic environment ---
	## Do we have shim installed? 
	${CHROOT_PREFIX} pacman -Qs shim-signed > /dev/null
	## if not... 
	if [[ $? -gt 0 ]]; then
		notify "Installing shim-signed from pre-built package.\nThis will also clone AUR git repo to ${BUILDDIR}."
		mkdir -p ${BUILDDIR}
		cd ${BUILDDIR}
		rm -r shim-signed
		git clone https://aur.archlinux.org/shim-signed.git
		cp /root/Arch_install/shim-signed-*pkg.tar.zst ${BUILDDIR}/shim-signed/
		${CHROOT_PREFIX} bash -c "pacman -U ${BUILDDIR_CHROOT}/shim-signed/shim-signed*.pkg.tar.zst"
		cd /root
	fi

	## install GRUB, we need to have it first
	cat > /mnt/etc/grub.d/sbat.csv << EOF
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,1,Free Software Foundation,grub,2.06,https://www.gnu.org/software/grub
EOF
	notify "Installing GRUB"
	${CHROOT_PREFIX} grub-install --target=x86_64-efi --efi-directory=/boot --modules=tpm --sbat /etc/grub.d/sbat.csv --bootloader-id=GRUB

	## --- Prepare shim loader ---
	## Is this needed? grub now doesnt create BOOTx64.efi
	if ! [[ -e /mnt/boot/EFI/GRUB/grubx64.efi ]]; then
		cp /mnt/boot/EFI/GRUB/BOOTx64.efi  /mnt/boot/EFI/GRUB/grubx64.efi 
	fi

	cp /mnt/usr/share/shim-signed/shimx64.efi /mnt/boot/EFI/GRUB/BOOTx64.efi  
	cp /mnt/usr/share/shim-signed/mmx64.efi /mnt/boot/EFI/GRUB/ 

	## --- EFImanager set ---
	## Check if we have shim EFI entry, if yes, rewrite
	notify "Preparing EFI boot entry"
	SHIM_ID=($(efibootmgr | grep Shim | sed 's/[^0-9]*//g'))
	for i in "${SHIM_ID[@]}"; do
		efibootmgr -b $i -B
	done

	## install boot entry 
	efibootmgr --verbose --disk ${INSTALL_PARTITION} --part 1 --create --label "Shim" --loader /EFI/GRUB/BOOTx64.efi  

	## create MoK and certs

	if ! [[ -e ${MOKDIR}/MOK.crt ]]; then
		notify "Preparing Machine Owners Key for SecureBoot"
		mkdir -p ${MOKDIR}
		openssl req -newkey rsa:4096 -nodes -keyout ${MOKDIR}/MOK.key -new -x509 -sha256 -days 3650 -subj "/CN=${HOSTNAME} Machine Owner Key" -out ${MOKDIR}/MOK.crt
		openssl x509 -outform DER -in ${MOKDIR}/MOK.crt -out ${MOKDIR}/MOK.cer
	fi

	cp ${MOKDIR}/MOK.cer /mnt/boot/EFI/GRUB/

	## Sign everything
	notify "Signing bootloader and startup image"
	${CHROOT_PREFIX} sbsign --key ${MOKDIR_CHROOT}/MOK.key --cert ${MOKDIR_CHROOT}/MOK.crt --output /boot/vmlinuz-linux /boot/vmlinuz-linux
	${CHROOT_PREFIX} sbsign --key ${MOKDIR_CHROOT}/MOK.key --cert ${MOKDIR_CHROOT}/MOK.crt --output /boot/EFI/GRUB/grubx64.efi /boot/EFI/GRUB/grubx64.efi
}

## ----------------------------------------------

## Main script flow

## make sure we are in the correct directory
cd /root

## Keymap for instalation ISO - mainly for passphrases
loadkeys ${KEYMAP}

## Lets set all the vars if we need to
if [[ -z ${INSTALL_PARTITION}  ||  -z ${USERNAME} || -z ${HOSTNAME} ]]; then set_variables; fi

net_connect

## Set time via ntp
timedatectl set-ntp true

## DEBUG - option to only mount prepared FS, for debbuging
if [[ ${ONLY_MOUNT} = true ]]; then
	mount_filesystem
	notify "Filesystems mounted, exiting."
	exit 0
fi

[[ $SKIP_CREATE_FS = true ]] || create_filesystem
[[ $SKIP_MOUNT_FS = true ]] || mount_filesystem
[[ $SKIP_SWAPFILE = true ]] || create_swapfile

## Install base system + defined utils
if ! [[ $SKIP_PACSTRAP = true ]]; then
    notify_wait "installing base system with \n 'pacstrap /mnt base linux linux-firmware ${INSTALLSW}'"
    pacstrap /mnt base linux linux-firmware ${INSTALLSW}
fi

## ---------------------------------------------
## Chroot to new install
## (we cannot chroot, so we will use ${CHROOT_PREFIX}
## ---------------------------------------------

## Enroll fido2 key to cryptsetup (if we are using one)
if ! [[ ${FIDO2_DISABLE} = true ]]; then 
    notify "Enrolling FIDO2 key for enrcrypted drive"
    ${CHROOT_PREFIX} systemd-cryptenroll --fido2-device=auto ${CRYPT_PARTITION}
    ${CHROOT_PREFIX} systemd-cryptenroll --recovery-key ${CRYPT_PARTITION}
    warn_wait "This is your recovery key.\nMake sure you dont lose this!!!"
fi

## set locales and keymap
## TODO: for locale in locases add... 
sed -i 's/^#cs_CZ.UTF-8 UTF-8/cs_CZ.UTF-8 UTF-8/ ; s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
notify "Generating Locales"
${CHROOT_PREFIX} locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP="${KEYMAP} > /mnt/etc/vconsole.conf

## update /etc/mkinitcpio.conf - add hooks
sed -i 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf

## create /etc/crypttab.initramfs , add cryptrrot by UUID
cp /mnt/etc/crypttab /mnt/etc/crypttab.initramfs
echo "cryptroot	/dev/nvme0n1p2	-	fido2-device=auto" >> /mnt/etc/crypttab.initramfs

## make initramfs
notify "generate initramfs"
${CHROOT_PREFIX} mkinitcpio -P

## disable splash (DEBUG??)
sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/ quiet//' /mnt/etc/default/grub

if [[ ${SKIP_SWAPFILE} = true || ${SKIP_HIBERNATE} = true ]]; then enable_hibernate; fi

## TODO - Ask to skip if superuser already exists
## Create user - ask for username (if not provided in variable) and password
## Need to create user before SecureBOokt because of ~/ used 
notify "Creating non-root user."
if [[ -z $(grep ${USERNAME} /mnt/etc/passwd) ]]; then
	${CHROOT_PREFIX} useradd -m -G wheel -s /bin/bash ${USERNAME}
	${CHROOT_PREFIX} passwd ${USERNAME}
fi

## install grub, config grub
## SecureBoot runs its own grub-install
if [[ ${SKIP_SECUREBOOT} = true ]]; then
    notify "Installing GRUB"
    ${CHROOT_PREFIX} grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
   secure_boot
fi
notify "Configuring GRUB"
${CHROOT_PREFIX} grub-mkconfig -o /boot/grub/grub.cfg

## we can create fstab now
## TODO - run olny once
genfstab -U /mnt >> /mnt/etc/fstab

## Settimezone and hwclock
${CHROOT_PREFIX} ln -sf /usr/shaze/zoneinfo/Europe/Prague /etc/localtime
${CHROOT_PREFIX} hwclock --systohc

## set hosntame
echo ${HOSTNAME} > /mnt/etc/hostname

## TODO - check if wheel group is already in sudoers
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers.d/wheel
chmod 0440 /mnt/etc/sudoers.d/wheel

## Disable predictable interface names
[[ -e /mnt/etc/udev/rules.d/80-net-setup-link.rules ]] || ln -s /dev/null /mnt/etc/udev/rules.d/80-net-setup-link.rules

## Enable networkmanager
## TODO - check if networkmanager exists? 
${CHROOT_PREFIX} systemctl enable NetworkManager.service

## Set lower swappiness
echo "vm.swappiness=10" > /mnt/etc/sysctl.d/99-swappiness.conf

## DEBUG - copy over the install scripts to be able to work on them in the OS
cp -r /root/Arch_install /mnt/home/${USERNAME}/
cp -r /root/.ssh /mnt/home/${USERNAME}/
USER_ID=$(grep ${USERNAME} /mnt/etc/passwd | cut -d ':' -f 4 )
chown -R ${USER_ID}:${USER_ID} /mnt/home/${USERNAME}/

## before reboot, make sure to remove old passphrase from cryptroot if using FIDO2 token.
## not yet, debuugign and token doesnt work in arch live iso... 
## DEBUG
# if ! [[ ${FIDO2_DISABLE} = true ]]; then cryptsetup luksRemoveKey ${CRYPT_PARTITION}; fi

## We should have working system, lets try to go for it. = D
reboot 
