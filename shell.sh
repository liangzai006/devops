#!/usr/bin/env bash

clusters=()

checkClusterStatus() {
  # 循环监听指定 Cluster 状态变化
  retry=$((5 * 60 / 5))
  currentRetry=1
  while true; do
    echo "允许重试次数：$retry----当前重试次数:$currentRetry"

    if [ $retry == $currentRetry ]; then
      echo "检查装集群状态失败，无法添加集群"
      exit 1
    fi
    # 获取 Cluster 状态
    pod_status=$(kubectl get cluster "$clusterName" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}')

    # 输出当前 Cluster 状态
    echo "Cluster 状态: $pod_status"

    # 检查 Cluster 状态是否正常
    if [ "$pod_status" == "True" ]; then
      echo "$clusterName 状态正常，添加成功"
      clusters+=("$clusterName")

      break # 中断循环
    else
      echo "Cluster 状态异常，等待一段时间后重新检查"
      sleep 5 # 等待一段时间后重新检查
    fi
    ((currentRetry++))
  done

}

enableExtensions() {

  if [[ ! -d "${1}extensions" ]]; then
    mkdir "${1}extensions"
  fi

  if [[ ! -f "${1}extensions/kustomization.yaml" || ${EXTENSION_KUSTOMIZE_COPY} == true ]]; then
    if [[ ! -f "kse-extensions/kustomization.yaml" ]]; then
      echo "检测到缺少kustomization.yaml文件，请将kustomization.yaml文件放置kse-extensions目录下或放置${1}extensions目录下"
      exit 1
    fi

    cp kse-extensions/kustomization.yaml "${1}extensions/kustomization.yaml"

  fi

  yq ".resources" "${1}extensions/kustomization.yaml" | while IFS= read -r reource; do
    resourceName=$(echo "$reource" | sed "s/- //")

    if [[ ${EXTENSION_COPY} == true || ! -f "${1}extensions/${resourceName}" ]]; then
      cp kse-extensions/${resourceName} "${1}extensions/${resourceName}"
      echo "备份扩展组件： kse-extensions/${resourceName} >>> ${1}extensions/${resourceName}"
    fi

  done

  yq '.patches=[]' -i "${1}extensions/kustomization.yaml"

  patchCluster=""
  for c in "${clusters[@]}"; do
    patchCluster+="$c,"
  done

  yq ' .patches = [{"target":{"kind":"InstallPlan","annotationSelector": "kubesphere.io/installation-mode=Multicluster"},"patch":"- op: replace\n  path: /spec/clusterScheduling/placement/clusters\n  value: ['${patchCluster%","}']"}]' -i "${1}extensions/kustomization.yaml"

  kustomize build "${1}extensions" -o "${1}extension_deploy_config.yaml"

  kubectl apply -f "${1}extension_deploy_config.yaml"

  items=$(kubectl get -f "${1}extension_deploy_config.yaml" | grep -vc NAME)
  if [[ $items -ge 2 ]]; then
    extensionNames=$(kubectl get -f "${1}extension_deploy_config.yaml" -o jsonpath='{.items[*].metadata.name}')
  else
    extensionNames=$(kubectl get -f "${1}extension_deploy_config.yaml" -o jsonpath='{.metadata.name}')

  fi

  while true; do
    waitNum=0
    for name in ${extensionNames[*]}; do
      clusterSchedulingStatuses=$(kubectl get installplan "$name" -o yaml)

      for c in "${clusters[@]}"; do
        placement=$(echo "$clusterSchedulingStatuses" | yq '.spec.clusterScheduling.placement.clusters')
        if [[ $placement != "null" ]]; then
          planStatus=$(echo "$clusterSchedulingStatuses" | yq ".status.clusterSchedulingStatuses.$c.state")
        else
          planStatus=$(echo "$clusterSchedulingStatuses" | yq ".status.state")
        fi
        echo "${c}:集群${name}状态为：$planStatus "
        if [[ "$planStatus" != "Installed" ]]; then
          ((waitNum += 1))
        fi
      done
    done

    if [[ $waitNum == 0 ]]; then
      echo "安装完成"
      break
    fi
    sleep 3
  done

}

applyCluster() {

  for KS_CLUSTER in "${1}"deployCluster/*; do

    clusterName=$(echo "$KS_CLUSTER" | sed 's/.*\///; s/\.yaml$//')

    if [[ ${CLEAR_DEPLOY_CLUSTER} == true ]]; then
      if [[ ! -f "${1}kubeconfig/${clusterName}.yaml" ]]; then
        echo "${clusterName} KubeConfig不存在，将清理集群资源"
        kubectl delete -f "${KS_CLUSTER}"
        rm "${KS_CLUSTER}"
        continue
      fi
    fi
    checkName=$(kubectl get cluster "$clusterName" -o name 2>/dev/null)
    if [[ -z "$checkName" ]]; then
      echo "${clusterName}集群不存在"
      kubectl apply -f "$KS_CLUSTER"
    else
      echo "$clusterName 集群已存在"

    fi

    checkClusterStatus

  done

}

generateCluster() {
  TESTPATH="${1}kubeconfig"
  if [[ ! -d $TESTPATH ]]; then
    echo "${TESTPATH}目录不存在"
    exit 1
  fi
  for KUBECONFIG_PATH in ${TESTPATH}/*; do

    clusterName=$(echo "$KUBECONFIG_PATH" | sed 's/.*\///; s/\.yaml$//')

    kubeconfigBase64=$(cat $KUBECONFIG_PATH | base64 | tr -d "\r" | tr -d "\n")

    if [[ ! -d "${1}deployCluster" ]]; then
      echo "目录不存在,创建${1}deployCluster目录"
      mkdir "${1}deployCluster"
    fi

    if [[ ! -f "${1}deployCluster/$clusterName.yaml" ]]; then
      echo "文件不存在,创建${1}deployCluster/$clusterName.yaml"
      touch "${1}deployCluster/$clusterName.yaml"
      yq '.apiVersion="cluster.kubesphere.io/v1alpha1" | .kind="Cluster" | .metadata.name="'$clusterName'"  | .metadata.labels={"kubesphere.io/managed": "true"} | .spec.joinFederation=true|
                    with(.spec.connection; .type="direct" | .kubeconfig="'$kubeconfigBase64'")' -i "${1}deployCluster/$clusterName.yaml"
    else
      echo "存在${1}deployCluster/$clusterName.yaml文件"
    fi

  done

}

if [[ ${NOT_DEPLOY_HOST} != true ]]; then
  clusters+=("host")
fi

DEPLOY_PATH=${DEPLOY_PATH:-$1}

if [[ -n "${DEPLOY_PATH}" ]]; then

  last_char="${DEPLOY_PATH: -1}" # 获取字符串的最后一位字符

  if [ "$last_char" != "/" ]; then
    DEPLOY_PATH="${DEPLOY_PATH}/" # 添加斜杠到字符串末尾
  fi

  if [[ ! -d $DEPLOY_PATH ]]; then
    echo "${DEPLOY_PATH}目录不存在"
    exit 1
  fi
fi

generateCluster "${DEPLOY_PATH}"
applyCluster "${DEPLOY_PATH}"
enableExtensions "${DEPLOY_PATH}"
