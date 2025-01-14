#!/bin/bash -xe

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/common.sh"
source "$my_dir/../common/functions.sh"

TF_HELM_URL=${TF_HELM_URL:-https://github.com/tungstenfabric/tf-helm-deployer}
deployer_image=tf-helm-deployer-src
deployer_dir=${WORKSPACE}/tf-helm-deployer

if [ "$ORCHESTRATOR" == "kubernetes" ]; then
  TF_CHART="contrail-k8s"
else
  TF_CHART="contrail"
fi

fetch_deployer $deployer_image $deployer_dir || git clone "$TF_HELM_URL" $deployer_dir

# label nodes
label_nodes_by_ip opencontrail.org/vrouter-kernel=enabled $AGENT_NODES
if [ "$ORCHESTRATOR" == "kubernetes" ]; then
  label_nodes_by_ip opencontrail.org/vrouter-kernel=enabled $CONTROLLER_NODES
fi

cd $WORKSPACE/tf-helm-deployer

if [ "$ORCHESTRATOR" == "kubernetes" ]; then
  helm init -c --stable-repo-url=https://charts.helm.sh/stable

  # install plugin to make helm work without CNI
  kubectl -n kube-system scale deployment tiller-deploy --replicas=0
  helm plugin install https://github.com/rimusz/helm-tiller || :
  helm tiller stop >/dev/null &2>&1 || :
  export HELM_HOST=127.0.0.1:44134
  helm tiller start-ci
fi

function kill_helm_serve() {
  if [ "$ORCHESTRATOR" == "kubernetes" ]; then
    helm tiller stop >/dev/null &2>&1 || :
    (pgrep -f "helm serve" | xargs -n1 -r kill) || :
  elif [[ $ORCHESTRATOR == "openstack" ]] ; then
    sudo -H docker rm -f nginx-for-helm || :
  fi
}

function wait_vhost0_up() {
  local a=$1
  local d="$(basename $(dirname $my_dir))"
  if ! ip a | grep -q "${a}"; then
    ssh $SSH_OPTIONS ${a} "export PATH=\$PATH:/usr/sbin ; source /tmp/${d}/common/functions.sh ; wait_nic_up vhost0"
  else
    wait_nic_up vhost0
  fi
}

trap 'catch_errors' ERR
function catch_errors() {
  local exit_code=$?
  kill_helm_serve
  exit $exit_code
}

if [ "$ORCHESTRATOR" == "kubernetes" ]; then
  (pgrep -f "helm serve" | xargs -n1 -r kill) || :
  helm serve &
elif [[ $ORCHESTRATOR == "openstack" ]] ; then
  sudo -H docker rm -f nginx-for-helm || true
  sudo -H docker run --name nginx-for-helm --rm --detach -v $WORKSPACE/tf-helm-deployer/:/usr/share/nginx/html/charts -p 8879:80 nginx
fi
sleep 5
make all

# Refactor for AGENT_NODES and CONTROLLER_NODES
# Mark controller after vrouter installed
for node in $(kubectl get nodes --no-headers | cut -d' ' -f1); do
  kubectl label node --overwrite $node opencontrail.org/controller-
done

# Refactor BGP_PORT for OpenStack and Kubernetes modes
cat << EOF > $WORKSPACE/tf-devstack-values.yaml
global:
  contrail_env:
    CONTAINER_REGISTRY: ${CONTAINER_REGISTRY}
    CONTRAIL_CONTAINER_TAG: ${CONTRAIL_CONTAINER_TAG}
    CONTROLLER_NODES: "$(echo $CONTROLLER_NODES | tr ' ' ',')"
    JVM_EXTRA_OPTS: "-Xms1g -Xmx2g"
    BGP_PORT: "1179"
    CONFIG_DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
    DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
    LOG_LEVEL: SYS_DEBUG
    VROUTER_ENCRYPTION: FALSE
    ANALYTICS_ALARM_ENABLE: TRUE
    ANALYTICS_SNMP_ENABLE: TRUE
    ANALYTICSDB_ENABLE: TRUE
    CLOUD_ORCHESTRATOR: $ORCHESTRATOR
  node:
    host_os: $DISTRO
EOF

if [ "$DISTRO" == "centos" ]; then
  [[ $(sudo service firewalld stop) ]] || true
  # Determine kuberenetes dns and add it with searchdomains to dhclient.conf
  # because NetworkManager in centos rewrites resolv.conf
  k8s_dns=$(kubectl get services -n kube-system | grep dns | awk '{print $3}')
  sudo touch /etc/dhcp/dhclient.conf
  if [[ -z $(sudo grep "$k8s_dns" /etc/dhcp/dhclient.conf) ]]; then
    echo "prepend domain-name-servers $k8s_dns;" | sudo tee -a /etc/dhcp/dhclient.conf
    echo "prepend domain-search \"default.svc.cluster.local\", \"svc.cluster.local\";" | sudo tee -a /etc/dhcp/dhclient.conf
  fi
else
  host_var=""
fi

kubectl create ns tungsten-fabric || :
helm upgrade --install --namespace tungsten-fabric tungsten-fabric $WORKSPACE/tf-helm-deployer/$TF_CHART -f $WORKSPACE/tf-devstack-values.yaml $host_var
if [[ $ORCHESTRATOR == "openstack" ]] ; then
  for machine in $AGENT_NODES ; do
    wait_vhost0_up $machine
  done

  # upgrade of neutron and nova containers with tf ones
  helm upgrade neutron $WORKSPACE/openstack-helm/neutron --namespace=openstack --force --reuse-values \
    --set images.tags.tf_neutron_init=$CONTAINER_REGISTRY/contrail-openstack-neutron-init:${CONTRAIL_CONTAINER_TAG}
  helm upgrade nova $WORKSPACE/openstack-helm/nova --namespace=openstack --force --reuse-values \
    --set images.tags.tf_compute_init=$CONTAINER_REGISTRY/contrail-openstack-compute-init:${CONTRAIL_CONTAINER_TAG}
fi

# multinodes "wait_nic_up vhost0"
for machine in $CONTROLLER_NODES ; do
  if echo $AGENT_NODES | grep -q $machine ; then
    wait_vhost0_up $machine
  fi
done

label_nodes_by_ip opencontrail.org/controller=enabled $CONTROLLER_NODES

trap - ERR
kill_helm_serve

echo "TF Web UI will be available at any IP(or name) from '$CONTROLLER_NODES': https://IP:8143"
