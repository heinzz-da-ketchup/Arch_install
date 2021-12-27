Arch Linux reasonably secure instalation script
-----

This is a collection of scripts made to simplify installation of Arch Linux, using SecureBoot, full disk encryption (excluding `/boot`), btrfs including snapshots and swapfile hibernation, and FIDO2 token used as a master key both for LUKS (disk encryption) and PAM (linux user control). It is aimed mainly at laptops, because i don't even own a proper desktop PC.. = )\
While researching how to configure Arch linux installation in the ways i wanted, i have found out that information sources are sometimes quite chaotic, and sorting out what do I need to do for some non-standard configuration was at times a bit puzzling. I hope, that this repo can help someone (or future me) to work out the kinks and details of their own custom Arch setup.\
I have decided to write this as a practice project and it is my first bigger bash project that i've published, so please keep that in mind. = )

### Features
*Disclaimer: This tool was written mainly with MY OWN use-case in mind, and was never intended to replace distribution's installer. Please keep that in mind. = )*

- Reasonably automated Arch instalation for my/your convinience. Goal is not to make this fully unattended.
- Custom ArchISO, automatically built and containing all required files to make the installation just one command away! = )
- Security kept in mind at all th time, however this is not your tinfoil-hat paranoid Linux distro. For example FIDO2 token is not used as 2nd factor, but as a strong single-factor login tool, and so on. Security balanced with convenience.
- Working SecureBoot using Shim-signed AUR package. This is also a band-aid for unencrypted `/boot` partition.
- Btrfs with snapshots on LUKS encrypted volume and hibernate-to-swapfile.

### Planned features
- Some more sane system defaults (Firewall, USBGuard, LaptopTools and so on).
- GUI (Sway on Wayland, login manager).
- Import dotfiles from .git repository, configure as much of the OS as possible automagically.
- Optionally retrieve a backup of `/home`.
- Install packages from a backuped list.
- configure snapshots and remote backups of `/home`.

Simply, goal of this tool is to help me get most of the way of a fully configured and populated OS. We'll see how it goes. = )

## Usage

### Prepare ArchISO
Script `config_archiso.sh` should be used in a working ArchLinux environment, it uses Arch package `archiso` to build the new ISO. I haven't tested it in the basic LiveISO, but I don't see a reason it shouldn't work.
It will prepare necesary files that need `base-devel` package, specificaly `btrfs_map_physical` binary used in mapping swapfile for hibernation, and `shim-signed-*pkg.tar.zst` package built from AUR, containing a signed Shim bootloader.\
*It also copies over .ssh keys, just to make editing scripts and pushing to git easier. To Be Removed.\
For ease of development i'm also setting keymap and wireless credentials, and adding `git` package. None of that is sctrictly necessary.*\
Output is a file `/tmp/arch*iso` which you can transfer to USB stick and use to boot and install.

### Using the script
After booting to custom LiveISO, you just need to run `/root/Arch_install/install_arch_secure.sh`. It is a good idea to make sure that you have up-to-date version of the scripts by pulling the git repository.
Another option is to pre-load some useful variables like `USERNAME` or `INSTALL_PARTITION` to make the whole process more streamlined. Script is publiched with minimal possible configuration, all variables that are not provided will use sane defaults, or ask fot user input.
After the install script finishes, you can enable Secureboot and enroll your MOK.cer via Shim's helper tool. After this step, you have working basic instalation, try it out! = )
