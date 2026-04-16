#!/bin/bash
# =============================================================================
# AKS Cluster – Azure CNI Pod Subnet Networking
# =============================================================================
# Node pools  : system | user | webhook
# Outbound    : LoadBalancer (cluster-wide)
#               NAT GW overrides outbound at subnet level for "webhook" pool
# Webhook NAT : Public IP prefix /28 attached to webhook node + pod subnets
# =============================================================================
# Azure CNI Pod Subnet specifics:
#   - Each nodepool needs a dedicated node subnet AND a pod subnet.
#   - Pod subnets must be delegated to Microsoft.ContainerService/managedClusters.
#   - Cluster identity needs Network Contributor on the VNet before creation.
#   - NAT GW must be attached to BOTH the webhook node subnet and pod subnet so
#     that egress from pods (direct VNet IPs) also exits via the NAT GW.
# =============================================================================
# Usage: chmod +x create-podsubnet-cluster.sh && ./create-podsubnet-cluster.sh
# =============================================================================

set -euo pipefail
export MSYS_NO_PATHCONV=1   # prevent Git Bash from mangling ARM resource IDs

# ── Configuration ─────────────────────────────────────────────────────────────
RG="rg-sim-podsubnet"
LOCATION="italynorth"
CLUSTER="sim-podsubnet"
VNET="vnet-sim-podsubnet"
K8S_VERSION="1.34.1"

# Subnets
SUBNET_NODES="subnet-nodes"               # nodes  – system + user
SUBNET_PODS="subnet-pods"                 # pods   – system + user  (delegated)
SUBNET_WEBHOOK_NODES="subnet-wh-nodes"    # nodes  – webhook
SUBNET_WEBHOOK_PODS="subnet-wh-pods"      # pods   – webhook        (delegated + NAT GW)

# NAT Gateway (webhook nodepool outbound)
NAT_GW="natgw-webhook-podsubnet"
IP_PREFIX="prefix-webhook-podsubnet"
IP_PREFIX_LENGTH=28    # /28 = 16 public IPs

# Managed identity
IDENTITY_NAME="id-sim-podsubnet"

# Node pool VM sizes
VM_SIZE_SYSTEM="Standard_D4as_v5"
VM_SIZE_USER="Standard_D4as_v5"
VM_SIZE_WEBHOOK="Standard_D4as_v5"

# ── Step 1 – Resource Group ────────────────────────────────────────────────────
echo "==> [1/13] Creating Resource Group: $RG"
if ! az group show --name "$RG" &>/dev/null; then
  az group create \
    --name "$RG" \
    --location "$LOCATION"
else
  echo "  --> Resource group '$RG' already exists, skipping"
fi

# ── Step 2 – User-Assigned Managed Identity ────────────────────────────────────
# Azure CNI pod subnet requires Network Contributor on the VNet BEFORE cluster
# creation.  A user-assigned identity allows us to pre-assign the role.
echo "==> [2/13] Creating user-assigned managed identity: $IDENTITY_NAME"
if ! az identity show --resource-group "$RG" --name "$IDENTITY_NAME" &>/dev/null; then
  az identity create \
    --resource-group "$RG" \
    --name "$IDENTITY_NAME"
  echo "  --> Waiting 15s for identity ARM propagation..."
  sleep 15
fi

IDENTITY_ID=$(az identity show \
  --resource-group "$RG" \
  --name "$IDENTITY_NAME" \
  --query id -o tsv | tr -d '\r')

IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group "$RG" \
  --name "$IDENTITY_NAME" \
  --query principalId -o tsv | tr -d '\r')

echo "  Identity ID : $IDENTITY_ID"

# ── Step 3 – Virtual Network & Subnets ────────────────────────────────────────
echo "==> [3/13] Creating VNet: $VNET (10.20.0.0/16)"
if ! az network vnet show --resource-group "$RG" --name "$VNET" &>/dev/null; then
  az network vnet create \
    --resource-group "$RG" \
    --name "$VNET" \
    --address-prefixes "10.20.0.0/16"
fi

# Capture VNet ID immediately after creation/existence is confirmed.
# Do NOT defer this to step 5 — VAR=$(az ...) suppresses set -e, making
# failures silent if the lookup is done later.
VNET_ID=$(az network vnet show \
  --resource-group "$RG" \
  --name "$VNET" \
  --query id -o tsv | tr -d '\r')
