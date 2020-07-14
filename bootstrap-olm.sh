#!/usr/bin/env bash
set -e

waitForCsv() {
    local namespace=$1
    local name=$2
    local showname=$([ -z "$name" ] && echo "namespace \"$namespace\"" || echo "\"$name\"")
    local jsonpath=$([ -z "$name" ] && echo "{.items[0].status.phase}" || echo "{.status.phase}")
    local retries=50
    until [[ $retries == 0 || $new_csv_phase == "Succeeded" ]]; do
        local new_csv_phase=$(kubectl get csv -n "${namespace}" ${name} -o jsonpath="${jsonpath}" 2>/dev/null || echo "Waiting for CSV to appear")
        if [[ $new_csv_phase != "$csv_phase" ]]; then
            local csv_phase=$new_csv_phase
            echo "CSV $showname phase: $csv_phase"
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [ $retries == 0 ]; then
        echo "CSV $showname failed to reach phase succeeded"
        exit 1
    fi
}

genOlmCatalogSource() {
    local namespace=$1
    local indent_spaces=8
    cat <<EOF | sed "s/^ \{$indent_spaces\}//"
        ---
        apiVersion: operators.coreos.com/v1alpha1
        kind: CatalogSource
        metadata:
          name: topkube-catalog
          namespace: $namespace
        spec:
          sourceType: grpc
          image: docker.io/topkube/catalog-server:latest
          displayName: Custom Operators
          publisher: topkube.com
EOF
}

installOlm() {
    local release=${LC_TK_OLM_VERSION:-0.15.1}
    local url=https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${release}
    local namespace=olm

    # Install OLM
    kubectl apply -f ${url}/crds.yaml
    kubectl apply -f ${url}/olm.yaml

    # Install custom catalog source
    kubectl delete catalogsource operatorhubio-catalog -n $namespace
    genOlmCatalogSource $namespace | kubectl apply -n $namespace -f -

    # Wait for deployments to be ready
    kubectl rollout status -w deployment/olm-operator --namespace="${namespace}"
    kubectl rollout status -w deployment/catalog-operator --namespace="${namespace}"
    waitForCsv $namespace packageserver
    kubectl rollout status -w deployment/packageserver --namespace="${namespace}"
}

genArgoCdSubscription() {
    local namespace=$1
    local indent_spaces=8
    cat <<EOF | sed "s/^ \{$indent_spaces\}//"
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
          source: topkube-catalog
          sourceNamespace: olm
EOF
}

DEFAULT_GIT_KNOWN_HOSTS="
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
    gitlab.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFSMqzJeV9rUzU4kWitGjeR4PWSa29SPqJ1fVkhtj3Hw9xjLVXVYrU9QlYWrOLXBpQ6KWjbjTDTdDkoohFzgbEY=
    gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf
    gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2bNKTBSpIYDEGk9KxsGh3mySTRgMtXL583qmBpzeQ+jqCMRgBqB98u3z++J1sKlXHWfM9dyhSevkMwSbhoR8XIq/U0tCNyokEi/ueaBMCvbcTHhO7FcwzY92WK4Yt0aGROY5qX2UKSeOvuP4D6TPqKF1onrSzH9bx9XUf2lEdWT/ia1NEKjunUqu1xOB/StKDHMoX4/OKyIzuS0q/T1zOATthvasJFoPrAjkohTyaDUz2LN5JoH839hViyEG82yB+MjcFV5MU3N1l1QL3cVUCh93xSaua1N85qivl+siMkPGbO5xR/En4iEY6K2XPASUEMaieWVNTRCtJ4S8H+9
    bitbucket.org ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAubiN81eDcafrgMeLzaFPsw2kNvEcqTKl/VqLat/MaB33pZy0y3rJZtnqwR2qOOvbwKZYKiEO1O6VqNEBxKvJJelCq0dTXWT5pbO2gDXC6h6QDXCaHo6pOHGPUy+YBaGQRGuSusMEASYiWunYN0vCAI8QaXnWMXNMdFP3jHAJH0eDsoiGnLPBlBp4TNm6rYI74nMzgz3B9IikW4WVK+dc8KZJZWYjAuORU3jc1c/NPskD2ASinf8v3xnfXeukU0sJ5N6m5E8VLjObPEO+mN2t/FZTMZLiFqPWc/ALSqnMnnhwrNi2rbfg/rd/IpL8Le3pSBne8+seeFVBoGqzHM9yXw==
    ssh.dev.azure.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7Hr1oTWqNqOlzGJOfGJ4NakVyIzf1rXYd4d7wo6jBlkLvCA4odBlL0mDUyZ0/QUfTTqeu+tm22gOsv+VrVTMk6vwRU75gY/y9ut5Mb3bR5BV58dKXyq9A9UeB5Cakehn5Zgm6x1mKoVyf+FFn26iYqXJRgzIZZcZ5V6hrE0Qg39kZm4az48o0AUbf6Sp4SLdvnuMa2sVNwHBboS7EJkm57XQPVU3/QpyNLHbWDdzwtrlS+ez30S3AdYhLKEOxAG8weOnyrtLJAUen9mTkol8oII1edf7mWWbWVf0nBmly21+nZcmCTISQBtdcyPaEno7fFQMDD26/s0lfKob4Kw8H
    vs-ssh.visualstudio.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7Hr1oTWqNqOlzGJOfGJ4NakVyIzf1rXYd4d7wo6jBlkLvCA4odBlL0mDUyZ0/QUfTTqeu+tm22gOsv+VrVTMk6vwRU75gY/y9ut5Mb3bR5BV58dKXyq9A9UeB5Cakehn5Zgm6x1mKoVyf+FFn26iYqXJRgzIZZcZ5V6hrE0Qg39kZm4az48o0AUbf6Sp4SLdvnuMa2sVNwHBboS7EJkm57XQPVU3/QpyNLHbWDdzwtrlS+ez30S3AdYhLKEOxAG8weOnyrtLJAUen9mTkol8oII1edf7mWWbWVf0nBmly21+nZcmCTISQBtdcyPaEno7fFQMDD26/s0lfKob4Kw8H
