#!/bin/bash

### Modify the following variables to suit your needs ###

chrootpath="/jail/chroot1"                                                                                               # Path to the chrooted environment
chrootuser="chrootuser"                                                                                                  # Username for the chrooted environment
corebinaries=(bash cat cp echo ls mkdir mv rm rmdir touch)                                                               # Basic binaries for the shell to work
binaries=(awk chmod chown crontab cut du find grep head mount nano nc passwd rsync sh sleep tail tar touch umount xterm) # Other binaries that might be useful

###

# Colors!
RED='\033[0;31m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m' # No Color

# Check if script is being run as root
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo -e "${RED}    ERROR: Please run as root.${NC}"
    echo ""
    exit 1
fi

# Check if the declared binaries are installed
for binary in "${binaries[@]}"; do
    if ! which "$binary" >/dev/null; then
        echo ""
        echo -e "${RED}    ERROR: $binary is not installed. Fix the issue and re-run the script.${NC}"
        echo ""
        exit 1
    fi
done

# Check if $chrootuser exists, exit if it does
if id -u $chrootuser >/dev/null 2>&1; then
    echo ""
    echo -e "${RED}    ERROR: User $chrootuser already exists. Fix the issue and re-run the script.${NC}"
    echo ""
    exit 1
fi

# Check if $chrootpath is a valid path
if ! [[ $chrootpath =~ ^/ ]]; then
    echo ""
    echo -e "${RED}    ERROR: $chrootpath is not a valid path. Fix the issue and re-run the script.${NC}"
    echo ""
    exit 1
fi

# If $chrootpath does not exist, create it
if ! [ -d $chrootpath ]; then
    mkdir -p $chrootpath
    echo "Creating $chrootpath..."
fi

# Create $chrootuser
useradd $chrootuser -c "Chrooted user" -s /bin/bash
echo "Creating user $chrootuser..."

# Create /dev/null, /dev/zero, /dev/random, /dev/urandom and /dev/tty
mkdir -p $chrootpath/{dev,etc,lib64,lib,bin,home}
mknod -m 666 $chrootpath/dev/null c 1 3
echo "Creating /dev/null..."
mknod -m 666 $chrootpath/dev/zero c 1 5
echo "Creating /dev/zero..."
mknod -m 666 $chrootpath/dev/random c 1 8
echo "Creating /dev/random..."
mknod -m 666 $chrootpath/dev/urandom c 1 9
echo "Creating /dev/urandom..."
mknod -m 666 $chrootpath/dev/tty c 5 0
echo "Creating /dev/tty..."
echo ""

# Set permissions and ownership for $chrootpath
chown root:root $chrootpath
chmod 0755 $chrootpath
echo "Setting permissions and ownership for $chrootpath..."

# Copy /etc/{passwd,group,bashrc} to $chrootpath/etc
cp -f /etc/{passwd,group,bashrc} $chrootpath/etc/
echo "Copying /etc/passwd, /etc/group and /etc/bashrc to $chrootpath/etc..."

# If $chrootpath/home/$chrootuser does not exist, create it
[ -d $chrootpath/home/$chrootuser ] || mkdir -p $chrootpath/home/$chrootuser
chown -R $chrootuser:$chrootuser $chrootpath/home/$chrootuser
chmod -R 0700 $chrootpath/home/$chrootuser

# Add main commands along with their libs to $chrootpath/bin
echo ""
echo "Copying core binaries to $chrootpath/bin..."
mainlib=$(ldd /bin/bash | grep -v "=>" | grep "lib" | cut -d " " -f 1 | tr -d '[:blank:]')
libtype=$(echo "$mainlib" | cut -d "/" -f 2)
cp "$mainlib" $chrootpath/"$libtype"
for binary in "${corebinaries[@]}"; do
    cp /bin/"$binary" $chrootpath/bin/
    echo "Copying /bin/$binary to $chrootpath/bin..."
    ldd /bin/"$binary" | grep "=> /" | awk '{print $3}' | while read -r dep; do
        if [[ $dep == /lib* ]]; then
            cp "$dep" "$chrootpath/lib/"
        elif [[ $dep == /lib64* ]]; then
            cp "$dep" "$chrootpath/lib64/"
        fi
    done
done

echo ""
echo "Copying the rest of binaries to $chrootpath/bin..."
mainlib=$(ldd /bin/bash | grep -v "=>" | grep "lib" | cut -d " " -f 1 | tr -d '[:blank:]')
libtype=$(echo "$mainlib" | cut -d "/" -f 2)
cp "$mainlib" $chrootpath/"$libtype"
for binary in "${binaries[@]}"; do
    cp /bin/"$binary" $chrootpath/bin/
    echo "Copying /bin/$binary to $chrootpath/bin..."
    ldd /bin/"$binary" | grep "=> /" | awk '{print $3}' | while read -r dep; do
        if [[ $dep == /lib* ]]; then
            cp "$dep" "$chrootpath/lib/"
        elif [[ $dep == /lib64* ]]; then
            cp "$dep" "$chrootpath/lib64/"
        fi
    done
done

# Set $chrootuser's $PATH variable to include $chrootpath/bin
echo ""
echo "Setting $chrootuser's BASH envivorement..."
echo ". /etc/bashrc" >$chrootpath/home/$chrootuser/.bashrc
echo "export PATH=/bin/" >>$chrootpath/home/$chrootuser/.bashrc

# Ask the user if they want to set $chrootuser's password
echo ""
echo -e "${YEL}Do you want to set a new password for user $chrootuser? (y/n)${NC}"
read -r answer
if ! [ "$answer" = "${answer#[Yy]}" ]; then
    passwd $chrootuser
fi

# Configure SSH to jail $chrootuser
if [ -f "/etc/ssh/sshd_config" ]; then
    echo "Match User $chrootuser" >>/etc/ssh/sshd_config
    echo "    ChrootDirectory $chrootpath" >>/etc/ssh/sshd_config
    echo ""
    sshconfigured=true
else
    echo "${YEL}The SSH config file couldn't be found${NC}"
    sshconfigured=false
fi

# Determine between ssh or sshd
if systemctl is-active --quiet sshd.service; then
    sshservice_name="sshd.service"
elif systemctl is-active --quiet ssh.service; then
    sshservice_name="ssh.service"
else
    sshservice_name="unknown"
fi

# Ask the user if they want to restart the SSH daemon
if [ "$sshconfigured" = true ] && ! [ "$sshservice_name" = "unknown" ]; then
    echo ""
    echo -e "${YEL}Do you want to restart the SSH daemon? (y/n)${NC}"
    read -r answer
    if ! [ "$answer" = "${answer#[Yy]}" ]; then
        systemctl restart $sshservice_name
    fi
fi

# Done!
echo ""
echo -e "${BLU}  Done! ${NC}"
if [ "$sshconfigured" = false ]; then
    echo ""
    echo "To configure the user to be able to access via SSH do the following:"
    echo ""
    echo "1. Add the following lines to /etc/ssh/sshd_config:"
    echo "   Match User $chrootuser"
    echo "   ChrootDirectory $chrootpath"
    echo ""
    echo "2. Restart sshd:"
    echo "   systemctl restart ssh.service"
    echo ""
else
    echo ""
    echo "The user $chrootuser can now be accessed via SSH by running:"
    echo "  ssh $chrootuser@$(hostname -I)"
    echo ""
fi
exit 0
