#!/usr/bin/env bash

set -u

# shellcheck disable=SC1091
source lib/logging.sh
# shellcheck disable=SC1091
source lib/common.sh


check_bm_hosts() {
    local FAILS_CHECK="${FAILS}"
    local NAME ADDRESS USER PASSWORD MAC CRED_NAME CRED_SECRET \
      BM_HOSTS BM_HOST BM_VMS BM_VMNAME BM_VM_IFACES
    NAME="${1}"
    ADDRESS="${2}"
    USER="${3}"
    PASSWORD="${4}"
    MAC="${5}"
    BM_HOSTS="$(kubectl --kubeconfig "${KUBECONFIG}" get baremetalhosts\
      -n metal3 -o json)"
    BM_VMS="$(sudo virsh list --all)"
    BM_VMNAME="${NAME//-/_}"
    # Verify BM host exists
    RESULT_STR="${NAME} Baremetalhost exist"
    echo "$BM_HOSTS" | grep -w "${NAME}"  > /dev/null
    process_status $?

    BM_HOST="$(echo "${BM_HOSTS}" | \
      jq ' .items[] | select(.metadata.name=="'"${NAME}"'" )')"

    # Verify addresses of the host
    RESULT_STR="${NAME} Baremetalhost address correct"
    equals "$(echo "${BM_HOST}" | jq -r '.spec.bmc.address')" "${ADDRESS}"

    RESULT_STR="${NAME} Baremetalhost mac address correct"
    equals "$(echo "${BM_HOST}" | jq -r '.spec.bootMACAddress')" \
      "${MAC}"

    # Verify BM host status
    RESULT_STR="${NAME} Baremetalhost status OK"
    equals "$(echo "${BM_HOST}" | jq -r '.status.operationalStatus')" \
      "OK"

    # Verify credentials exist
    RESULT_STR="${NAME} Baremetalhost credentials secret exist"
    CRED_NAME="$(echo "${BM_HOST}" | jq -r '.spec.bmc.credentialsName')"
    CRED_SECRET="$(kubectl get secret "${CRED_NAME}" -n metal3 -o json | \
      jq '.data')"
    process_status $?

    # Verify credentials correct
    RESULT_STR="${NAME} Baremetalhost password correct"
    equals "$(echo "${CRED_SECRET}" | jq -r '.password' | \
      base64 --decode)" "${PASSWORD}"

    RESULT_STR="${NAME} Baremetalhost user correct"
    equals "$(echo "${CRED_SECRET}" | jq -r '.username' | \
      base64 --decode)" "${USER}"

    # Verify the VM was created
    RESULT_STR="${NAME} Baremetalhost VM exist"
    echo "$BM_VMS "| grep -w "${BM_VMNAME}"  > /dev/null
    process_status $?

    #Verify the VMs interfaces
    BM_VM_IFACES="$(sudo virsh domiflist "${BM_VMNAME}")"
    for bridge in ${BRIDGES}; do
      RESULT_STR="${NAME} Baremetalhost VM interface ${bridge} exist"
      echo "$BM_VM_IFACES" | grep -w "${bridge}"  > /dev/null
      process_status $?
    done

    #Verify the introspection completed successfully
    RESULT_STR="${NAME} Baremetalhost introspecting completed"
    is_in "$(echo "${BM_HOST}" | jq -r '.status.provisioning.state')" \
      "ready available"

    echo ""

    return "$((FAILS-FAILS_CHECK))"
}


#Verify that a resource exists in a type
check_k8s_entity() {
  local FAILS_CHECK="${FAILS}"
  local ENTITY
  local TYPE="${1}"
  shift
  for name in "${@}"; do
    # Check entity exists
    RESULT_STR="${TYPE} ${name} created"
    ENTITY="$(kubectl --kubeconfig "${KUBECONFIG}" get "${TYPE}" "${name}" \
      -n metal3 -o json)"
    process_status $?

    # Check the replicas
    if [[ "${BMO_RUN_LOCAL}" != true ]] && [[ "${CAPBM_RUN_LOCAL}" != true ]]
    then
      RESULT_STR="${name} ${TYPE} replicas correct"
      equals "$(echo "${ENTITY}" | jq -r '.status.readyReplicas')" \
        "$(echo "${ENTITY}" | jq -r '.status.replicas')"
    fi
  done

  return "$((FAILS-FAILS_CHECK))"
}