"

yamlBlock() {
    local indent_spaces=$1
    echo "|" # Start of block scalar
    # 1. Remove leading spaces from input
    # 2. Remove empty lines
    # 3. Indent by number of spaces specified
    sed "s/^\s*//; /^$/d; s/^/$(printf %${indent_spaces}s)/"
}

genArgoCdConfiguration() {
    local namespace=$1
    local indent_spaces=8
    local git_url=${LC_TK_GITOPS_URL}
    local git_rev=HEAD
    local git_path=core-services
    local secrets_name=argocd-git-secrets
    local git_username_sec=$([[ "$LC_TK_GITOPS_USERNAME" ]] && echo "username: $LC_TK_GITOPS_USERNAME")
    local git_username_ref=$([[ "$LC_TK_GITOPS_USERNAME" ]] && echo "usernameSecret: { name: ${secrets_name}, key: username }")
    local git_password_sec=$([[ "$LC_TK_GITOPS_PASSWORD" ]] && echo "password: $LC_TK_GITOPS_PASSWORD")
    local git_password_ref=$([[ "$LC_TK_GITOPS_PASSWORD" ]] && echo "passwordSecret: { name: ${secrets_name}, key: password }")
    local git_priv_key_sec=$([[ "$LC_TK_GITOPS_PRIV_KEY" ]] && echo "sshPrivateKey: $(echo "$LC_TK_GITOPS_PRIV_KEY" | yamlBlock $((indent_spaces + 4)) )")
    local git_priv_key_ref=$([[ "$LC_TK_GITOPS_PRIV_KEY" ]] && echo "sshPrivateKeySecret: { name: ${secrets_name}, key: sshPrivateKey }")
    local git_known_hosts=$( ([[ "$LC_TK_GITOPS_KNOWN_HOSTS" ]] && echo "$LC_TK_GITOPS_KNOWN_HOSTS" || echo "$DEFAULT_GIT_KNOWN_HOSTS" ) | yamlBlock $((indent_spaces + 4)) )
    cat <<EOF | sed "s/^ \{$indent_spaces\}//"
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: $secrets_name
          namespace: $namespace
        type: Opaque
        stringData:
          $git_username_sec
          $git_password_sec
          $git_priv_key_sec
        ---
        apiVersion: argoproj.io/v1alpha1
        kind: ArgoCD
        metadata:
          name: argocd
          namespace: $namespace
        spec:
          initialRepositories: |
            - url: $git_url
              type: git
              name: core-gitops
              $git_username_ref
              $git_password_ref
              $git_priv_key_ref
          initialSSHKnownHosts: $git_known_hosts
          repositoryCredentials: |
            - sshPrivateKeySecret:
                key: sshPrivateKey
                name: $secrets_name
              type: git
              url: $git_url
        ---
        apiVersion: argoproj.io/v1alpha1
        kind: AppProject
        metadata:
          name: core-services
          namespace: $namespace
          annotations:
            argocd.argoproj.io/sync-wave: "-1"
        spec:
          clusterResourceWhitelist:
          - group: '*'
            kind: '*'
          destinations:
          - namespace: '*'
            server: '*'
          sourceRepos:
          - '*'
        ---
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: core-services
          namespace: $namespace
        spec:
          destination:
            namespace: core-services
            server: https://kubernetes.default.svc
          project: core-services
          source:
            repoURL: $git_url
            targetRevision: $git_rev
            path: $git_path
          syncPolicy:
            automated:
              prune: false
              selfHeal: true
        ---
EOF
}

genArgoCdRoleBindingFix() {
    local namespace=$1
    local indent_spaces=8
    cat <<EOF | sed "s/^ \{$indent_spaces\}//"
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: argocd-application-controller
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: cluster-admin
          #  name: argocd-application-controller
        subjects:
        - kind: ServiceAccount
          name: argocd-application-controller
          namespace: $namespace
EOF
}

installArgoCd() {
    local namespace=my-argocd-operator
    genArgoCdSubscription $namespace | kubectl apply -f -
    waitForCsv $namespace
    kubectl rollout status -w deployment/argocd-operator --namespace="${namespace}"
    genArgoCdConfiguration $namespace | kubectl apply -f -
    # Hack - rollout status initially fails because it's called before the deployment is created
    local retries=10
    local done=
    until [[ $retries == 0 || $done ]]; do
        kubectl rollout status -w deployment/argocd-server --namespace="${namespace}" 2>/dev/null && done=yes || true
        sleep 1
        retries=$((retries - 1))
    done
    # Hack - ArgoCD operator installs with limited permissions for in-cluster operations.
    genArgoCdRoleBindingFix $namespace | kubectl apply -f -
}

# Environment variables (names with LC_* can be passed through SSH in most default configurations)
# LC_TK_OLM_VERSION
# LC_TK_GITOPS_URL
# LC_TK_GITOPS_USERNAME
# LC_TK_GITOPS_PASSWORD
# LC_TK_GITOPS_PRIV_KEY (multi-line)
# LC_TK_GITOPS_KNOWN_HOSTS (multi-line)

installOlm
installArgoCd


