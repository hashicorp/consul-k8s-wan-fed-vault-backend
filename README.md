# consul-k8s-wan-fed-vault-backend
This repo shows how to configure Vault as the backend for two Consul-K8s deployed in a WAN Federation topology. 

High level steps:
- Install Vault server (demo mode) in first Kube cluster (dc1) and install Vault agent in second Kube cluster (dc2).
- Configure Vault server (enable K8s Auth methods, roles, policies, etc)
- Deploy primary Consul cluster on dc1, using to values stored on Vault, like PKI engines, gossip, roles, etc.
- Deploy secondary Consul cluster on dc2, using to values stored on Vault, like PKI engines, replication tokens, roles, etc.

![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2010.21.55%20AM.png "WAN FED Topology")


# Pre-reqs
1. A exsiting VNET/VPC. 
   - In our example, we will use Azure VNET. 
2. Two Kubernetes Clusters. In our example, we will name them dc1 and dc2.
   - This example will use two Kubernetes cluster privided by Azure Kubernetees Service (AKS) but other Kubernetes clusters should also work.
   - In our example, we will specify the Azure CNI, which will require you to select an existing VNET for your pod IPs. 
3. You will need to have Consul installed locally if you want to run the config-vault.sh script provided from your local machine. The reason is because the script will run the **consul keygen** command which requires Consul. It will then store the output of the command onto a Vault KV store. 
 
If you do not have Consul installed locally, you can edit the config-vault.sh script to explicitly set the gossip key:
```
vault kv put consul/secret/gossip key="<YOUR_GOSSIP_KEY>"
```


# Deploy Vault in first Kube cluster. We have named this kube cluster: dc1

1. Set the context to your **dc1** kubernetes cluster

```kubectl config use-context dc1```

2. Install Vault in dev-mode to dc1

```helm install vault-dc1 -f vault-dc1.yaml hashicorp/vault --wait```

3. Set variable VAULT_SERVER_HOST with the external-IP of the newly deployed Vault service.

```VAULT_SERVER_HOST=$(kubectl get svc vault-dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')```

4. Check and confirm the VAULT_SERVER_HOST variable matches the Vault server's external IP address.
```
echo $VAULT_SERVER_HOST

kubectl get svc vault-dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

6. Create Helm values file which will be used to deploy the Vault agent injector in the second kubernetes cluster, dc2. 

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
  
5. Set the context to your **dc2** kubernetes cluster

```kubectl config use-context dc2```
  
6. Deploy Vault agent injector to dc2

```helm install vault-dc2 -f vault-dc2.yaml hashicorp/vault --wait```
  

# Next we configure the Vault instance with the config-vault.sh script provided
  
8. Set the permission on the config-vault.sh script file.
  
```chmod 777 config-vault.sh```
  
9. Run config-vault.sh
  
```source config-vault.sh```
  
10. Vault should now be configured. Log onto your Vault server to confirm the consul/ and pki engines show appear.

   ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2011.48.54%20AM.png)

   Confirm the Consul gossip and replication secrets are located in the **consul/** secrets engine.
   
  ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2012.04.55%20PM.png)
   
   Confirm the Consul Agent CA's certificate also appears in the **pki** secrets engine. It should say **Consul CA**.
   
  ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2012.11.07%20PM.png)
  
  
# Now we can deploy Consul in dc1 
  
11. Set the context to your **dc1** kubernetes cluster
  
```kubectl config use-context dc1```
  
  
11. Deploy the primary Consul in dc1 with the consul-dc1.yaml file.
  
```helm install consul-dc1 -f consul-dc1.yaml hashicorp/consul```
  
12. Confirm the primary Consul in dc1 successfully deploys. This may take a few minutes to fully complete. You may see the consul-mesh-gateway pod error out a couple of times before it successfully launches. This is expected.

    example:
```
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
```  
  
  
13. On your Vault server UI, you should see additional **connect_root** and **dc1/connect_inter/** secrets engines appear.
  ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/connect-root-pki.png)
  
  To check that the Connect CA certificates on Vault matches with Connect CA certificates used on your Consul deployment, you can compare the two certificates in the **connect_root** UI page with the certificates returned from when querying the Consul server API.

   On Vault UI, click on one of the certiificates links and view the certificate.
   ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2012.37.52%20PM.png)

   On Consul:
   ```
   kubectl exec consul-server-0 -- curl --cacert /vault/secrets/serverca.crt -v https://localhost:8501/v1/agent/connect/ca/roots | jq
   ```


14. Set the MESH_GW_HOST variable to point to the Mesh Gateway's external-IP that was launched on your primary Consul deployment. 
    We will use this to deploy and connect the secondary Consul tp the primary Consul.
  
```
MESH_GW_HOST=$(kubectl get svc consul-mesh-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

14. Create the Consul helm values file for your secondary Consul deployment by copy/pasting the full command below.
```  
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
```  
  
  
  16. Set the context to your **dc2** kubernetes cluster

```kubectl config use-context dc2```
  
  17. Deploy your secondary Consul
  
```helm install consul-dc2 -f consul-dc2.yaml hashicorp/consul```
  
  18. Confirm the primary Consul in dc2 successfully deploys. This may take a few minutes to fully complete. 
  
  example
```kubectl get pods
NAME                                           READY   STATUS    RESTARTS   AGE
consul-client-g44r5                            2/2     Running   0          106s
consul-client-r7nn8                            2/2     Running   0          106s
consul-client-smz85                            2/2     Running   0          106s
consul-connect-injector-8c87566f-l87fd         2/2     Running   0          106s
consul-controller-5d6fc5cdf9-wkflq             2/2     Running   0          106s
consul-mesh-gateway-7cd99d4bc-kbb25            3/3     Running   0          106s
consul-server-0                                2/2     Running   0          106s
consul-webhook-cert-manager-7d55c485b7-zgh6q   1/1     Running   0          106s
vault-dc2-agent-injector-549bf89c5c-zvm8w      1/1     Running   0          8m32s
```

19. Retreive external-ip of primary Consul UI. 

example:
```
kubectl get service --context dc1
NAME                           TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)                                                                   AGE
consul-connect-injector        ClusterIP      10.0.57.134    <none>           443/TCP                                                                   8m22s
consul-controller-webhook      ClusterIP      10.0.57.73     <none>           443/TCP                                                                   8m22s
consul-dns                     ClusterIP      10.0.241.253   <none>           53/TCP,53/UDP                                                             8m22s
consul-mesh-gateway            LoadBalancer   10.0.136.150   52.249.210.137   443:31601/TCP                                                             8m22s
consul-server                  ClusterIP      None           <none>           8501/TCP,8301/TCP,8301/UDP,8302/TCP,8302/UDP,8300/TCP,8600/TCP,8600/UDP   8m22s
consul-ui                      LoadBalancer   10.0.252.71    52.249.210.131   443:31869/TCP                                                             8m22s
kubernetes                     ClusterIP      10.0.0.1       <none>           443/TCP                                                                   17m
vault-dc1                      LoadBalancer   10.0.40.164    52.226.54.128    8200:30420/TCP,8201:31193/TCP                                             12m
```
Then log into primary Consul UI to confirm both dc1 and dc1 are connected. In browser, use https://<consul-ui-external-ip>:443.
Example: ```https://52.249.210.131:443```

  
  
