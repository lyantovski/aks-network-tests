#!/bin/bash
# =============================================================================
# AKS Cluster – Kubenet Networking
# =============================================================================
# Node pools  : system | user | webhook
# Outbound    : LoadBalancer (cluster-wide)
#               NAT GW overrides outbound at subnet level for "webhook" pool
# Webhook NAT : Public IP prefix /28 attached to subnet-webhook
# =============================================================================
# Usage: chmod +x create-kubenet-cluster.sh && ./create-kubenet-cluster.sh
# =============================================================================

set -euo pipefail
export MSYS_NO_PATHCONV=1   # prevent Git Bash from mangling ARM resource IDs

# ── Configuration ─────────────────────────────────────────────────────────────
RG="rg-sim-kubenet"
LOCATION="italynorth"
CLUSTER="sim-kubenet"
VNET="vnet-sim-kubenet"
K8S_VERSION="1.34.1"

# Subnets
SUBNET_NODES="subnet-nodes"       # shared by system + user nodepools
SUBNET_WEBHOOK="subnet-webhook"   # exclusive to webhook nodepool → NAT GW

# NAT Gateway (webhook nodepool outbound)
NAT_GW="natgw-webhook-kubenet"
IP_PREFIX="prefix-webhook-kubenet"
IP_PREFIX_LENGTH=28   # /28 = 16 public IPs

# Managed identity (pre-created so we can assign Network Contributor before cluster creation)
IDENTITY_NAME="id-sim-kubenet"

# Node pool VM sizes
VM_SIZE_SYSTEM="Standard_D4as_v5"
VM_SIZE_USER="Standard_D4as_v5"
VM_SIZE_WEBHOOK="Standard_D4as_v5"

# ── Step 1 – Resource Group ────────────────────────────────────────────────────
echo "==> [1/10] Creating Resource Group: $RG"
if ! az group show --name "$RG" &>/dev/null; then
  az group create \
    --name "$RG" \
    --location "$LOCATION"
else
  echo "  --> Resource group '$RG' already exists, skipping"
fi

# ── Step 2 – User-Assigned Managed Identity ────────────────────────────────────
# Using a user-assigned identity so we can pre-assign Network Contributor
# on the VNet/subnets before cluster creation (required for kubenet BYO-VNet).
echo "==> [2/10] Creating user-assigned managed identity: $IDENTITY_NAME"
if ! az identity show --resource-group "$RG" --name "$IDENTITY_NAME" &>/dev/null; then
  az identity create \
    --resource-group "$RG" \
    --name "$IDENTITY_NAME"
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
echo "==> [3/10] Creating VNet: $VNET (10.10.0.0/16)"
if ! az network vnet show --resource-group "$RG" --name "$VNET" &>/dev/null; then
  az network vnet create \
    --resource-group "$RG" \
    --name "$VNET" \
    --address-prefixes "10.10.0.0/16"
fi

echo "  --> Creating subnet for system + user nodes (10.10.0.0/22)"
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_NODES" &>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_NODES" \
    --address-prefix "10.10.0.0/22"
fi

echo "  --> Creating subnet for webhook nodes (10.10.4.0/24) — will attach NAT GW"
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_WEBHOOK" &>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_WEBHOOK" \
    --address-prefix "10.10.4.0/24"
fi

# ── Step 4 – NAT Gateway for Webhook Nodepool ──────────────────────────────────
echo "==> [4/10] Creating Public IP Prefix: $IP_PREFIX (/$IP_PREFIX_LENGTH)"
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

