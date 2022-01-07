#!/bin/bash
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
## Auhtor: Jan Hrubes, 2021-2022
## ----------------------------------------------

source vars.sh
source common_functions.sh

## End on error or SIGINT- DEBUG
trap exit 1 ERR
trap exit 1 SIGINT

## ----------------------------------------------
## Main functions
## ----------------------------------------------

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

    ## Partition disk, i dont care about other partitioning schemes or encrypted /boot. Swapping to a swapfile.
    notify "Partitioning device ${INSTALL_PARTITION}"
    parted ${INSTALL_PARTITION} mklabel gpt >/dev/null
    parted ${INSTALL_PARTITION} mkpart EFI fat32 0% 512MB >/dev/null
    parted ${INSTALL_PARTITION} set 1 esp on >/dev/null
    parted ${INSTALL_PARTITION} mkpart LUKS 512MB 100% >/dev/null

    ## Prepare LUKS2 encrypted root
    notify "Preparing encrypted volume"
    if ! [[ ${FIDO2_DISABLE} = true ]]; then warn_wait "No need to set strong passphrase, it will later be replaced by FIDO2 token and recovery key"; fi
    cryptsetup luksFormat ${CRYPT_PARTITION}
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
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

## Mount all prepared filesystems.
## For now (for ever?) fully hardcoded
mount_filesystem () {

    if ! [[ -e /dev/mapper/cryptroot ]]; then
	notify "Please unlock cryptroot"
	cryptsetup open ${CRYPT_PARTITION} cryptroot
    fi

    # Create all needed mountpoints
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/boot
    mkdir -p /mnt/home
    mkdir -p /mnt/.snapshots
    mkdir -p /mnt/var/cache/pacman/pkg
    mkdir -p ${SWAPDIR}

    ## Mount all prepared partitions
    mount ${BOOT_PARTITION} /mnt/boot
    mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
    mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
    mount -o subvol=@pacman_cache /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
    mount -o subvol=@swap /dev/mapper/cryptroot ${SWAPDIR}
}

## Create swap file, same size as RAM, to enable hybernation
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

## Configure hibernation to swapfile by adding proper options to grub config.
## We need to use `btrfs_map_physical` binary to get a correct FS offset of swapfile.
enable_hibernate () {

	notify "Configuring hibernation to swapfile"

	SWAPFILE_PHYSICAL=$(/root/Arch_install/btrfs_map_physical ${SWAPFILE} | awk 'NR == 2 {print $9}')
	PAGESIZE=$(${CHROOT_PREFIX} getconf PAGESIZE)

	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/s/\"$/ resume=UUID=$(findmnt -no UUID -T ${SWAPFILE})\"/" /mnt/etc/default/grub
	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT/s/\"$/ resume_offset=$(expr $SWAPFILE_PHYSICAL / $PAGESIZE)\"/" /mnt/etc/default/grub
}