echo "  VNet ID : $VNET_ID"

echo "  --> Subnet for system + user NODES (10.20.0.0/22)"
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_NODES" &>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_NODES" \
    --address-prefix "10.20.0.0/22"
fi

echo "  --> Subnet for system + user PODS (10.20.8.0/21) — delegated"
# /21 = 2048 IPs; supports up to ~18 nodes at 110 maxPods each
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_PODS" &>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_PODS" \
    --address-prefix "10.20.8.0/21" \
    --delegations "Microsoft.ContainerService/managedClusters"
fi

echo "  --> Subnet for webhook NODES (10.20.16.0/24) — will attach NAT GW"
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_WEBHOOK_NODES" &>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_WEBHOOK_NODES" \
    --address-prefix "10.20.16.0/24"
fi

echo "  --> Subnet for webhook PODS (10.20.17.0/24) — delegated + NAT GW"
# /24 = 256 IPs; supports up to 5 nodes at 30 maxPods each (150 IPs required)
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_WEBHOOK_PODS" &>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_WEBHOOK_PODS" \
    --address-prefix "10.20.17.0/24" \
    --delegations "Microsoft.ContainerService/managedClusters"
fi

# ── Step 4 – NAT Gateway for Webhook Nodepool ──────────────────────────────────
echo "==> [4/13] Creating Public IP Prefix: $IP_PREFIX (/$IP_PREFIX_LENGTH)"
if ! az network public-ip prefix show --resource-group "$RG" --name "$IP_PREFIX" &>/dev/null; then
  az network public-ip prefix create \
    --resource-group "$RG" \
    --name "$IP_PREFIX" \
    --location "$LOCATION" \
    --length "$IP_PREFIX_LENGTH"
fi

echo "  --> Creating NAT Gateway: $NAT_GW"
if ! az network nat gateway show --resource-group "$RG" --name "$NAT_GW" &>/dev/null; then
  az network nat gateway create \
    --resource-group "$RG" \
    --name "$NAT_GW" \
    --location "$LOCATION" \
    --public-ip-prefixes "$IP_PREFIX" \
    --idle-timeout 10
fi

# Attach NAT GW to BOTH webhook subnets.
# Pods in Azure CNI pod-subnet mode get real VNet IPs from the pod subnet,
# so the NAT GW must be on the pod subnet as well to cover pod egress traffic.
echo "  --> Associating NAT GW with $SUBNET_WEBHOOK_NODES"
EXISTING_NATGW_NODES=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_WEBHOOK_NODES" \
  --query 'natGateway.id' -o tsv 2>/dev/null | tr -d '\r')
if [[ -z "$EXISTING_NATGW_NODES" ]]; then
  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_WEBHOOK_NODES" \
    --nat-gateway "$NAT_GW"
else
  echo "  --> NAT GW already associated with $SUBNET_WEBHOOK_NODES, skipping"
fi

echo "  --> Associating NAT GW with $SUBNET_WEBHOOK_PODS"
EXISTING_NATGW_PODS=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_WEBHOOK_PODS" \
  --query 'natGateway.id' -o tsv 2>/dev/null | tr -d '\r')
if [[ -z "$EXISTING_NATGW_PODS" ]]; then
  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_WEBHOOK_PODS" \
    --nat-gateway "$NAT_GW"
else
  echo "  --> NAT GW already associated with $SUBNET_WEBHOOK_PODS, skipping"
fi

# ── Step 5 – RBAC: Network Contributor on VNet ────────────────────────────────
echo "==> [5/13] Assigning Network Contributor to managed identity on VNet"
if ! az role assignment list \
    --assignee "$IDENTITY_PRINCIPAL_ID" \
    --role "Network Contributor" \
    --scope "$VNET_ID" \
    --query '[0].id' -o tsv 2>/dev/null | grep -q .; then
  az role assignment create \
    --assignee "$IDENTITY_PRINCIPAL_ID" \
    --role "Network Contributor" \
    --scope "$VNET_ID"
  echo "  --> Waiting 30s for RBAC propagation..."
  sleep 30
else
  echo "  --> Role already assigned, skipping"
fi

