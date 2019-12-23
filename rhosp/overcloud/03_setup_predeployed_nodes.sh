#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [ -f /home/stack/env.sh ]; then
   source /home/stack/env.sh
else
   echo "File /home/stack/env.sh not found"
   exit
fi


# RHEL Registration
set +x
if [ -f /home/stack/rhel-account.rc ]; then
   source /home/stack/rhel-account.rc
else
   echo "File home/stack/rhel-account.rc not found"
   exit
fi

#set -x
register_opts=''
[ -n "$RHEL_USER" ] && register_opts+=" --username $RHEL_USER"
[ -n "$RHEL_PASSWORD" ] && register_opts+=" --password $RHEL_PASSWORD"

attach_opts='--auto'
if [[ -n "$RHEL_POOL_ID" ]] ; then
   attach_opts="--pool $RHEL_POOL_ID"
fi

#Removing default gateway if it's defined
check_gateway=$(ip route list | grep -c default)
if (( $check_gateway > 0 )); then
   ip route delete default
   echo default gateway deleted
fi

ip route add default via ${prov_ip} dev eth0
sed -i '/nameserver/d'  /etc/resolv.conf
echo 'nameserver 8.8.8.8' >> /etc/resolv.conf


setenforce 0
sed -i "s/SELINUX=.*/SELINUX=disabled/g" /etc/selinux/config
getenforce
cat /etc/selinux/config
subscription-manager unregister || true
echo subscription-manager register ...
subscription-manager register $register_opts
subscription-manager attach $attach_opts

subscription-manager repos --disable=*
subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-rh-common-rpms --enable=rhel-ha-for-rhel-7-server-rpms --enable=rhel-7-server-openstack-13-rpms
yum update -y

yum install -y  ntp wget yum-utils vim python-heat-agent*

chkconfig ntpd on
service ntpd start

# install pip for future run of OS checks
curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
python get-pip.py
pip install -q virtualenv docker

#Auto-detect physnet MTU for cloud environments
default_iface=`ip route get 1 | grep -o "dev.*" | awk '{print $2}'`
default_iface_mtu=`ip link show $default_iface | grep -o "mtu.*" | awk '{print $2}'`

if (( ${default_iface_mtu} < 1500 )); then
  echo "{ \"mtu\": ${default_iface_mtu}, \"debug\":false }" > /etc/docker/daemon.json
fi

echo INSECURE_REGISTRY="--insecure-registry ${prov_ip}:8787" >> /etc/sysconfig/docker
systemctl restart docker

#Heat Stack will fail if INSECURE_REGISTRY is presented in the file
#so we delete it and let Heat to append this later
sed -i '$ d' /etc/sysconfig/docker


