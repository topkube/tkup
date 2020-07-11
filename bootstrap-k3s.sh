#!/bin/bash

# Copyright Marc Richarme 2020

previouslyInstalled() {
	name=$1
	k3s kubectl get helmcharts.helm.cattle.io -n kube-system $name >/dev/null 2>&1
}

getHelmInstallState() {
	name=$1
	restartcount=$(k3s kubectl get pods -n kube-system --selector=job-name=helm-install-$name -o \
		jsonpath='{.items[*].status.containerStatuses[0].restartCount}')
	statemsg=$(k3s kubectl get pods -n kube-system --selector=job-name=helm-install-$name -o \
		jsonpath='{.items[*].status.containerStatuses[0].state}')
	status=$(echo $statemsg | sed -n 's/^map\[\(\w*\):.*$/\1/p')
	reason=$(echo $statemsg | sed -n 's/^.* reason:\(\w*\).*/\1/p')
	echo $restartcount/$status/$reason
}

resetHelmInstall() {
	name=$1
	rm /var/lib/rancher/k3s/server/manifests/$name.yaml || true
	k3s kubectl delete helmcharts.helm.cattle.io -n kube-system $name || true
	# Wait until a possible previous helm install pod is removed, so we can
	# subsequenctly track the status of the new install.
	loopcount=
	status=dummy
	while [[ $status != "" && $loopcount -lt 30 ]]; do
		state=$(getHelmInstallState $name)
		restartcount=$(echo $state | cut -d/ -f1)
		status=$(echo $state | cut -d/ -f2)
		sleep 1
		((loopcount++))
	done
	if [[ $status != "" ]]; then
		echo >&2 "ERROR: Failed to clean up previous helm install of $name"
		exit 1;
	fi
}

waitHelmInstall() {
	name=$1
	echo "Waiting for installation of $name..."
	loopcount=
	restartcount=
	status=dummy
	while [[ $status != "terminated" && $restartcount -lt 1 && $loopcount -lt 30 ]]; do
		state=$(getHelmInstallState $name)
		restartcount=$(echo $state | cut -d/ -f1)
		status=$(echo $state | cut -d/ -f2)
		reason=$(echo $state | cut -d/ -f3)
		sleep 1
		((loopcount++))
	done
	if [[ $status != "terminated" || $reason != "Completed" ]]; then
		echo >&2
		echo >&2 ======
		k3s  >&2 kubectl logs job/helm-install-$name -n kube-system
		echo >&2 ======
		echo >&2
		echo >&2 "ERROR: Failed to install $name. Logs shown above."
		exit 1;
	fi
}

writeSealedSecretsManifest() {
	targetFile=/var/lib/rancher/k3s/server/manifests/sealed-secrets.yaml
	echo "Writing manifest to $targetFile"
	cat >$targetFile <<-EOF
		apiVersion: helm.cattle.io/v1
		kind: HelmChart
		metadata:
		  name: sealed-secrets
		  namespace: kube-system
		spec:
		  chart: stable/sealed-secrets
		  version: 1.10.3
		EOF
}

installSealedSecrets() {
	if previouslyInstalled "sealed-secrets"; then
		resetHelmInstall "sealed-secrets"
		k3s kubectl delete crd sealedsecrets.bitnami.com
	fi
	writeSealedSecretsManifest
	waitHelmInstall "sealed-secrets"
}

downloadArgocdChart() {
	argocdFilename=$1
	argocdUrl=https://argoproj.github.io/argo-helm/${argocdFilename}
	targetFile=/var/lib/rancher/k3s/server/static/charts/${argocdFilename}
	if [ -e "$targetFile" ]; then
		rm "$targetFile"
	fi
	echo "Downloading chart $argocdUrl as $targetFile"
	curl -sSL $argocdUrl --output "$targetFile"
}

writeArgocdManifest() {
	argocdFilename=$1
	targetFile=/var/lib/rancher/k3s/server/manifests/argocd.yaml
	echo "Writing manifest to $targetFile"
	cat >$targetFile <<-EOF
		apiVersion: helm.cattle.io/v1
		kind: HelmChart
		metadata:
		  name: argocd
		  namespace: kube-system
		spec:
		  chart: https://%{KUBERNETES_API}%/static/charts/${argocdFilename}
		  set:
		    fullnameOverride: "argocd"
		    rbac.enabled: "true"
		    ssl.enabled: "true"
		    metrics.prometheus.enabled: "true"
		    kubernetes.ingressEndpoint.useDefaultPublishedService: "true"
		EOF
}


installArgocd() {
	if previouslyInstalled "argocd"; then
		resetHelmInstall "argocd"
	fi
	argocdVersion=$(curl -s https://argoproj.github.io/argo-helm/index.yaml | sed -e '1,/^\s\+argo-cd:/d' | sed -n 's/^\s\+version: //p' | head -1)
	argocdFilename=argo-cd-${argocdVersion}.tgz
	downloadArgocdChart $argocdFilename
	writeArgocdManifest $argocdFilename
	waitHelmInstall "argocd"
}

installSealedSecrets
installArgocd

