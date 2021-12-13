USERNAME="jhrubes"

rm -r /mnt/archiso_custom

## copy profile
cp -r /usr/share/archiso/configs/releng /mnt/archiso_custom

## copy over .ssh and Arch_install dirs
mkdir /mnt/archiso_custom/airootfs/root/.ssh
cp -r /home/${USERNAME}/.ssh/id_ed25519 /mnt/archiso_custom/airootfs/root/.ssh/
cp -r /home/${USERNAME}/Arch_install /mnt/archiso_custom/airootfs/root/

## set permissions 
sed -i '$d' /mnt/archiso_custom/profiledef.sh
echo '  ["/root/.ssh/"]="0:0:700"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/.ssh/id_ed25519"]="0:0:600"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/Arch_install/install_arch_secure.sh"]="0:0:755"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/Arch_install/btrfs_map_physical"]="0:0:755"'>> /mnt/archiso_custom/profiledef.sh
echo '  ["/root/Arch_install/config_archiso.sh"]="0:0:755"'>> /mnt/archiso_custom/profiledef.sh
echo ')' >> /mnt/archiso_custom/profiledef.sh

## set keymap
echo "KEYMAP=cz-qwertz" >> /mnt/archiso_custom/airootfs/vconsole.conf

## set wifi
mkdir -p /mnt/archiso_custom/airootfs/var/lib/iwd
echo "[Security]" >> /mnt/archiso_custom/airootfs/var/lib/iwd/CabinLove.psk
echo "Passphrase=NebudouMitStenata" >> /mnt/archiso_custom/airootfs/var/lib/iwd/CabinLove.psk

## add git package
echo "git" >> /mnt/archiso_custom/packages.x86_64

## build archiso
mkarchiso -v -w /tmp/archiso-tmp -o /tmp /mnt/archiso_custom
