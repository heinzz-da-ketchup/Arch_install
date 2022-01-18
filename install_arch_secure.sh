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

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

source ${SCRIPT_DIR}/common_functions.sh
source ${SCRIPT_DIR}/vars.sh

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

	SWAPFILE_PHYSICAL=$(${SCRIPT_DIR}/btrfs_map_physical ${SWAPFILE} | awk 'NR == 2 {print $9}')
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
		rm -r shim-signed 2>/dev/null
		git clone https://aur.archlinux.org/shim-signed.git
		cp ${SCRIPT_DIR}/shim-signed-*pkg.tar.zst ${BUILDDIR}/shim-signed/
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

set_firewall () {

    ## We need to change some rules to work with ipv6
    ## TODO - Neighbor discovery protocol - We need to know attached subnets, do i really care? 
    cp /etc/iptables/simple_firewall.rules /etc/iptables/simple_firewall_ipv6.rules
    sed -i 's/tcp-reset/icmp6-adm-prohibited/' /mnt/etc/iptables/simple_firewall_ipv6.rules
    sed -i 's/icmp-port-unreachable/icmp6-adm-prohibited/' /mnt/etc/iptables/simple_firewall_ipv6.rules
    sed -i 's/icmp-proto-unreachable/icmp6-adm-prohibited/' /mnt/etc/iptables/simple_firewall_ipv6.rules
    sed -i 's/-p icmp/-p ipv6-icmp --icmpv6-type 128 -m conntrack --ctstate NEW/' /mnt/etc/iptables/simple_firewall_ipv6.rules
    ## DHCPv6
    sed -i '/-p ipv6-icmp/s/.*/&\\\n-A INPUT -p udp --sport 547 --dport 546 -j ACCEPT/' /mnt/etc/iptables/simple_firewall_ipv6.rules
    
    ${CHROOT_PREFIX} iptables-restore < /etc/iptables/empty.rules
    ${CHROOT_PREFIX} iptables-restore < /etc/iptables/simple_firewall.rules
    ${CHROOT_PREFIX} iptables-save -f /etc/iptables/iptables.rules

    ${CHROOT_PREFIX} ip6tables-restore < /etc/iptables/empty.rules
    ${CHROOT_PREFIX} ip6tables-restore < /etc/iptables/simple_firewall_ipv6.rules
    ${CHROOT_PREFIX} ip6tables-save -f /etc/iptables/ip6tables.rules

    ${CHROOT_PREFIX} systemctl enable iptables.service
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

if ! [[ $SKIP_UCODE = true ]]; then
    if grep -q Intel /proc/cpuinfo; then
	INSTALLSW="${INSTALLSW} intel-ucode"
    elif grep -q AMD /proc/cpuinfo; then 
	INSTALLSW="${INSTALLSW} amd-ucode"
    fi
fi

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

## Enroll fido2 key to cryptsetup (if we are using one).
## To prevent duplicate entries, we first remove all fido2 tokens, then enroll new one.
if ! [[ ${FIDO2_DISABLE} = true ]]; then 
    notify "Enrolling FIDO2 key for enrcrypted drive"
    ${CHROOT_PREFIX} systemd-cryptenroll --wipe-slot=fido2 --fido2-device=auto ${CRYPT_PARTITION}
    ${CHROOT_PREFIX} systemd-cryptenroll --wipe-slot=recovery --recovery-key ${CRYPT_PARTITION}
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

if ! [[ ${SKIP_SWAPFILE} = true || ${SKIP_HIBERNATE} = true ]]; then enable_hibernate; fi

## TODO - Ask to skip if superuser already exists
## Create user - ask for username (if not provided in variable) and password
## Need to create user before SecureBoot because of ~/ used 
if ! ${CHROOT_PREFIX} id ${USERNAME} &>/dev/null; then
	notify "Creating non-root administrator user ${USERNAME}."
	${CHROOT_PREFIX} useradd -m -G wheel -s /bin/bash ${USERNAME}
	until ${CHROOT_PREFIX} passwd ${USERNAME}; do
	    warn "Password not set, try again!"
	done
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

## We can also remove 'GRUB' EFI entry, installing grub creates it automatically and we won't be using it.
GRUB_ID=($(efibootmgr | grep GRUB | sed 's/[^0-9]*//g'))
for i in "${GRUB_ID[@]}"; do
	efibootmgr -b $i -B
done

## we can create fstab now
## TODO - run olny once
genfstab -U /mnt >> /mnt/etc/fstab

## Settimezone and hwclock
## TODO - Timezone in variable? 
${CHROOT_PREFIX} ln -sf /usr/share/zoneinfo/Europe/Prague /etc/localtime
${CHROOT_PREFIX} hwclock --systohc
## Enable ntp via systemd-timesyncd.service
sed -i 's/^#Fallback/Fallback/' /mnt/etc/systemd/timesyncd.conf
${CHROOT_PREFIX} systemctl enable systemd-timesyncd.service


## set hosntame
echo ${HOSTNAME} > /mnt/etc/hostname

## Enable sudo for group `wheel`
if ! [[ -e /mnt/sudoers/wheel ]]; then
    echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers.d/wheel
    chmod 0440 /mnt/etc/sudoers.d/wheel
fi

## allowlist connected devices in UsbGuard - Mainly for Fido2 key
## TODO - Let user select which device is Fido2 key, do not allow everything
${CHROOT_PREFIX} usbguard generate-policy > /etc/usbguard/rules.conf

## Setup passwordless sudo and login with Fido2
if ! [[ ${FIDO2_DISABLE} == true ]]; then
    mkdir -p /mnt/home/${USERNAME}/.config/Yubico
    ${CHROOT_PREFIX} pamu2fcfg -o pam://${HOSTNAME} -i pam://${HOSTNAME} > /home/${USERNAME}/.config/Yubico/u2f_keys

    ## Set pam configuration
    sed -i '/auth/i auth sufficient pam_u2f.so cue origin=pam://${HOSTNAME} appid=pam://${HOSTNAME}' /mnt/etc/pam.d/login
    sed -i '/auth/i auth sufficient pam_u2f.so cue origin=pam://${HOSTNAME} appid=pam://${HOSTNAME}' /mnt/etc/pam.d/sudo
fi

## Disable predictable interface names
[[ -e /mnt/etc/udev/rules.d/80-net-setup-link.rules ]] || ln -s /dev/null /mnt/etc/udev/rules.d/80-net-setup-link.rules

## Enable networkmanager service
## TODO - check if networkmanager exists? 
${CHROOT_PREFIX} systemctl enable NetworkManager.service

## Enable periodic fstrim, screw you if you dont have ssd in 2022 >= )
${CHROOT_PREFIX} systemctl enable fstrim.timer

## Set lower swappiness
echo "vm.swappiness=10" > /mnt/etc/sysctl.d/99-swappiness.conf

## Enforce 4sec delay between failed login attempst
echo "auth optional pam_faildelay.so delay=4000000" >> /mnt/etc/pam.d/system-login

## Set basic firewall
[[ $SKIP_FIREWALL = true ]] || set_firewall

## Set Pacman mirrorlist
reflector --country Czechia,Germany,Slovakia,Austria --age 12 --number 5 --protocol https --sort rate --save /mnt/etc/pacman.d/mirrolist

## If we have specified Samba mounts, create mountpoints, store credentials and add them to the fstab
if [[ -n ${SAMBA_SHARES} ]]; then
    mkdir -p /etc/samba/credentials
    chmod 700 /etc/samba/credentials

    for Share in ${SAMBA_SHARES}; do
	Share_name=$(grep -o '[^\/]*$' <<< ${Share})

	mkdir /mnt/${Share_name}

	echo "username=${SAMBA_USER}" > /etc/samba/credentials/${Share_name}
	echo "password=${SAMBA_PW}" >> /etc/samba/credentials/${Share_name}
	chmod 600 /etc/samba/credentials/${Share_name}

	echo "${Share}	/mnt/${Share_name} _netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=10min,credentials=/etc/samba/credentials/${Share_name} 0 0" >> /etc/fstab
    done
fi

## DEBUG - copy over the install scripts to be able to work on them in the OS
cp -r ${SCRIPT_DIR} /mnt/home/${USERNAME}/
cp -r /root/.ssh /mnt/home/${USERNAME}/
USER_ID=$(grep ${USERNAME} /mnt/etc/passwd | cut -d ':' -f 4 )
chown -R ${USER_ID}:${USER_ID} /mnt/home/${USERNAME}/

## before reboot, make sure to remove old passphrase from cryptroot if using FIDO2 token.
## DEBUG - not yet, debuging and token doesnt work in arch live iso... 
# if ! [[ ${FIDO2_DISABLE} = true ]]; then ${CHROOT_PREFIX} systemd-cryptenroll --wipe-slot=password ${CRYPT_PARTITION}; fi

## We should have working system, lets try to go for it. = D
notify_wait "Installation complete, ready to reboot"
reboot 
