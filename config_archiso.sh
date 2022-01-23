#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

source ${SCRIPT_DIR}/vars.sh
source ${SCRIPT_DIR}/common_functions.sh

if [[ -z ${USERNAME} ]]; then
	USERNAME=$(get_confirmed_input "username") 
fi

## Prepare packages and binary files to use
notify "Installing 'archiso'"
sudo pacman -Sy archiso

if ! [[ -e ${SCRIPT_DIR}/btrfs_map_physical  &&  $(ls -l ${SCRIPT_DIR} | grep shim-signed.*pkg.tar.zst) ]]; then
    sudo pacman -Sy base-devel
fi

## Get and build btrfs_map_physical
if ! [[ -e ${SCRIPT_DIR}/btrfs_map_physical ]]; then
	
	notify "Getting and compiling 'btrfs_map_physical' tool"

	mkdir -p ${BUILDDIR}
	mkdir -p ${BUILDDIR}/btrfs_map_physical
	cd ${BUILDDIR}/btrfs_map_physical

	curl -LO https://github.com/osandov/osandov-linux/raw/master/scripts/btrfs_map_physical.c
	gcc -O2 -o btrfs_map_physical btrfs_map_physical.c

	cp btrfs_map_physical ${SCRIPT_DIR}
	cd ${SCRIPT_DIR}
fi

## Get and makepkg for signed shim
if ! [[ $(ls -l ${SCRIPT_DIR} | grep shim-signed.*pkg.tar.zst) ]]; then
	
	notify "Getting 'shim-signed' from AUR and buildng package"

	mkdir -p ${BUILDDIR}
	cd ${BUILDDIR}
	rm -r shim-signed 2>/dev/null
	git clone https://aur.archlinux.org/shim-signed.git
	cd ${BUILDDIR}/shim-signed

	## Due dilligence
	warn_wait "Check your AUR build files!" 
	less PKGBUILD
	printf "\n"
	less shim-signed.install

	printf ${YELLOW}
	printf "Is it OK? Y/y to continue"
	printf ${NC}
	read Confirm
	if ! [[ ${Confirm} =~ y|Y ]]; then
		error "Aborting install"
	fi

	makepkg -rc

	cp ${BUILDDIR}/shim-signed/shim-signed-*pkg.tar.zst ${SCRIPT_DIR}
	cd ${SCRIPT_DIR}
fi

sudo rm -r /mnt/archiso_custom 2>/dev/null

## copy profile
sudo cp -r /usr/share/archiso/configs/releng /mnt/archiso_custom
sudo chown -R ${USERNAME}:${USERNAME} /mnt/archiso_custom

## copy over .ssh and Arch_install dirs
## DEBUG - SSH key is only for development! 
mkdir /mnt/archiso_custom/airootfs/root/.ssh
cp -r /home/${USERNAME}/.ssh/id_ed25519 /mnt/archiso_custom/airootfs/root/.ssh/
cp -r ${SCRIPT_DIR} /mnt/archiso_custom/airootfs/root/

## set permissions 
sed -i '$d' /mnt/archiso_custom/profiledef.sh
echo '  ["/root/.ssh/"]="0:0:700"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/.ssh/id_ed25519"]="0:0:600"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/Arch_install/install_arch_secure.sh"]="0:0:755"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/Arch_install/btrfs_map_physical"]="0:0:755"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/Arch_install/config_archiso.sh"]="0:0:755"'>> /mnt/archiso_custom/profiledef.sh
echo ')' >> /mnt/archiso_custom/profiledef.sh

## set keymap
echo "KEYMAP=cz-qwertz" >> /mnt/archiso_custom/airootfs/etc/vconsole.conf

## set wifi

printf ${GREEN} 
printf "\n##############################\n" 
printf "Do you want to set wifi for live ISO? y/n\n"
read Confirm
printf "##############################\n" 
if [[ ${Confirm} == 'y' || ${Confirm} == 'Y' ]]; then 
    if [[ -z ${SSID} ]]; then
	SSID=$(get_confirmed_input "Wifi SSID")
    fi
    if [[ -z ${PSK} ]]; then
	PSK=$(get_confirmed_input "Wifi Passphrase")
    fi
    mkdir -p /mnt/archiso_custom/airootfs/var/lib/iwd
    echo "[Security]" >> /mnt/archiso_custom/airootfs/var/lib/iwd/${SSID}.psk
    echo "Passphrase=${PSK}" >> /mnt/archiso_custom/airootfs/var/lib/iwd/${SSID}.psk
fi

## add git package
echo "git" >> /mnt/archiso_custom/packages.x86_64

## build archiso
sudo mkarchiso -v -w /tmp/archiso-tmp -o /tmp /mnt/archiso_custom
