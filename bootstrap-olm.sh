#!/usr/bin/env bash
set -e

waitForCsv() {
    local namespace=$1
    local name=$2
    local displayname=$([ -z "$name" ] && echo "namespace \"$namespace\"" || echo "\"$name\"")
    local retries=50
    local jsonpath=$([ -z "$name" ] && echo "{.items[0].status.phase}" || echo "{.status.phase}")
    until [[ $retries == 0 || $new_csv_phase == "Succeeded" ]]; do
        local new_csv_phase=$(kubectl get csv -n "${namespace}" ${name} -o jsonpath="${jsonpath}" 2>/dev/null || echo "Waiting for CSV to appear")
        if [[ $new_csv_phase != "$csv_phase" ]]; then
            local csv_phase=$new_csv_phase
            echo "CSV $dispayname phase: $csv_phase"
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [ $retries == 0 ]; then
        echo "CSV $displayname failed to reach phase succeeded"
        exit 1
    fi
}

installOlm() {
    local release=${TK_OLM_VERSION:-0.15.1}
    local url=https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${release}
    local namespace=olm

    kubectl apply -f ${url}/crds.yaml
    kubectl apply -f ${url}/olm.yaml

    # wait for deployments to be ready
    kubectl rollout status -w deployment/olm-operator --namespace="${namespace}"
    kubectl rollout status -w deployment/catalog-operator --namespace="${namespace}"

    waitForCsv $namespace packageserver

    kubectl rollout status -w deployment/packageserver --namespace="${namespace}"
}

subscribeArgoCD() {
    local namespace=$1
    local spaces=8
    cat <<EOF | sed "s/^ \{$spaces\}//"
        apiVersion: v1
        kind: Namespace
        metadata:
          name: $namespace
        ---
        apiVersion: operators.coreos.com/v1
        kind: OperatorGroup
        metadata:
          name: operatorgroup
          namespace: $namespace
        spec:
          targetNamespaces:
          - $namespace
        ---
        apiVersion: operators.coreos.com/v1alpha1
        kind: Subscription
        metadata:
          name: $namespace
          namespace: $namespace
        spec:
          channel: alpha
          name: argocd-operator
          source: operatorhubio-catalog
          sourceNamespace: olm
EOF
}

installArgoCD() {
    local namespace=my-argocd-operator
    subscribeArgoCD $namespace | kubectl apply -f -
    waitForCsv $namespace
}

installOlm
installArgoCD


