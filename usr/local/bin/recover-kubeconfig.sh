#!/bin/bash

set -eou pipefail

# context
intapi=$(oc get infrastructures.config.openshift.io cluster -o "jsonpath={.status.apiServerInternalURI}")
context="$(oc config current-context)"
# cluster
cluster="$(oc config view -o "jsonpath={.contexts[?(@.name==\"$context\")].context.cluster}")"
server="$(oc config view -o "jsonpath={.clusters[?(@.name==\"$cluster\")].cluster.server}")"
# token
ca_crt_data="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token -o "jsonpath={.data.ca\.crt}" | base64 --decode)"
namespace="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token  -o "jsonpath={.data.namespace}" | base64 --decode)"
token="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token -o "jsonpath={.data.token}" | base64 --decode)"

export KUBECONFIG="$(mktemp)"
kubectl config set-credentials "kubelet" --token="$token" >/dev/null
ca_crt="$(mktemp)"; echo "$ca_crt_data" > $ca_crt
kubectl config set-cluster $cluster --server="$intapi" --certificate-authority="$ca_crt" --embed-certs >/dev/null
kubectl config set-context kubelet --cluster="$cluster" --user="kubelet" >/dev/null
kubectl config use-context kubelet >/dev/null
cat "$KUBECONFIG"