## Configure SecureBoot. We are using shim_signed from AUR, it must be prepared on installation media.
secure_boot () {

	## ----------------------------------------------
	## Install  basic environment
	## ----------------------------------------------

	## Do we have shim installed? 
	${CHROOT_PREFIX} pacman -Qs shim-signed > /dev/null
	## if not, install it. We clone the AUR git repo so that it is easier to update/maintain AUR package in the installed system. 
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

	## install GRUB, we have to use sbat (SecureBootAdvancedTargeting) and TPM module
	## via https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Shim_with_key_and_GRUB
	cat > /mnt/etc/grub.d/sbat.csv << EOF
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,1,Free Software Foundation,grub,2.06,https://www.gnu.org/software/grub
EOF
	notify "Installing GRUB"
	${CHROOT_PREFIX} grub-install --target=x86_64-efi --efi-directory=/boot --modules=tpm --sbat /etc/grub.d/sbat.csv --bootloader-id=GRUB

	## ----------------------------------------------
	## Prepare shim loader
	## ----------------------------------------------

	## DEBUG Is this needed? grub now doesnt create BOOTx64.efi
	#if ! [[ -e /mnt/boot/EFI/GRUB/grubx64.efi ]]; then
		#cp /mnt/boot/EFI/GRUB/BOOTx64.efi  /mnt/boot/EFI/GRUB/grubx64.efi 
	#fi

	cp /mnt/usr/share/shim-signed/shimx64.efi /mnt/boot/EFI/GRUB/BOOTx64.efi  
	cp /mnt/usr/share/shim-signed/mmx64.efi /mnt/boot/EFI/GRUB/ 

	## ----------------------------------------------
	## EFImanager set
	## ----------------------------------------------

	## Check if we have shim EFI entry, if yes, rewrite
	notify "Preparing EFI boot entry"
	SHIM_ID=($(efibootmgr | grep Shim | sed 's/[^0-9]*//g'))
	for i in "${SHIM_ID[@]}"; do
		efibootmgr -b $i -B
	done

	## We can also remove 'GRUB' EFI entry, installing grub creates it automatically and we won't be using it.
	GRUB_ID=($(efibootmgr | grep GRUB | sed 's/[^0-9]*//g'))
	for i in "${GRUB_ID[@]}"; do
		efibootmgr -b $i -B
	done

	## Add Shim boot entry 
	efibootmgr --verbose --disk ${INSTALL_PARTITION} --part 1 --create --label "Shim" --loader /EFI/GRUB/BOOTx64.efi  

	## ----------------------------------------------
	## create MachineOwnerKey and certs
	## ----------------------------------------------

	## We should make MOK only when it is not provided.
	## We need all of the required files tho, if any of them is missing, recreate them all
	if ! [[ -e ${MOKDIR}/MOK.crt ]] || ! [[ -e ${MOKDIR}/MOK.key ]] || ! [[ -e ${MOKDIR}/MOK.cer ]]; then
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
## ----------------------------------------------

## make sure we are in the correct directory
## DEBUG - Needed? we are using absolute paths everywhere
cd /root

## Keymap for instalation, mainly for passphrases
if ! [[ -z ${KEYMAP} ]]; then
    warn "Setting keymap to ${KEYMAP}, be carefull about your passphrases and password(s)!"
    loadkeys ${KEYMAP}
fi

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
    notify_wait "Installing base system with \n 'pacstrap /mnt base linux linux-firmware ${INSTALLSW}'"
    pacstrap /mnt base linux linux-firmware ${INSTALLSW}
    notify "Base system succesfully installed"
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
    warn_wait "This is your recovery key.\nMake sure you dont lose it!!!"
fi

## Set locales and keymap
## TODO: for locale in locases add... 
sed -i 's/^#cs_CZ.UTF-8 UTF-8/cs_CZ.UTF-8 UTF-8/ ; s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
notify "Generating Locales"
${CHROOT_PREFIX} locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP="${KEYMAP} > /mnt/etc/vconsole.conf

## Update /etc/mkinitcpio.conf - add hooks
sed -i 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf

## Create /etc/crypttab.initramfs, add cryptrrot by UUID
cp /mnt/etc/crypttab /mnt/etc/crypttab.initramfs
echo "cryptroot	${CRYPT_PARTITION}	-	fido2-device=auto" >> /mnt/etc/crypttab.initramfs

## make initramfs
notify "Generating initramfs"
${CHROOT_PREFIX} mkinitcpio -P

## disable splash (DEBUG?? Replace with some kind of prompt?)
sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/ quiet//' /mnt/etc/default/grub

if [[ ${SKIP_SWAPFILE} = true || ${SKIP_HIBERNATE} = true ]]; then enable_hibernate; fi

## TODO - Ask to skip if superuser already exists
## Create user - ask for username (if not provided in variable) and password
## Need to create user before SecureBoot because of ~/ used 
notify "Creating non-root administrator user ${USERNAME}."
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
## TODO - Timezone in variable? 
${CHROOT_PREFIX} ln -sf /usr/shaze/zoneinfo/Europe/Prague /etc/localtime
${CHROOT_PREFIX} hwclock --systohc

## set hosntame
echo ${HOSTNAME} > /mnt/etc/hostname

## TODO - check if wheel group is already in sudoers
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers.d/wheel
chmod 0440 /mnt/etc/sudoers.d/wheel

## Disable predictable interface names
[[ -e /mnt/etc/udev/rules.d/80-net-setup-link.rules ]] || ln -s /dev/null /mnt/etc/udev/rules.d/80-net-setup-link.rules

## Enable networkmanager service
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
## DEBUG - not yet, debuging and token doesnt work in arch live iso... 
# if ! [[ ${FIDO2_DISABLE} = true ]]; then cryptsetup luksRemoveKey ${CRYPT_PARTITION}; fi

## We should have working system, lets try to go for it. = D
notify_wait "Installation complete, ready to reboot"
reboot 
