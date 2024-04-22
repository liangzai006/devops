#!/usr/bin/env bash

for EXTENSION_PATH in ./kse-extensions/*; do
    cluster=$(yq '.spec.clusterScheduling.placement.clusters' $EXTENSION_PATH)
    if [[ $cluster != "null" ]]; then
        echo "不为空"
        yq '.spec.clusterScheduling.placement.clusters=["host","member"]' $EXTENSION_PATH
    else
        echo "$EXTENSION_PATH:为空"
    fi
done
