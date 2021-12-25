USERNAME="jhrubes"
HOSTNAME="jhrubes-NTB"
BUILDDIR=""
MOKDIR=""
INSTALL_PARTITION="/dev/nvme0n1"

secure_boot () {

	## DONT FORGET TO ADJUST FOR ARCHISO!
	
	## --- Istall  basic environment ---
	## install base-devel and other packages
	#sudo pacman -Sy --needed base-devel sbsigntools

	## prepare build env
	if [[ -z ${BUILDDIR} ]]; then
		BUILDDIR="/home/${USERNAME}/builds"
	fi

	if [[ -z ${MOKDIR} ]]; then
		MOKDIR="/home/${USERNAME}/.mok"
	fi

	## Do we have shim installed? 
	pacman -Qs shim-signed > /dev/null
	## if not... 
	if [[ $? -gt 0 ]]; then

		mkdir -p ${BUILDDIR}
		cd ${BUILDDIR}
		git clone https://aur.archlinux.org/shim-signed.git
		cd ${BUILDDIR}/shim-signed

		## Due dilligence
		echo "check your AUR build files!" 
		less PKGBUILD
		less shim-signed.install
		echo "is it OK? Y to continue"
		read Confirm
		if ! [[ ${Confirm} =~ y|Y ]]; then
			echo "Aborting install"
			exit 1
		fi

		makepkg -sirc
	fi

	## --- Prepare shim loader ---
	if ! [[ -e /boot/EFI/GRUB/grubx64.efi ]]; then
		cp /boot/EFI/GRUB/BOOTx64.efi  /boot/EFI/GRUB/grubx64.efi 
		sudo cp /usr/share/shim-signed/shimx64.efi /boot/EFI/GRUB/BOOTx64.efi  
		sudo cp /usr/share/shim-signed/mmx64.efi /boot/EFI/GRUB/ 
	fi

	## --- EFImanager set ---
	## Check if we have shim EFI entry, if yes, remove it!
	SHIM_ID=($(efibootmgr | grep Shim | sed 's/[^0-9]*//g'))
	if [[ -n ${SHIM_ID[@]} ]]; then
		echo "Shim EFI entry exist, will not make a new one"
	else
		for i in "${SHIM_ID[@]}"; do
			sudo efibootmgr -b $i -B
		done

		## install boot entry 
		sudo efibootmgr --verbose --disk ${INSTALL_PARTITION} --part 1 --create --label "Shim" --loader /EFI/GRUB/BOOTx64.efi  
	fi

	## create MoK and certs

	if ! [[ -e ${MOKDIR}/MOK.crt ]]; then
		mkdir -p ${MOKDIR}
		openssl req -newkey rsa:4096 -nodes -keyout ${MOKDIR}/MOK.key -new -x509 -sha256 -days 3650 -subj "/CN=${HOSTNAME} Machine Owner Key" -out ${MOKDIR}/MOK.crt
		openssl x509 -outform DER -in ${MOKDIR}/MOK.crt -out ${MOKDIR}/MOK.cer
	fi

	sudo cp ${MOKDIR}/MOK.cer /boot/EFI/GRUB/

	cat > /tmp/sbat.csv << EOF
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,1,Free Software Foundation,grub,2.06,https://www.gnu.org/software/grub
EOF
	sudo cp /tmp/sbat.csv /etc/grub.d/sbat.csv
	sudo grub-install --target=x86_64-efi --efi-directory=/boot --modules=tpm --sbat /etc/grub.d/sbat.csv --bootloader-id=GRUB

	## Sign everything
	sudo sbsign --key ${MOKDIR}/MOK.key --cert ${MOKDIR}/MOK.crt --output /boot/vmlinuz-linux /boot/vmlinuz-linux
	sudo sbsign --key ${MOKDIR}/MOK.key --cert ${MOKDIR}/MOK.crt --output /boot/EFI/GRUB/grubx64.efi /boot/EFI/GRUB/grubx64.efi


}

secure_boot 