# ── Step 6 – Retrieve Subnet IDs ──────────────────────────────────────────────
echo "==> [6/13] Resolving subnet resource IDs"
NODES_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" \
  --name "$SUBNET_NODES" --query id -o tsv | tr -d '\r')

PODS_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" \
  --name "$SUBNET_PODS" --query id -o tsv | tr -d '\r')

WEBHOOK_NODES_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" \
  --name "$SUBNET_WEBHOOK_NODES" --query id -o tsv | tr -d '\r')

WEBHOOK_PODS_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" \
  --name "$SUBNET_WEBHOOK_PODS" --query id -o tsv | tr -d '\r')

echo "  Nodes subnet ID         : $NODES_SUBNET_ID"
echo "  Pods subnet ID          : $PODS_SUBNET_ID"
echo "  Webhook nodes subnet ID : $WEBHOOK_NODES_SUBNET_ID"
echo "  Webhook pods subnet ID  : $WEBHOOK_PODS_SUBNET_ID"

# ── Step 7 – Create AKS Cluster (system nodepool) ─────────────────────────────
echo "==> [7/13] Creating AKS cluster with system nodepool: $CLUSTER"
if ! az aks show --resource-group "$RG" --name "$CLUSTER" &>/dev/null; then
  az aks create \
    --resource-group "$RG" \
    --name "$CLUSTER" \
    --location "$LOCATION" \
    --kubernetes-version "$K8S_VERSION" \
    --tier Standard \
    \
    --network-plugin azure \
    --network-dataplane azure \
    --network-policy none \
    --service-cidr "172.16.0.0/16" \
    --dns-service-ip "172.16.0.10" \
    --vnet-subnet-id "$NODES_SUBNET_ID" \
    --pod-subnet-id "$PODS_SUBNET_ID" \
    --outbound-type loadBalancer \
    --load-balancer-sku standard \
    \
    --nodepool-name system \
    --node-count 2 \
    --min-count 2 \
    --max-count 3 \
    --enable-cluster-autoscaler \
    --node-vm-size "$VM_SIZE_SYSTEM" \
    --node-osdisk-type Managed \
    --nodepool-taints "CriticalAddonsOnly=true:NoSchedule" \
    --max-pods 110 \
    \
    --assign-identity "$IDENTITY_ID" \
    --enable-managed-identity \
    --enable-aad \
    --enable-azure-rbac \
    \
    --auto-upgrade-channel none \
    --node-os-upgrade-channel None \
    --zones 1 2 3 \
    --generate-ssh-keys \
    --no-wait

  echo "  --> Waiting for cluster provisioning (up to 30 min)..."
  az aks wait \
    --resource-group "$RG" \
    --name "$CLUSTER" \
    --created \
    --interval 30 \
    --timeout 1800
else
  echo "  --> Cluster '$CLUSTER' already exists, skipping creation"
fi

# ── Step 8 – Kubelet identity: Network Contributor on VNet ────────────────────
# The kubelet identity (node identity) also needs Network Contributor on the VNet
# to manage pod IP allocations from the pod subnet at runtime.
echo "==> [8/13] Assigning Network Contributor to kubelet identity on VNet"
KUBELET_IDENTITY_OBJECT_ID=$(az aks show \
  --resource-group "$RG" \
  --name "$CLUSTER" \
  --query identityProfile.kubeletidentity.objectId -o tsv | tr -d '\r')

if ! az role assignment list \
    --assignee "$KUBELET_IDENTITY_OBJECT_ID" \
    --role "Network Contributor" \
    --scope "$VNET_ID" \
    --query '[0].id' -o tsv 2>/dev/null | grep -q .; then
  az role assignment create \
    --assignee "$KUBELET_IDENTITY_OBJECT_ID" \
    --role "Network Contributor" \
    --scope "$VNET_ID"
  echo "  --> Waiting 20s for RBAC propagation..."
  sleep 20
else
  echo "  --> Kubelet identity role already assigned, skipping"
fi

# ── Step 9 – User Nodepool ─────────────────────────────────────────────────────
echo "==> [9/13] Adding user nodepool"
if ! az aks nodepool show --resource-group "$RG" --cluster-name "$CLUSTER" --name user &>/dev/null; then
  az aks nodepool add \
    --resource-group "$RG" \
    --cluster-name "$CLUSTER" \
    --name user \
    --mode User \
    --node-count 2 \
    --min-count 1 \
    --max-count 5 \
    --enable-cluster-autoscaler \
    --node-vm-size "$VM_SIZE_USER" \
    --node-osdisk-type Managed \
    --vnet-subnet-id "$NODES_SUBNET_ID" \
    --pod-subnet-id "$PODS_SUBNET_ID" \
    --max-pods 110 \
    --labels "role=user" \
    --zones 1 2 3
