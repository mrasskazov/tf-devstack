tls_env_files=''
if [[ "$ENABLE_TLS" == 'ipa' ]] ; then
  tls_env_files+=' -e tripleo-heat-templates/environments/contrail/contrail-tls.yaml'
  tls_env_files+=' -e tripleo-heat-templates/environments/ssl/tls-everywhere-endpoints-dns.yaml'
  tls_env_files+=' -e tripleo-heat-templates/environments/services/haproxy-public-tls-certmonger.yaml'
  tls_env_files+=' -e tripleo-heat-templates/environments/ssl/enable-internal-tls.yaml'
elif [[ "$ENABLE_TLS" == 'local' ]] ; then
  tls_env_files+=' -e contrail-tls-local.yaml'
  tls_env_files+=' -e tripleo-heat-templates/environments/contrail/endpoints-public-dns.yaml'
else
  # use names even w/o tls case
  tls_env_files+=' -e tripleo-heat-templates/environments/contrail/endpoints-public-dns.yaml'
fi
if [ -n "$SSL_CACERT" ] ; then
   tls_env_files+=' -e inject-ca.yaml'
fi

rhel_reg_env_files=''
if [[ "$ENABLE_RHEL_REGISTRATION" == 'true' && "$USE_PREDEPLOYED_NODES" != 'true' ]] ; then
  # use rhel registration options in eneabled and for non predeployed nodes.
  # for predeployed nodes registration is made in rhel_provisioning.sh
  rhel_reg_env_files+=" -e tripleo-heat-templates/environments/rhsm.yaml"
  rhel_reg_env_files+=" -e rhsm.yaml"
fi

network_env_files=''
if [[ "$ENABLE_NETWORK_ISOLATION" == true ]] ; then
  network_env_files+=' -e tripleo-heat-templates/environments/network-isolation.yaml'
  network_env_files+=' -e tripleo-heat-templates/environments/contrail/contrail-net.yaml'
else
  network_env_files+=' -e tripleo-heat-templates/environments/contrail/contrail-net-single.yaml'
fi

network_data_file=''
if [[ -n "$L3MH_CIDR" ]] ; then
  network_data_file+=" -n $(pwd)/tripleo-heat-templates/network_data_l3mh.yaml"
  network_env_files+=' -e tripleo-heat-templates/environments/contrail/ips-from-pool-l3mh.yaml'
fi

roles=''

storage_env_files=''
if [[ -n "$overcloud_ceph_instance" ]] ; then
  storage_env_files+=' -e tripleo-heat-templates/environments/ceph-ansible/ceph-ansible.yaml'
  storage_env_files+=' -e tripleo-heat-templates/environments/ceph-ansible/ceph-mds.yaml'
  roles+=" CephStorage"
fi

role_file="$(pwd)/roles_data.yaml"
if [[ -z "$overcloud_ctrlcont_instance" && -z "$overcloud_compute_instance" ]] ; then
  if [[ -z "$L3MH_CIDR" ]] ; then
    roles+=" ContrailAio"
  else
    roles+=" ContrailAioL3mh"
  fi
else
  roles+=" Controller"
  if [[ "$CONTROL_PLANE_ORCHESTRATOR" != 'operator' ]] ; then
    roles+=" ContrailController"
  else
    [[ -n "$EXTERNAL_CONTROLLER_NODES" ]] || roles+=" ContrailOperator"
  fi
  if [[ -z "$L3MH_CIDR" ]] ; then
    roles+=" Compute"
  else
    roles+=" ComputeL3mh"
  fi
fi

[[ -z "$overcloud_dpdk_instance" ]] || roles+=" ContrailDpdk"
[[ -z "$overcloud_sriov_instance" ]] || roles+=" ContrailSriov"

openstack overcloud roles generate --roles-path tripleo-heat-templates/roles -o $role_file $roles

plugin_file_suffix=''
[[ -z "$CONTROL_PLANE_ORCHESTRATOR" ]] || plugin_file_suffix="-$CONTROL_PLANE_ORCHESTRATOR"
plugin_env_file="-e tripleo-heat-templates/environments/contrail/contrail-plugins$plugin_file_suffix.yaml"

pre_deploy_nodes_env_files=''
if [[ "$USE_PREDEPLOYED_NODES" == true ]]; then
  pre_deploy_nodes_env_files+=" --disable-validations"
  pre_deploy_nodes_env_files+=" --deployed-server"
  pre_deploy_nodes_env_files+=" --overcloud-ssh-user $SSH_USER_OVERCLOUD"
  pre_deploy_nodes_env_files+=" --overcloud-ssh-key .ssh/id_rsa"
  pre_deploy_nodes_env_files+=" -e tripleo-heat-templates/environments/deployed-server-environment.yaml"
  pre_deploy_nodes_env_files+=" -e ctlplane-assignments.yaml"
  pre_deploy_nodes_env_files+=" -e hostname-map.yaml"

  if [[ -z "$overcloud_ctrlcont_instance" && -z "$overcloud_compute_instance" ]] ; then
    export OVERCLOUD_ROLES="ContrailAio"
    export ContrailAio_hosts="${overcloud_cont_prov_ip//,/ }"
  else
    export OVERCLOUD_ROLES="Controller Compute ContrailController"
    export Controller_hosts="${overcloud_cont_prov_ip//,/ }"
    export Compute_hosts="${overcloud_compute_prov_ip//,/ }"
    export ContrailController_hosts="${overcloud_ctrlcont_prov_ip//,/ }"
  fi
fi

./tripleo-heat-templates/tools/process-templates.py --clean \
  -r $role_file $network_data_file \
  -p tripleo-heat-templates/

./tripleo-heat-templates/tools/process-templates.py \
  -r $role_file $network_data_file \
  -p tripleo-heat-templates/

echo "INFO: DEPLOY OVERCLOUD COMMAND:"
echo "openstack overcloud deploy --templates tripleo-heat-templates/ \
  --stack overcloud --libvirt-type kvm \
  --roles-file $role_file $network_data_file \
  -e overcloud_containers.yaml \
  $rhel_reg_env_files \
  $pre_deploy_nodes_env_files \
  -e tripleo-heat-templates/environments/contrail/contrail-services.yaml \
  $network_env_files \
  $storage_env_files \
  $plugin_env_file \
  $tls_env_files \
  -e misc_opts.yaml \
  -e contrail-parameters.yaml \
  -e containers-prepare-parameter.yaml \
  $RHOSP_EXTRA_HEAT_ENVIRONMENTS" | tee .deploy_overcloud_command

openstack overcloud deploy --templates tripleo-heat-templates/ \
  --stack overcloud --libvirt-type kvm \
  --roles-file $role_file $network_data_file \
  -e overcloud_containers.yaml \
  $rhel_reg_env_files \
  $pre_deploy_nodes_env_files \
  -e tripleo-heat-templates/environments/contrail/contrail-services.yaml \
  $network_env_files \
  $storage_env_files \
  $plugin_env_file \
  $tls_env_files \
  -e misc_opts.yaml \
  -e contrail-parameters.yaml \
  -e containers-prepare-parameter.yaml \
  $RHOSP_EXTRA_HEAT_ENVIRONMENTS

