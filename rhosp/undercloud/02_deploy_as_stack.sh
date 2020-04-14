#!/bin/bash -e


my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"


if [ -f ~/rhosp-environment.sh ]; then
   source ~/rhosp-environment.sh
else
   echo "File ~/rhosp-environment.sh not found"
   exit
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"


# ssh config to do not check host keys and avoid garbadge in known hosts files
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat <<EOF >~/.ssh/config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOF
chmod 644 ~/.ssh/config

cd $my_dir
export local_mtu=`/sbin/ip link show $undercloud_local_interface | grep -o "mtu.*" | awk '{print $2}'`
cat undercloud.conf.template | envsubst >~/undercloud.conf

openstack undercloud install

#Adding user to group docker
user=$(whoami)
sudo usermod -a -G docker $user

echo User "$user" has been added to group "docker". Please relogin