else
  echo "  --> Nodepool 'user' already exists, skipping"
fi

# ── Step 10 – Webhook Nodepool ─────────────────────────────────────────────────
# Node subnet (subnet-wh-nodes) and pod subnet (subnet-wh-pods) both have
# the NAT GW attached, ensuring all egress — from nodes and from pods — exits
# via the NAT GW public IP prefix.
echo "==> [10/13] Adding webhook nodepool (NAT GW egress via $NAT_GW)"
if ! az aks nodepool show --resource-group "$RG" --cluster-name "$CLUSTER" --name webhook &>/dev/null; then
  az aks nodepool add \
    --resource-group "$RG" \
    --cluster-name "$CLUSTER" \
    --name webhook \
    --mode User \
    --node-count 2 \
    --min-count 1 \
    --max-count 5 \
    --enable-cluster-autoscaler \
    --node-vm-size "$VM_SIZE_WEBHOOK" \
    --node-osdisk-type Managed \
    --vnet-subnet-id "$WEBHOOK_NODES_SUBNET_ID" \
    --pod-subnet-id "$WEBHOOK_PODS_SUBNET_ID" \
    --max-pods 30 \
    --node-taints "webhook=true:NoSchedule" \
    --labels "role=webhook" \
    --zones 1 2 3
else
  echo "  --> Nodepool 'webhook' already exists, skipping"
fi

# ── Step 11 – Deploy Sample Applications ──────────────────────────────────────
echo "==> [11/13] Fetching credentials and deploying applications"
az aks get-credentials \
  --resource-group "$RG" \
  --name "$CLUSTER" \
  --overwrite-existing

# Cluster was created with --enable-azure-rbac; assign current user cluster-admin.
echo "  --> Assigning Azure Kubernetes Service RBAC Cluster Admin to current user"
CLUSTER_ID=$(az aks show \
  --resource-group "$RG" \
  --name "$CLUSTER" \
  --query id -o tsv | tr -d '\r')

CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv | tr -d '\r')

if ! az role assignment list \
    --assignee "$CURRENT_USER_ID" \
    --role "Azure Kubernetes Service RBAC Cluster Admin" \
    --scope "$CLUSTER_ID" \
    --query '[0].id' -o tsv 2>/dev/null | grep -q .; then
  az role assignment create \
    --assignee "$CURRENT_USER_ID" \
    --role "Azure Kubernetes Service RBAC Cluster Admin" \
    --scope "$CLUSTER_ID"
  echo "  --> Waiting 20s for RBAC propagation..."
  sleep 20
else
  echo "  --> Cluster Admin role already assigned, skipping"
fi

# Convert kubeconfig to use az cli credentials (avoids device-code flow)
kubelogin convert-kubeconfig -l azurecli

kubectl apply -f webhook-app.yaml
kubectl apply -f user-app.yaml

# ── Step 12 – Egress verification: user-app (LoadBalancer) ────────────────────
echo ""
echo "==> [12/13] Verifying user-app egress (should match cluster LoadBalancer outbound IP)"

echo "  --> Waiting for user-app pods to be Running..."
kubectl wait pod \
  --namespace user-app \
  --selector app=user-app \
  --for=condition=Ready \
  --timeout=120s

echo "  --> Running curl ifconfig.me inside a user-app pod..."
USER_POD=$(kubectl get pod -n user-app -l app=user-app -o jsonpath='{.items[0].metadata.name}')
USER_EGRESS_IP=$(kubectl exec -n user-app "$USER_POD" -- curl -s --max-time 15 ifconfig.me | tr -d '[:space:]')
echo "  Pod egress IP (curl ifconfig.me) : $USER_EGRESS_IP"

echo "  --> Fetching cluster LoadBalancer outbound IP..."
LB_OUTBOUND_IP=$(MSYS_NO_PATHCONV=1 az network lb show \
  --resource-group "MC_${RG}_${CLUSTER}_${LOCATION}" \
  --name "kubernetes" \
  --query 'frontendIPConfigurations[0].publicIPAddress.id' \
  -o tsv 2>/dev/null | tr -d '\r')
