#!/bin/bash

# This script will create and fire up a standard debian buster lxc container on your Proxmox VE.
# On a Proxmox cluster, the script will create the container on the local node, where it's executed.
# The container ID will be automatically assigned by increasing (+1) the highest number of
# existing LXC containers in your environment. If the assigned ID is already taken by a VM
# or no containers exist yet, the script falls back to the ID 100.

# Authors:
# (C) 2021 Idea an concept by Christian Zengel <christian@sysops.de>
# (C) 2021 Script design and prototype by Markus Helmke <m.helmke@nettwarker.de>
# (C) 2021 Script rework and documentation by Thorsten Spille <thorsten@spille-edv.de>

# IMPORTANT NOTE:
# Please adjust th settings in 'zamba.conf' to your needs before running the script

############### ZAMBA INSTALL SCRIPT ###############

# Load configuration file
source $PWD/zamba.conf

LXC_MP="0"
LXC_UNPRIVILEGED="1"
LXC_NESTING="0"

i=0

while [ $i -le 0 ]; do
  opt=$(
    whiptail --title "Operative Systems" --menu "Make your choice" 16 100 9 \
      "zmb-standalone" " ZAMBA Server standalone " \
      "zmb-ad" " ZAMBA Server active directory controller" \
      "zmb-member" " ZAMBA Server active directory member" \
      "mailpiler" " Mailpiler open source email archiving solution" \
      "matrix" " Matrix chat server and element web service" \
      "debian-unpriv" " Debian-only LXC container unprivileged mode " \
      "debian-priv" " Debian-only LXC container privileged mode" 3>&1 1>&2 2>&3
  )
  exitstatus=$?
  if [ $exitstatus != 0 ]; then
    exit
  fi
  result="Configuring LXC container '$opt'!"
  case $opt in
  "zmb-standalone")
    LXC_MP="1"
    LXC_UNPRIVILEGED="0"
    ;;
  "zmb-ad")
    LXC_NESTING="1"
    LXC_UNPRIVILEGED="0"
    ;;
  "zmb-member")
    LXC_MP="1"
    LXC_UNPRIVILEGED="0"
    ;;
  "mailpiler")
    result="Configuring LXC container for '$opt'!"
    LXC_NESTING="1"
    ;;
  "matrix")
    opt=""
    result="Install Matrix chat server and element web service"
    ;;
  "debian-unpriv")
    result="Debian-only LXC container unprivileged mode selected"
    ;;
  "debian-priv")
    result="Debian-only LXC container privileged mode selected"
    LXC_UNPRIVILEGED="0"
    ;;
  esac

  if whiptail --yesno "$result" 8 60; then
    ((i++))
  fi
done

# CHeck is the newest template available, else download it.
DEB_LOC=$(pveam list $LXC_TEMPLATE_STORAGE | grep debian-10-standard | cut -d'_' -f2)
DEB_REP=$(pveam available --section system | grep debian-10-standard | cut -d'_' -f2)


if [[ $DEB_LOC == $DEB_REP ]]; then
  echo "Newest Version of Debian 10 Standard $DEP_REP exists."
else
  echo "Will now download newest Debian 10 Standard $DEP_REP."
  pveam download $LXC_TEMPLATE_STORAGE debian-10-standard_$DEB_REP\_amd64.tar.gz
fi

# Get next free LXC-number
LXC_LST=$(lxc-ls | egrep -o '.{1,5}$')
LXC_CHK=$((LXC_LST + 1))

if [ $LXC_CHK -lt 100 ] || [ -f /etc/pve/qemu-server/$LXC_CHK.conf ]; then
  LXC_NBR=$(pvesh get /cluster/nextid)
else
  LXC_NBR=$LXC_CHK
fi
echo "Will now create LXC Container $LXC_NBR!"

# Create the container
pct create $LXC_NBR -unprivileged $LXC_UNPRIVILEGED $LXC_TEMPLATE_STORAGE:vztmpl/debian-10-standard_$DEB_REP\_amd64.tar.gz -rootfs $LXC_ROOTFS_STORAGE:$LXC_ROOTFS_SIZE
sleep 2

# Check vlan configuration
if [[ $LXC_VLAN != "" ]]; then
  VLAN=",tag=$LXC_VLAN"
else
  VLAN=""
fi

# Reconfigure conatiner
pct set $LXC_NBR -memory $LXC_MEM -swap $LXC_SWAP -hostname $LXC_HOSTNAME \-nameserver $LXC_DNS -searchdomain $LXC_DOMAIN -onboot 1 -timezone $LXC_TIMEZONE -features nesting=$LXC_NESTING -net0 name=eth0,bridge=$LXC_BRIDGE,firewall=1,gw=$LXC_GW,ip=$LXC_IP,type=veth$VLAN
sleep 2

if [ $LXC_MP -gt 0 ]; then
  pct set $LXC_NBR -mp0 $LXC_SHAREFS_STORAGE:$LXC_SHAREFS_SIZE,mp=/$LXC_SHAREFS_MOUNTPOINT
fi
sleep 2

PS3="Select the Server-Function: "

pct start $LXC_NBR
sleep 5
# Set the root password and key
echo "Setting root password"
echo -e "$LXC_PWD\n$LXC_PWD" | lxc-attach -n$LXC_NBR passwd
echo "Creating /root/.ssh"
lxc-attach -n$LXC_NBR mkdir /root/.ssh
echo "Copying authorized_keys"
pct push $LXC_NBR $LXC_AUTHORIZED_KEY /root/.ssh/authorized_keys
echo "Copying sources.list"
pct push $LXC_NBR ./sources.list /etc/apt/sources.list
echo "Copying zamba.conf"
pct push $LXC_NBR ./zamba.conf /root/zamba.conf
echo "Copying install script"
pct push $LXC_NBR ./$opt.sh /root/$opt.sh
echo "Install '$opt'!"
lxc-attach -n$LXC_NBR bash /root/$opt.sh

if [[ $opt == "zmb-ad" ]]; then
  pct stop $LXC_NBR
  pct set $LXC_NBR \-nameserver $(echo $LXC_IP | cut -d'/' -f 1)
  pct start $LXC_NBR
fi
