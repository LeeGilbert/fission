#!/bin/bash

set -euo pipefail

# To be uncommented before merge, right now for testing can't be cron

#if [[ "$TRAVIS_EVENT_TYPE" -ne "cron" ]]
#then
#    exit 0
#fi

if [ ! -f ${HOME}/.kube/config ]
then
    echo "Skipping end to end tests, no cluster credentials"
    exit 0
fi

ROOT_RELPATH=$(dirname $0)/../..
pushd $ROOT_RELPATH
ROOT=$(pwd)
popd

# This will change for every new release
CURRENT_VERSION=0.6.0

source $ROOT/test/test_utils.sh
source $(dirname $0)/fixture_tests.sh

id=$(generate_test_id)
ns=f-$id
fns=f-func-$id
controllerNodeport=31234
routerNodeport=31235
pruneInterval=1
routerServiceType=ClusterIP

helmVars=functionNamespace=$fns,controllerPort=$controllerNodeport,routerPort=$routerNodeport,pullPolicy=Always,analytics=false,pruneInterval=$pruneInterval,routerServiceType=$routerServiceType

#serviceType=NodePort

dump_system_info

timeout 30 bash -c "helm_setup"

echo "Deleting old releases"
helm list -q|xargs -I@ bash -c "helm_uninstall_fission @"

# deleting ns does take a while after command is issued
while kubectl get ns| grep "fission-builder"
do
    sleep 5
done

helm install \
--name $id \
--wait \
--timeout 540 \
--set $helmVars \
--namespace $ns \
https://github.com/fission/fission/releases/download/${CURRENT_VERSION}/fission-all-${CURRENT_VERSION}.tgz

mkdir temp && cd temp && curl -Lo fission https://github.com/fission/fission/releases/download/${CURRENT_VERSION}/fission-cli-linux && chmod +x fission && sudo mv fission /usr/local/bin/ && cd .. && rm -rf temp

port_forward_services $id $routerNodeport

## Setup - create fixtures for tests

setup_fission_objects
trap "cleanup_fission_objects $id" EXIT

## Test before upgrade

upgrade_tests

## Build images for Upgrade

REPO=gcr.io/fission-ci
IMAGE=$REPO/fission-bundle
FETCHER_IMAGE=$REPO/fetcher
FLUENTD_IMAGE=gcr.io/fission-ci/fluentd
BUILDER_IMAGE=$REPO/builder
TAG=upgrade-test
PRUNE_INTERVAL=1 # Unit - Minutes; Controls the interval to run archivePruner.
ROUTER_SERVICE_TYPE=ClusterIP

build_and_push_fission_bundle $IMAGE:$TAG

build_and_push_fetcher $FETCHER_IMAGE:$TAG

build_and_push_fluentd $FLUENTD_IMAGE:$TAG

build_fission_cli

sudo mv $ROOT/fission/fission /usr/local/bin/

## Upgrade 

helmVars=image=$IMAGE,imageTag=$TAG,fetcherImage=$FETCHER_IMAGE,fetcherImageTag=$TAG,logger.fluentdImage=$FLUENTD_IMAGE,logger.fluentdImageTag=$TAG,functionNamespace=$fns,controllerPort=$controllerNodeport,routerPort=$routerNodeport,pullPolicy=Always,analytics=false,pruneInterval=$pruneInterval,routerServiceType=$routerServiceType

echo "Upgrading fission"
helm upgrade	\
 --wait			\
 --timeout 540	        \
 --set $helmVars	\
 --namespace $ns        \
 $id $ROOT/charts/fission-all

sleep 10 # Takes a few seconds after upgrade to re-create K8S objects etc.

port=8889 # Change local port as earlier bound port might not work
kubectl get pods -l svc="router" -o name --namespace $ns | \
        sed 's/^.*\///' | \
        xargs -I{} kubectl port-forward {} $port:8888 -n $ns &

export FISSION_ROUTER="127.0.0.1:"
FISSION_ROUTER+="$port"
export PATH=$ROOT/fission:$PATH

## Tests
validate_post_upgrade
upgrade_tests

## Cleanup is done by trap