if [[ -n "$LB_OUTBOUND_IP" ]]; then
  LB_IP=$(MSYS_NO_PATHCONV=1 az network public-ip show --ids "$LB_OUTBOUND_IP" --query ipAddress -o tsv | tr -d '\r')
else
  LB_IP=""
fi
echo "  LoadBalancer outbound IP         : $LB_IP"

if [[ "$USER_EGRESS_IP" == "$LB_IP" ]]; then
  echo "  [PASS] User-app egress matches LoadBalancer outbound IP"
else
  echo "  [WARN] Mismatch – pod: $USER_EGRESS_IP | LB: $LB_IP"
fi

# ── Step 13 – Egress verification: webhook-app (NAT Gateway) ──────────────────
echo ""
echo "==> [13/13] Verifying webhook-app egress (should match NAT GW IP prefix)"

echo "  --> Waiting for webhook pods to be Running..."
kubectl wait pod \
  --namespace webhook \
  --selector app=webhook \
  --for=condition=Ready \
  --timeout=120s

echo "  --> Running curl ifconfig.me inside a webhook pod..."
WEBHOOK_POD=$(kubectl get pod -n webhook -l app=webhook -o jsonpath='{.items[0].metadata.name}')
WEBHOOK_EGRESS_IP=$(kubectl exec -n webhook "$WEBHOOK_POD" -- curl -s --max-time 15 ifconfig.me | tr -d '[:space:]')
echo "  Pod egress IP (curl ifconfig.me) : $WEBHOOK_EGRESS_IP"

echo "  --> Fetching NAT GW public IP prefix..."
NATGW_PREFIX=$(az network public-ip prefix show \
  --resource-group "$RG" \
  --name "$IP_PREFIX" \
  --query ipPrefix -o tsv | tr -d '\r')
# Strip the /28 mask to get just the network address for comparison prefix
NATGW_PREFIX_BASE="${NATGW_PREFIX%/*}"
echo "  NAT GW IP prefix                 : $NATGW_PREFIX"

# Check if the pod's egress IP falls within the prefix (simple prefix check)
NATGW_PREFIX_OCTETS=$(echo "$NATGW_PREFIX_BASE" | cut -d. -f1-3)
WEBHOOK_IP_OCTETS=$(echo "$WEBHOOK_EGRESS_IP" | cut -d. -f1-3)
if [[ "$WEBHOOK_IP_OCTETS" == "$NATGW_PREFIX_OCTETS" ]]; then
  echo "  [PASS] Webhook-app egress IP ($WEBHOOK_EGRESS_IP) is within NAT GW prefix ($NATGW_PREFIX)"
else
  echo "  [WARN] Mismatch – pod: $WEBHOOK_EGRESS_IP | NAT GW prefix: $NATGW_PREFIX"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Cluster  : $CLUSTER (Azure CNI Pod Subnet)"
echo " Location : $LOCATION"
echo " RG       : $RG"
echo "------------------------------------------------------------"
echo " Node pools:"
echo "   system  – taint CriticalAddonsOnly=true:NoSchedule"
echo "             nodes: $SUBNET_NODES | pods: $SUBNET_PODS"
echo "   user    – general workloads"
echo "             nodes: $SUBNET_NODES | pods: $SUBNET_PODS"
echo "   webhook – taint webhook=true:NoSchedule"
echo "             nodes: $SUBNET_WEBHOOK_NODES | pods: $SUBNET_WEBHOOK_PODS"
echo "------------------------------------------------------------"
echo " NAT GW   : $NAT_GW"
echo " IP Prefix: $(az network public-ip prefix show \
    --resource-group "$RG" --name "$IP_PREFIX" --query ipPrefix -o tsv)"
echo "------------------------------------------------------------"
echo " Egress verification:"
echo "   user-app   pod IP : ${USER_EGRESS_IP:-n/a}  |  LB outbound: ${LB_IP:-n/a}"
echo "   webhook    pod IP : ${WEBHOOK_EGRESS_IP:-n/a}  |  NAT GW prefix: ${NATGW_PREFIX:-n/a}"
echo "============================================================"
