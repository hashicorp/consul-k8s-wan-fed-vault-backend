kubectl config use-context dc2
helm delete vault-dc2
consul-k8s uninstall -auto-approve -wipe-data   
kubectl config use-context dc1
helm delete vault-dc1
consul-k8s uninstall -auto-approve -wipe-data

