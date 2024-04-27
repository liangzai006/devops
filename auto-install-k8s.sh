#!/usr/bin/env bash

sshpass -p "123456" ssh root@172.31.73.183  -o StrictHostKeyChecking=no  "

set -ex

if ! command -v kk &>/dev/null; then
  if [[ ! -f \"./kk\" ]]; then
    echo \"kk 不存在\"
    curl  -fL  'https://get-kk.kubesphere.io' | sh -
  fi
  mv ./kk /usr/local/bin/kk
fi

kk init os



kk create cluster --with-local-storage -y



kubectl get nodes

kubectl get pod -A
"