echo "  --> Associating NAT GW with $SUBNET_WEBHOOK"
EXISTING_NATGW=$(az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_WEBHOOK" \
  --query 'natGateway.id' -o tsv 2>/dev/null | tr -d '\r')
if [[ -z "$EXISTING_NATGW" ]]; then
  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$SUBNET_WEBHOOK" \
    --nat-gateway "$NAT_GW"
else
  echo "  --> NAT GW already associated with $SUBNET_WEBHOOK, skipping"
fi

# ── Step 5 – RBAC: Network Contributor on VNet ────────────────────────────────
# Kubenet requires the cluster identity to manage route tables on the subnets.
echo "==> [5/10] Assigning Network Contributor to managed identity on VNet"
VNET_ID=$(az network vnet show \
  --resource-group "$RG" \
  --name "$VNET" \
  --query id -o tsv | tr -d '\r')

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
echo "==> [6/10] Resolving subnet resource IDs"
NODES_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_NODES" \
  --query id -o tsv | tr -d '\r')

WEBHOOK_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_WEBHOOK" \
  --query id -o tsv | tr -d '\r')

echo "  Nodes subnet ID   : $NODES_SUBNET_ID"
echo "  Webhook subnet ID : $WEBHOOK_SUBNET_ID"

# ── Step 7 – Create AKS Cluster (system nodepool) ─────────────────────────────
echo "==> [7/10] Creating AKS cluster with system nodepool: $CLUSTER"
if ! az aks show --resource-group "$RG" --name "$CLUSTER" &>/dev/null; then
  az aks create \
    --resource-group "$RG" \
    --name "$CLUSTER" \
    --location "$LOCATION" \
    --kubernetes-version "$K8S_VERSION" \
    --tier Standard \
    \
    --network-plugin kubenet \
    --pod-cidr "10.244.0.0/16" \
    --service-cidr "10.0.0.0/16" \
    --dns-service-ip "10.0.0.10" \
    --vnet-subnet-id "$NODES_SUBNET_ID" \
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

# ── Step 8 – User Nodepool ─────────────────────────────────────────────────────
echo "==> [8/10] Adding user nodepool"
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
    --max-pods 110 \
    --labels "role=user" \
    --zones 1 2 3
else
  echo "  --> Nodepool 'user' already exists, skipping"
fi

# ── Step 9 – Webhook Nodepool ──────────────────────────────────────────────────
# Placed in its own subnet (subnet-webhook) which has the NAT GW attached.
# Azure subnet-level NAT GW takes precedence over the load balancer outbound
# rules, so all egress from this nodepool will exit via the NAT GW public IP prefix.
echo "==> [9/10] Adding webhook nodepool (NAT GW egress via $NAT_GW)"
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
    --vnet-subnet-id "$WEBHOOK_SUBNET_ID" \
    --max-pods 110 \
    --node-taints "webhook=true:NoSchedule" \
    --labels "role=webhook" \
    --zones 1 2 3
else
  echo "  --> Nodepool 'webhook' already exists, skipping"
fi

# ── Step 10 – Deploy Sample Webhook Application ────────────────────────────────
echo "==> [10/12] Fetching credentials and deploying webhook application"
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

# ── Step 11 – Egress verification: user-app (LoadBalancer) ────────────────────
echo ""
echo "==> [11/12] Verifying user-app egress (should match cluster LoadBalancer outbound IP)"

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

# ── Step 12 – Egress verification: webhook-app (NAT Gateway) ──────────────────
echo ""
echo "==> [12/12] Verifying webhook-app egress (should match NAT GW IP prefix)"

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
echo " Cluster  : $CLUSTER (Kubenet)"
echo " Location : $LOCATION"
echo " RG       : $RG"
echo "------------------------------------------------------------"
echo " Node pools:"
echo "   system  – taint CriticalAddonsOnly=true:NoSchedule"
echo "   user    – general workloads"
echo "   webhook – taint webhook=true:NoSchedule | subnet: $SUBNET_WEBHOOK"
echo "------------------------------------------------------------"
echo " NAT GW   : $NAT_GW"
echo " IP Prefix: $(az network public-ip prefix show \
    --resource-group "$RG" --name "$IP_PREFIX" --query ipPrefix -o tsv)"
echo "------------------------------------------------------------"
echo " Egress verification:"
echo "   user-app   pod IP : ${USER_EGRESS_IP:-n/a}  |  LB outbound: ${LB_IP:-n/a}"
echo "   webhook    pod IP : ${WEBHOOK_EGRESS_IP:-n/a}  |  NAT GW prefix: ${NATGW_PREFIX:-n/a}"
echo "============================================================"
