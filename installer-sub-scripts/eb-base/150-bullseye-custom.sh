# ------------------------------------------------------------------------------
# BULLSEYE_CUSTOM.SH
# ------------------------------------------------------------------------------
set -e
source $INSTALLER/000-source

# ------------------------------------------------------------------------------
# ENVIRONMENT
# ------------------------------------------------------------------------------
MACH="$TAG-bullseye"
cd $MACHINES/$MACH

ROOTFS="/var/lib/lxc/$MACH/rootfs"

# ------------------------------------------------------------------------------
# INIT
# ------------------------------------------------------------------------------
[[ "$BULLSEYE_SKIPPED" = true ]] && exit
[[ "$DONT_RUN_BULLSEYE_CUSTOM" = true ]] && exit

echo
echo "---------------------- $MACH CUSTOM -----------------------"

# start container
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# wait for the network to be up
for i in $(seq 0 29); do
    lxc-attach -n $MACH -- ping -c1 host.loc && break || true
    sleep 2
done

# ------------------------------------------------------------------------------
# PACKAGES
# ------------------------------------------------------------------------------
# update
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive

for i in 1 2 3; do
    sleep 1
    apt -y --allow-releaseinfo-change update && sleep 3 && break
done

apt $APT_PROXY -y full-upgrade
EOS

# packages
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt $APT_PROXY -y install less tmux vim autojump
apt $APT_PROXY -y install curl dnsutils
apt $APT_PROXY -y install net-tools ngrep ncat
apt $APT_PROXY -y install htop bmon bwm-ng
apt $APT_PROXY -y install rsync bzip2 man-db ack
EOS

# ------------------------------------------------------------------------------
# ROOT USER
# ------------------------------------------------------------------------------
# shell
lxc-attach -n $MACH -- chsh -s /bin/zsh root
cp root/.bashrc $ROOTFS/root/
cp root/.vimrc $ROOTFS/root/
cp root/.zshrc $ROOTFS/root/
cp root/.tmux.conf $ROOTFS/root/

# ------------------------------------------------------------------------------
# CONTAINER SERVICES
# ------------------------------------------------------------------------------
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
