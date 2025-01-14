
function _run()
{
    cat <<EOF | ssh $ssh_opts stack@${instance_ip}
export CONTAINER_REGISTRY="$CONTAINER_REGISTRY"
export DEPLOYER_CONTAINER_REGISTRY="$DEPLOYER_CONTAINER_REGISTRY"
export CONTRAIL_CONTAINER_TAG="$CONTRAIL_CONTAINER_TAG"
export CONTRAIL_DEPLOYER_CONTAINER_TAG="$CONTRAIL_DEPLOYER_CONTAINER_TAG"
export ORCHESTRATOR="$ORCHESTRATOR"
source /etc/profile
source rhosp-environment.sh
./tf-devstack/rhosp/run.sh $@
EOF
}

function machines() {
    # dirty hack - somehow started vbmc port becomes down at time of this stage
    echo "INFO: vbmc ports status"
    sudo vbmc --no-daemon list || true
    echo "INFO: start all vbmc ports"
    sudo vbmc --no-daemon start $(vbmc --no-daemon list -c 'Domain name' -f value) || true
    _run machines
}

function tf_flavors() {
    _run tf_flavors
}

function tf_containers() {
    _run tf_containers
}

function tf_templates() {
    _run tf_templates
}

function tf_no_deploy() {
    _run tf_no_deploy
}

function tf_deploy() {
    _run tf_deploy
}

function tf() {
    _run tf
}

function wait() {
    _run wait
}

function logs() {
    _run logs
    scp $ssh_opts stack@${instance_ip}:logs.tgz logs.tgz
}

function collect_deployment_env() {
    echo "INFO: skip collect_deployment_env - nothing to do on kvm node"
}

trap on_exit EXIT

function on_exit() {
  # rm tf-devstack profile on kvm node,
  # as real profile is on undercloud
  [ -n "$TF_STACK_PROFILE" ] && [ -e $TF_STACK_PROFILE ] && rm -f $TF_STACK_PROFILE || true
  echo "DEBUG: remove $TF_STACK_PROFILE on kvm node"
}