#Verify that a resource exists in a type
check_k8s_rs() {
  local FAILS_CHECK="${FAILS}"
  local ENTITY
  for name in "${@}"; do
    # Check entity exists
    LABEL=$(echo "$name" | cut -f1 -d:);
    NAME=$(echo "$name" | cut -f2 -d:);

    ENTITY="$(kubectl --kubeconfig "${KUBECONFIG}" get replicasets \
      -l "${LABEL}"="${NAME}" -n metal3 -o json | jq '.items[0]')"
    RESULT_STR="Replica set ${NAME} created"
    differs "${ENTITY}" "null"

    # Check the replicas
    if [[ "${BMO_RUN_LOCAL}" != true ]] && [[ "${CAPBM_RUN_LOCAL}" != true ]]
    then
      RESULT_STR="${NAME} replicas correct"
      equals "$(echo "${ENTITY}" | jq -r '.status.readyReplicas')" \
        "$(echo "${ENTITY}" | jq -r '.status.replicas')"
    fi
  done

  return "$((FAILS-FAILS_CHECK))"
}


#Verify that a resource exists in a type
check_k8s_pods() {
  local FAILS_CHECK="${FAILS}"
  local ENTITY
  for name in "${@}"; do
    # Check entity exists
    LABEL=$(echo "$name" | cut -f1 -d:);
    NAME=$(echo "$name" | cut -f2 -d:);

    ENTITY="$(kubectl --kubeconfig "${KUBECONFIG}" get pods \
      -l "${LABEL}"="${NAME}" -n metal3 -o json | jq '.items[0]')"
    RESULT_STR="Pod ${NAME} created"
    differs "${ENTITY}" "null"
  done

  return "$((FAILS-FAILS_CHECK))"
}

#Verify a container is running
check_container(){
  local NAME="$1"
  RESULT_STR="Container ${NAME} running"
  sudo "${CONTAINER_RUNTIME}" ps | grep -w "$NAME$" > /dev/null
  process_status $?
  return $?
}

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
EXPTD_CRDS="baremetalhosts.metal3.io \
  clusters.cluster.k8s.io \
  machineclasses.cluster.k8s.io \
  machinedeployments.cluster.k8s.io \
  machines.cluster.k8s.io \
  machinesets.cluster.k8s.io"
EXPTD_V1ALPHA2_CRDS="clusters.cluster.x-k8s.io \
  kubeadmconfigs.bootstrap.cluster.x-k8s.io \
  kubeadmconfigtemplates.bootstrap.cluster.x-k8s.io \
  machinedeployments.cluster.x-k8s.io \
  machines.cluster.x-k8s.io \
  machinesets.cluster.x-k8s.io \
  baremetalclusters.infrastructure.cluster.x-k8s.io \
  baremetalhosts.metal3.io \
  baremetalmachines.infrastructure.cluster.x-k8s.io \
  baremetalmachinetemplates.infrastructure.cluster.x-k8s.io"
EXPTD_STATEFULSETS="cluster-api-controller-manager \
  cluster-api-provider-baremetal-controller-manager"
EXPTD_DEPLOYMENTS="metal3-baremetal-operator"
EXPTD_RS="name:metal3-baremetal-operator"
EXPTD_V1ALPHA2_DEPLOYMENTS="cabpk-controller-manager \
  capbm-controller-manager \
  capi-controller-manager \
  metal3-baremetal-operator"
EXPTD_V1ALPHA2_RS="control-plane:cabpk-controller-manager \
  control-plane:capbm-controller-manager \
  control-plane:cluster-api-controller-manager \
  name:metal3-baremetal-operator"
