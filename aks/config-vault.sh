# config Vault Script
# This is based on a gist provided by Iryna Shustava on Engineering team
# https://gist.github.com/ishustava/508be6f6c6480b4a68c91fae07cfb811#file-vault-wan-fed-mdx


# Set environemental variables for your environment

export VAULT_TOKEN=root

export VAULT_SERVER_HOST=$(kubectl get svc vault-dc1 --context=dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo Vault server host address is address is $VAULT_SERVER_HOST

export VAULT_ADDR=http://${VAULT_SERVER_HOST}:8200
echo Vault address is $VAULT_ADDR

# Since we've set the VAULT_ADDR to point to our Vault server (via the Load Balancer), we can run the vault commands 
# below locally without having to log into the Vault container. 

# First, enable the Kubernetes Auth Method. This allows Vault to authenticate and communicate 
# with the both of the Kube cluster API servers.

#Enable Auth method for dc1

echo Enabling Kubernetes Auth Method on dc1

vault auth enable -path=kubernetes-dc1 kubernetes

vault write auth/kubernetes-dc1/config kubernetes_host=https://kubernetes.default.svc

kubectl apply -f auth-method.yaml

echo Enabling Kubernetes Auth Method on dc2

# Next, we will need to retreive the token and CA cert from that service account secret from the dc2 k8s cluster.
# We will store these in Vault (auth/kubernetes-dc2/config) and use them to enable Auth method on 
# dc1, as you'll see in the subsequent steps below. 

K8S_DC2_CA_CERT="$(kubectl get secret `kubectl get serviceaccounts vault-dc2-auth-method -o jsonpath='{.secrets[0].name}'` -o jsonpath='{.data.ca\.crt}' | base64 -d)"

K8S_DC2_JWT_TOKEN="$(kubectl get secret `kubectl get serviceaccounts vault-dc2-auth-method -o jsonpath='{.secrets[0].name}'` -o jsonpath='{.data.token}' | base64 -d)"

export KUBE_API_URL_DC2=$(kubectl config view -o jsonpath="{.clusters[?(@.name == \"$(kubectl config current-context)\")].cluster.server}")

#Enable Kube Auth method on dc2
vault auth enable -path=kubernetes-dc2 kubernetes

vault write auth/kubernetes-dc2/config kubernetes_host="${KUBE_API_URL_DC2}" token_reviewer_jwt="${K8S_DC2_JWT_TOKEN}" kubernetes_ca_cert="${K8S_DC2_CA_CERT}"

# Next, We will need to create auth roles for the consul-k8s components so that they access
# secrets that they will need. For each auth method in Vault, we will need roles for:

# Consul server
# Consul client
# server-acl-init job
# Role for Consul server CA

echo Creating Vault Kube Auth roles for Consul server, Consul client, server-acl-init, and Consul server CA

vault write auth/kubernetes-dc1/role/consul-server \
        bound_service_account_names=consul-server \
        bound_service_account_namespaces="default" \
        policies="gossip,connect-ca-dc1,consul-cert-dc1" \
        ttl=24h
vault write auth/kubernetes-dc1/role/consul-client \
        bound_service_account_names=consul-client \
        bound_service_account_namespaces="default" \
        policies="gossip" \
        ttl=24h
vault write auth/kubernetes-dc1/role/server-acl-init \
        bound_service_account_names=consul-server-acl-init \
        bound_service_account_namespaces="default" \
        policies="replication-token" \
        ttl=24h
vault write auth/kubernetes-dc1/role/consul-ca \
        bound_service_account_names="*" \
        bound_service_account_namespaces="default" \
        policies=ca-policy \
        ttl=1h

vault write auth/kubernetes-dc2/role/consul-server \
        bound_service_account_names=consul-server \
        bound_service_account_namespaces="default" \
        policies="gossip,connect-ca-dc2,consul-cert-dc2,replication-token" \
        ttl=24h
vault write auth/kubernetes-dc2/role/consul-client \
        bound_service_account_names=consul-client \
        bound_service_account_namespaces="default" \
        policies="gossip" \
        ttl=24h
vault write auth/kubernetes-dc2/role/server-acl-init \
        bound_service_account_names=consul-server-acl-init \
        bound_service_account_namespaces="default" \
        policies="replication-token" \
        ttl=24h
vault write auth/kubernetes-dc2/role/consul-ca \
        bound_service_account_names="*" \
        bound_service_account_namespaces="default" \
        policies=ca-policy \
        ttl=1h


# Generate and store gossip secrets on Vault. Create policy for gossip key.

vault secrets enable -path=consul kv-v2
vault kv put consul/secret/gossip key="$(consul keygen)"

vault policy write gossip - <<EOF
path "consul/data/secret/gossip" {
  capabilities = ["read"]
}
EOF

# Generate and store replication secret on Vault. Create policy for replication token.

vault kv put consul/secret/replication token="$(uuidgen | tr '[:upper:]' '[:lower:]')"

vault policy write replication-token - <<EOF
path "consul/data/secret/replication" {
  capabilities = ["read"]
}
EOF


# Configure the Consul server PKI. This is for the Consul Agent CA on the control plane.

echo Enabling PKI and configuring for Consul Agent CA  
vault secrets tune -max-lease-ttl=87600h pki
vault secrets enable pki
vault write pki/root/generate/internal common_name="Consul CA" ttl=87600h

vault policy write ca-policy - <<EOF
path "pki/cert/ca" {
  capabilities = ["read"]
}
EOF

vault write pki/roles/consul-cert-dc1 \
  allowed_domains="dc1.consul,consul-server,consul-server.default,consul-server.default.svc" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_localhost=true \
  generate_lease=true \
  max_ttl="720h"

vault policy write consul-cert-dc1 - <<EOF
path "pki/issue/consul-cert-dc1"
{
  capabilities = ["create","update"]
}
EOF

vault write pki/roles/consul-cert-dc2 \
  allowed_domains="dc2.consul,consul-server,consul-server.default,consul-server.default.svc" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_localhost=true \
  generate_lease=true \
  max_ttl="720h"

vault policy write consul-cert-dc2 - <<EOF
path "pki/issue/consul-cert-dc2"
{
  capabilities = ["create","update"]
}
EOF


# Create Connect CA policy
# This policy will allow Consul servers to use Vault as the CA for the service mesh. 
# The Connect CA will generate TLS certs for services in the mesh for mTLS communcation.
# We need to create one for each datacenter, as they will have different intermediate CAs.

echo Create Connect CA policy

vault policy write connect-ca-dc1 - <<EOF
path "/sys/mounts" {
  capabilities = [ "read" ]
}
path "/sys/mounts/connect_root" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
path "/sys/mounts/dc1/connect_inter" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
path "/connect_root/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
path "/dc1/connect_inter/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
EOF

vault policy write connect-ca-dc2 - <<EOF
path "/sys/mounts" {
  capabilities = [ "read" ]
}
path "/sys/mounts/connect_root" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
path "/sys/mounts/dc2/connect_inter" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
path "/connect_root/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
path "/dc2/connect_inter/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
EOF



