# consul-k8s-wan-fed-vault-backend
This repo show how to configure Vault as the backend for two Consul-K8s deployed in a WAN Federation topology. 

# Pre-reqs
1. A exsiting VNET/VPC. 
   - In our example, we will use Azure VNET. 
2. Two Kubernetes Clusters. In our example, we will name them dc1 and dc2.
   - This example will use two Kubernetes cluster privided by Azure Kubernetees Service (AKS) but other Kubernetes clusters should also work.
   - In our example, we will specify the Azure CNI, which will require you to select an existing VNET for your pod IPs. 


# Deploy Vault in first Kube cluster. We have named this kube cluster: dc1

1. Set the context to your dc1 kubernetes cluster

  kubectl config use-context dc1

2. Install Vault in dev-mode to dc1

  helm install vault-dc1 -f vault-dc1.yaml hashicorp/vault --wait

3. Set variable VAULT_SERVER_HOST with the external-IP of the newly deployed Vault service.

  VAULT_SERVER_HOST=$(kubectl get svc vault-dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

4. Create Helm values file which will be used to deploy the Vault agent injector in the second kubernetes cluster, dc2. 

```
cat <<EOF >> vault-dc2.yaml
# vault-dc2.yaml
server:
  enabled: false
injector:
  enabled: true
  externalVaultAddr: http://${VAULT_SERVER_HOST}:8200
  authPath: auth/kubernetes-dc2
EOF
```
  
5. Set the context to your dc2 kubernetes cluster

  kubectl config use-context dc2
  
6. Deploy Vault agent injector to dc2
  
   helm install vault-dc2 -f vault-dc2.yaml hashicorp/vault --wait
  

# Next we configure the Vault instance with the config-vault.sh script provided
  
8. Set the permission on the config-vault.sh script file.
  
  chmod 777 config-vault.sh
  
9. Run config-vault.sh
  
  source config-vault.sh
  
  
# Now we can deploy Consul in dc1 
  
10. Set the context to your dc1 kubernetes cluster
  
  kubectl config use-context dc1
  
  
11. Deploy the primary Consul in dc1 with the consul-dc1.yaml file.
  
  helm install consul-dc1 -f consul-dc1.yaml hashicorp/consul
  
12. Confirm Consul successfully deploys:

    example:

    kubectl get pods   
    NAME                                           READY   STATUS    RESTARTS   AGE
    consul-client-8clws                            2/2     Running   0          5m30s
    consul-client-s9vpl                            2/2     Running   0          7m17s
    consul-connect-injector-7c5ff9bcb7-s4csd       2/2     Running   0          7m17s
    consul-controller-bb9bcbd85-lmnpt              2/2     Running   0          7m17s
    consul-mesh-gateway-86d96bb565-n2lq7           3/3     Running   0          7m17s
    consul-server-0                                2/2     Running   0          7m17s
    consul-webhook-cert-manager-54fb557847-cbmxl   1/1     Running   0          7m17s
    vault-dc1-0                                    1/1     Running   0          56m
    vault-dc1-agent-injector-7857998c95-784st      1/1     Running   0          56m
  
  
13. Set the MESH_GW_HOST variable to point to the Mesh Gateway's external-IP that was launched on your primary Consul deployment. 
    We will use this to deploy and connect the secondary Consul tp the primary Consul.
  
  MESH_GW_HOST=$(kubectl get svc consul-mesh-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

14. Create the Consul helm values file for your secondary Consul deployment by copy/pasting the full command below.
  
cat <<EOF >> consul-dc2.yaml
global:
  datacenter: "dc2"
  name: consul
  secretsBackend:
    vault:
      enabled: true
      consulServerRole: consul-server
      consulClientRole: consul-client
      consulCARole: consul-ca
      manageSystemACLsRole: server-acl-init
      connectCA:
        address: http://${VAULT_SERVER_HOST}:8200
        rootPKIPath: connect_root/
        intermediatePKIPath: dc2/connect_inter/
        authMethodPath: kubernetes-dc2
  tls:
    enabled: true
    enableAutoEncrypt: true
    caCert:
      secretName: "pki/cert/ca"
  federation:
    enabled: true
    primaryDatacenter: dc1
    primaryGateways:
    - ${MESH_GW_HOST}:443
  acls:
    manageSystemACLs: true
    replicationToken:
      secretName: consul/data/secret/replication
      secretKey: token
  gossipEncryption:
    secretName: consul/data/secret/gossip
    secretKey: key
server:
  replicas: 1
  serverCert:
    secretName: "pki/issue/consul-cert-dc2"
connectInject:
  replicas: 1
  enabled: true
controller:
  enabled: true
meshGateway:
  enabled: true
  replicas: 1
EOF
  
  
  
  16. Set the context to your dc2 kubernetes cluster

  kubectl config use-context dc2
  
  17. Deploy your secondary Consul
  
 helm install consul-dc2 -f consul-dc2.yaml hashicorp/consul
  
  
  
  
