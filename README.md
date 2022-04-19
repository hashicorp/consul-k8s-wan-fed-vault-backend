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
3. You will need to have Consul installed locally if you want to run the config-vault.sh script provided from your local machine. The reason is because the script will run the **consul keygen** command which requires Consul. It will then store the output of the command onto a Vault KV store. 
 
If you do not have Consul installed locally, you can edit the config-vault.sh script to explicitly set the gossip key:
```
vault kv put consul/secret/gossip key="<YOUR_GOSSIP_KEY>"
```


# Deploy Vault in first Kube cluster. We have named this kube cluster: dc1

1. Set the context to your **dc1** kubernetes cluster

```
kubectl config use-context dc1
```

2. Install Vault in dev-mode to dc1

```
helm install vault-dc1 -f vault-dc1.yaml hashicorp/vault --wait
```

3. Set variable VAULT_SERVER_HOST with the external-IP of the newly deployed Vault service.

```
VAULT_SERVER_HOST=$(kubectl get svc vault-dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```


# Deploy Vault in second Kube cluster. We have named this kube cluster: dc2

5. Create Helm values file which will be used to deploy the Vault agent injector in the second kubernetes cluster, dc2. 

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
  
6. Set the context to your **dc2** kubernetes cluster

```
kubectl config use-context dc2
```
  
7. Deploy Vault agent injector to dc2

```
helm install vault-dc2 -f vault-dc2.yaml hashicorp/vault --wait
```
  

# Next we configure the Vault instance with the config-vault.sh script provided
  
8. Set the permission on the config-vault.sh script file.
  
```
chmod 777 config-vault.sh
```
  
9. Run config-vault.sh
  
```
source config-vault.sh
```
  
10. Vault should now be configured. Log onto your Vault server to confirm the consul/ and pki engines show appear. Vault server's externa-IP service can be retreived with
```
kubectl get svc vault-dc1 --context=dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```
Use port 8200 in your browsers. Example: ```http://20.85.158.201:8200```

Root password for Vault in demo-mode is ```root```

   ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2011.48.54%20AM.png)

   Confirm the Consul gossip and replication secrets are located in the **consul/** secrets engine.
   
  ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2012.04.55%20PM.png)
   
   Confirm the Consul Agent CA's certificate also appears in the **pki** secrets engine. It should say **Consul CA**.
   
  ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2012.11.07%20PM.png)
  
  
# Now we can deploy Consul in dc1 
  
11. Set the context to your **dc1** kubernetes cluster
  
```
kubectl config use-context dc1
```
  
  
12. Deploy the primary Consul in dc1 with the consul-dc1.yaml file.
  
```
helm install consul-dc1 -f consul-dc1.yaml hashicorp/consul
```
  
13. Confirm the primary Consul in dc1 successfully deploys. This may take a few minutes to fully complete. You may see the consul-mesh-gateway pod error out a couple of times before it successfully launches. This is expected.

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
  
# (Optional) Confirm Agent CA Certificates 
14. On your Vault server UI in the **pki** secrets engine, you should see two certificates cooresponding to the Consul Agent CA and the Consul server TLS certificate. 

   Note: If you see three certificates, it is likley a bug, but should be harmless.

 ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%201.26.06%20PM.png)

   These should match with file on your Consul server's mounted file system ```/vault/secrets```.  Run the commands below to check that they match the certificates on Vault.
```
kubectl exec consul-server-0 --context=dc1 -- cat /vault/secrets/serverca.crt 
kubectl exec consul-server-0 --context=dc1 -- cat vault/secrets/servercert.crt 
```   
  
# (Optional) Confirm Connect CA Certificates 

15. On your Vault server UI, you should see additional **connect_root** and **dc1/connect_inter/** secrets engines appear.
  ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/connect-root-pki.png)
  
  To check that the Connect CA certificates on Vault matches with Connect CA certificates used on your Consul deployment, you can compare the two certificates in the **connect_root** UI page with the certificates returned from when querying the Consul server API.

   On Vault UI, click on the certiificates links and view the certificate. 
   ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%2012.37.52%20PM.png)

   On Consul, run the command below to retrieve the root and intermediate certificates for the Connect CA. Confirm they match with the certiifcates from the Vault UI.
   ```
   kubectl exec consul-server-0 -- curl --cacert /vault/secrets/serverca.crt -v https://localhost:8501/v1/agent/connect/ca/roots | jq
   ```



# Deploy Secondary Consul on dc2.


16. Set the MESH_GW_HOST variable to point to the Mesh Gateway's external-IP that was launched on your primary Consul deployment. 
    We will use this to deploy and connect the secondary Consul to the primary Consul.
  
```
MESH_GW_HOST=$(kubectl get svc consul-mesh-gateway --context=dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

17. Create the Consul helm values file for your secondary Consul deployment by copy/pasting the full command below.
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
  
  
  18. Set the context to your **dc2** kubernetes cluster

```
kubectl config use-context dc2
```
  
  19. Deploy your secondary Consul
  
```
helm install consul-dc2 -f consul-dc2.yaml hashicorp/consul
```
  
  20. Confirm the primary Consul in dc2 successfully deploys. This may take a few minutes to fully complete. 
  
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

21. Confirm both Consul deployments are part of the WAN Federation:

```
kubectl exec consul-server-0 --context=dc1 -- consul members -wan -ca-file /vault/secrets/serverca.crt
Defaulted container "consul" out of: consul, vault-agent, vault-agent-init (init)
Node                 Address           Status  Type    Build   Protocol  DC   Partition  Segment
consul-server-0.dc1  10.244.0.10:8302  alive   server  1.11.3  2         dc1  default    <all>
consul-server-0.dc2  10.244.2.10:8302  alive   server  1.11.3  2         dc2  default    <all>
```

# (Optional) Confirm Agent CA Certificates.

On your Vault server UI in the **pki** secrets engine, you should see a new certificate cooresponding to secondary Consul server's TLS certificate on dc2. 

   These should match with files on your Consul server's mounted file system ```/vault/secrets``` on **dc2**.  Run the commands below to check that they match the certificates on Vault.
```
kubectl exec consul-server-0 --context=dc2 -- cat /vault/secrets/serverca.crt 
kubectl exec consul-server-0 --context=dc2 -- cat vault/secrets/servercert.crt 
```  

# (Optional) Confirm Connect CA Certificates.

22. On your Vault server UI, you should see additional **connect_root** and **dc2/connect_inter/** secrets engines appear.
  
  You should see a third certificate appear on the **connect_root** UI page. To check that the Connect CA certificates on Vault matches with Connect CA certificates used on your Consul deployment, you can compare the third certificate in the **connect_root** UI page with the certificates returned from when querying the Consul server API.

   On Vault UI, click on the newest certificate links and view the certificate.
   
   ![alt text](https://github.com/hashicorp/consul-k8s-wan-fed-vault-backend/blob/main/images/Screen%20Shot%202022-04-15%20at%201.11.11%20PM.png)

   On Consul, run the command below to retrieve the root and intermediate certificates for the Connect CA. You should see an additional intermediate certificate attached to the primary Consul's intermediate certificate.
   ```
   kubectl exec consul-server-0 -- curl --cacert /vault/secrets/serverca.crt -v https://localhost:8501/v1/agent/connect/ca/roots | jq
   ```

  