EXPTD_V1ALPHA2_PODS="control-plane:cabpk-controller-manager \
  control-plane:capbm-controller-manager \
  control-plane:cluster-api-controller-manager \
  name:metal3-baremetal-operator"
BRIDGES="provisioning baremetal"
EXPTD_CONTAINERS="httpd registry vbmc sushy-tools"

FAILS=0
BMO_RUN_LOCAL="${BMO_RUN_LOCAL:-false}"
CAPBM_RUN_LOCAL="${CAPBM_RUN_LOCAL:-false}"


# Verify networking
for bridge in ${BRIDGES}; do
  RESULT_STR="Network ${bridge} exists"
  ip link show dev "${bridge}" > /dev/null
  process_status $? "Network ${bridge} exists"
done


#Verify Kubernetes cluster is reachable
RESULT_STR="Kubernetes cluster reachable"
kubectl version > /dev/null
process_status $?
echo ""

# Verify that the CRDs exist
RESULT_STR="Fetch CRDs"
CRDS="$(kubectl --kubeconfig "${KUBECONFIG}" get crds)"
process_status $? "Fetch CRDs"

if [ "${CAPI_VERSION}" == "v1alpha2" ]; then
  for name in ${EXPTD_V1ALPHA2_CRDS}; do
    RESULT_STR="CRD ${name} created"
    echo "${CRDS}" | grep -w "${name}"  > /dev/null
    process_status $?
  done
  echo ""
elif [ "${CAPI_VERSION}" == "v1alpha1" ]; then
  for name in ${EXPTD_CRDS}; do
    RESULT_STR="CRD ${name} created"
    echo "${CRDS}" | grep -w "${name}"  > /dev/null
    process_status $?
  done
  echo ""
fi


if [ "${CAPI_VERSION}" == "v1alpha2" ]; then
  # Verify the v1alph2 Pods, Operators, Deployments, Replicasets
  iterate check_k8s_pods "${EXPTD_V1ALPHA2_PODS}"
  iterate check_k8s_entity deployments "${EXPTD_V1ALPHA2_DEPLOYMENTS}"
  iterate check_k8s_rs "${EXPTD_V1ALPHA2_RS}"
elif [ "${CAPI_VERSION}" == "v1alpha1" ]; then
  # Verify the v1alph1 Operators, Statefulsets, Deployments, Replicasets
  iterate check_k8s_entity statefulsets "${EXPTD_STATEFULSETS}"
  iterate check_k8s_entity deployments "${EXPTD_DEPLOYMENTS}"
  iterate check_k8s_rs "${EXPTD_RS}"
fi
# Verify the baremetal hosts
## Fetch the BM CRs
RESULT_STR="Fetch Baremetalhosts"
kubectl --kubeconfig "${KUBECONFIG}" get baremetalhosts -n metal3 -o json \
  > /dev/null
process_status $?

## Fetch the VMs
RESULT_STR="Fetch Baremetalhosts VMs"
sudo virsh list --all > /dev/null
process_status $?
echo ""

## Verify
while read -r name address user password mac; do
  iterate check_bm_hosts "${name}" "${address}" "${user}" \
    "${password}" "${mac}"
  echo ""
done <<< "$(list_nodes)"

# Verify that the operator are running locally
if [[ "${BMO_RUN_LOCAL}" == true ]]; then
  RESULT_STR="Baremetal operator locally running"
  pgrep "operator-sdk" > /dev/null 2> /dev/null
  process_status $?
fi
if [[ "${CAPBM_RUN_LOCAL}" == true ]]; then
  # shellcheck disable=SC2034
  RESULT_STR="CAPI operator locally running"
  pgrep -f "go run ./cmd/manager/main.go" > /dev/null 2> /dev/null
  process_status $?
fi
if [[ "${BMO_RUN_LOCAL}" == true ]] || [[ "${CAPBM_RUN_LOCAL}" == true ]]; then
  echo ""
fi

for container in ${EXPTD_CONTAINERS}; do
  iterate check_container "$container"
done


echo -e "\nNumber of failures : $FAILS"
exit "${FAILS}"
