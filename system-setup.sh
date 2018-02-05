#!/bin/bash
# Script for setting up the cluster after initial booting and configuration by
# CloudLab.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

# Echo all the args so we can see how this script was invoked in the logs.
echo -e "\n===== SCRIPT PARAMETERS ====="
echo $@
echo

# === Parameters decided by profile.py ===
# Local partition on NFS server that will be exported via NFS and used as a
# shared home directory for cluster users.
NFS_SHARED_HOME_EXPORT_DIR=$1
# NFS directory where remote blockstore datasets are mounted and exported via
# NFS to be shared by all nodes in the cluster.
NFS_DATASETS_EXPORT_DIR=$2
# Account in which various software should be setup.
USERNAME=$3
# Number of nodes in the cluster.
NUM_NODES=$4

# === Paarameters decided by this script. ===
# Directory where the NFS partition will be mounted on NFS clients
SHARED_HOME_DIR=/shome
# Directory where NFS shared datasets will be mounted on NFS clients
DATASETS_DIR=/datasets

# === Software dependencies that need to be installed. ===
# Common utilities
echo -e "\n===== INSTALLING COMMON UTILITIES ====="
apt-get update
apt-get --assume-yes install mosh vim tmux pdsh tree axel htop ctags
# NFS
echo -e "\n===== INSTALLING NFS PACKAGES ====="
apt-get --assume-yes install nfs-kernel-server nfs-common

# === Configuration settings for all machines ===
echo -e "\n===== SETTING SYSTEM WIDE PREFERENCES ====="
# Make vim the default editor.
cat >> /etc/profile.d/etc.sh <<EOM
export EDITOR=vim
EOM
chmod ugo+x /etc/profile.d/etc.sh

# Disable user prompting for sshing to new hosts.
cat >> /etc/ssh/ssh_config <<EOM
    StrictHostKeyChecking no
EOM

# NFS specific setup here. NFS exports NFS_SHARED_HOME_EXPORT_DIR (used as
# a shared home directory for all users), and also NFS_DATASETS_EXPORT_DIR
# (mount point for CloudLab datasets to which cluster nodes need shared access). 
if [ $(hostname --short) == "nfs" ]
then
  echo -e "\n===== SETTING UP NFS EXPORTS ON NFS ====="
  # Make the file system rwx by all.
  chmod 777 $NFS_SHARED_HOME_EXPORT_DIR

  # The datasets directory only exists if the user is mounting remote datasets.
  # Otherwise we'll just create an empty directory.
  if [ ! -e "$NFS_DATASETS_EXPORT_DIR" ]
  then
    mkdir $NFS_DATASETS_EXPORT_DIR
  fi

  chmod 777 $NFS_DATASETS_EXPORT_DIR

  # Remote the lost+found folder in the shared home directory
  rm -rf $NFS_SHARED_HOME_EXPORT_DIR/*

  # Make the NFS exported file system readable and writeable by all hosts in
  # the system (/etc/exports is the access control list for NFS exported file
  # systems, see exports(5) for more information).
  echo "$NFS_SHARED_HOME_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports
  echo "$NFS_DATASETS_EXPORT_DIR *(rw,sync,no_root_squash)" >> /etc/exports

  for dataset in $(ls $NFS_DATASETS_EXPORT_DIR)
  do
    echo "$NFS_DATASETS_EXPORT_DIR/$dataset *(rw,sync,no_root_squash)" >> /etc/exports
  done

  # Start the NFS service.
  /etc/init.d/nfs-kernel-server start

  # Give it a second to start-up
  sleep 5

  # Use the existence of this file as a flag for other servers to know that
  # NFS is finished with its setup.
  > /local/setup-nfs-done
fi

echo -e "\n===== WAITING FOR NFS SERVER TO COMPLETE SETUP ====="
# Wait until nfs is properly set up. 
while [ "$(ssh nfs "[ -f /local/setup-nfs-done ] && echo 1 || echo 0")" != "1" ]; do
  sleep 1
done

# NFS clients setup (all servers are NFS clients).
echo -e "\n===== SETTING UP NFS CLIENT ====="
nfs_clan_ip=`grep "nfs-clan" /etc/hosts | cut -d$'\t' -f1`
my_clan_ip=`grep "$(hostname --short)-clan" /etc/hosts | cut -d$'\t' -f1`
mkdir $SHARED_HOME_DIR; mount -t nfs4 $nfs_clan_ip:$NFS_SHARED_HOME_EXPORT_DIR $SHARED_HOME_DIR
echo "$nfs_clan_ip:$NFS_SHARED_HOME_EXPORT_DIR $SHARED_HOME_DIR nfs4 rw,sync,hard,intr,addr=$my_clan_ip 0 0" >> /etc/fstab

mkdir $DATASETS_DIR; mount -t nfs4 $nfs_clan_ip:$NFS_DATASETS_EXPORT_DIR $DATASETS_DIR
echo "$nfs_clan_ip:$NFS_DATASETS_EXPORT_DIR $DATASETS_DIR nfs4 rw,sync,hard,intr,addr=$my_clan_ip 0 0" >> /etc/fstab

# Move user accounts onto the shared directory. The NFS server is responsible
# for physically moving user files to shared folder. All other nodes just change
# the home directory in /etc/passwd. This avoids the problem of all servers
# trying to move files to the same place at the same time.
if [ $(hostname --short) == "nfs" ]
then
  echo -e "\n===== MOVING USERS HOME DIRECTORY TO NFS HOME ====="
  for user in $(ls /users/)
  do
    # Ensure that no processes by that user are running.
    pkill -u $user
    usermod --move-home --home $SHARED_HOME_DIR/$user $user
  done
else
  echo -e "\n===== SETTING USERS HOME DIRECTORY TO NFS HOME ====="
  for user in $(ls /users/)
  do
    # Ensure that no processes by that user are running.
    pkill -u $user
    usermod --home $SHARED_HOME_DIR/$user $user
  done
fi

# Setup password-less ssh between nodes
if [ $(hostname --short) == "nfs" ]
then
  echo -e "\n===== SETTING UP SSH BETWEEN NODES ====="
  for user in $(ls $SHARED_HOME_DIR)
  do
    ssh_dir=$SHARED_HOME_DIR/$user/.ssh
    /usr/bin/geni-get key > $ssh_dir/id_rsa
    chmod 600 $ssh_dir/id_rsa
    chown $user: $ssh_dir/id_rsa
    ssh-keygen -y -f $ssh_dir/id_rsa > $ssh_dir/id_rsa.pub
    cat $ssh_dir/id_rsa.pub >> $ssh_dir/authorized_keys
    chmod 644 $ssh_dir/authorized_keys
  done
fi

# NFS specific configuration.
if [ $(hostname --short) == "nfs" ]
then
  echo -e "\n===== RUNNING USER-SETUP SCRIPT FOR $USERNAME ====="
  # Execute all user-specific setup in user's shared folder using nfs.
  # This is to try and reduce network traffic during builds.
  sudo --login -u $USERNAME $SCRIPTPATH/user-setup.sh
fi
