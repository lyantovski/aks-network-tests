# AKS Networking Lab — Kubenet vs Azure CNI Pod Subnet

This lab provisions two AKS clusters side-by-side in **Italy North** to demonstrate the differences between the two most common AKS networking modes. Both clusters share the same three-nodepool topology and the same egress split design: regular workloads exit via the cluster Load Balancer, while webhook workloads exit via a dedicated NAT Gateway with a fixed public IP prefix.

---

## Repository Contents

| File | Purpose |
|------|---------|
| `create-kubenet-cluster.sh` | Provisions `sim-kubenet` — Kubenet networking, 10 steps |
| `create-podsubnet-cluster.sh` | Provisions `sim-podsubnet` — Azure CNI Pod Subnet, 13 steps |
| `user-app.yaml` | Sample deployment targeting the **user** nodepool |
| `webhook-app.yaml` | Sample deployment targeting the **webhook** nodepool |
| `sim-kubenet-architecture.excalidraw` | Architecture diagram for the kubenet cluster |
| `sim-podsubnet-architecture.excalidraw` | Architecture diagram for the pod-subnet cluster |
| `example-output-kubenet.txt` | Reference run output for the kubenet script |
| `examplle-output-podsubnet.txt` | Reference run output for the pod-subnet script |

---

## Quick Start

> **Note:** Both scripts default to the **Italy North** region. Change the `LOCATION` variable near the top of each script to match the customer's desired region before running.

Both scripts are fully idempotent — re-running them is safe and will skip any resource that already exists.

**Prerequisites**

- Git Bash (Windows) or any bash shell
- `az` CLI logged in (`az login`)
- `kubectl` and `kubelogin` on PATH
- `aks-preview` extension: `az extension add --name aks-preview`

```bash
# Kubenet cluster
chmod +x create-kubenet-cluster.sh
./create-kubenet-cluster.sh

# Azure CNI Pod Subnet cluster
chmod +x create-podsubnet-cluster.sh
./create-podsubnet-cluster.sh
```

> **Git Bash on Windows:** Both scripts export `MSYS_NO_PATHCONV=1` at the top to prevent Git Bash from converting ARM resource IDs (e.g. `/subscriptions/...`) into Windows paths. Do not remove this line.

---

## Cluster Topology (shared by both)

```
┌─────────────────────────────────────────┐
│           AKS Cluster                   │
│                                         │
│  ┌──────────────┐  ┌──────────────────┐ │
│  │ system pool  │  │   user pool      │ │
│  │ 2 nodes      │  │ 2–5 nodes        │ │
│  │ taint:       │  │ label: role=user │ │
│  │ CriticalOnly │  │                  │ │
│  └──────────────┘  └──────────────────┘ │
│                                         │
│  ┌──────────────────────────────────┐   │
│  │         webhook pool             │   │
│  │ 2–5 nodes                        │   │
│  │ taint: webhook=true:NoSchedule   │   │
│  │ label: role=webhook              │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Node pools

| Pool | Mode | Nodes | Taint | Label | Autoscaler |
|------|------|-------|-------|-------|-----------|
| system | System | 2–3 | `CriticalAddonsOnly=true:NoSchedule` | — | 2–3 |
| user | User | 2–5 | none | `role=user` | 1–5 |
| webhook | User | 2–5 | `webhook=true:NoSchedule` | `role=webhook` | 1–5 |

### Egress design

| Traffic | Exit path | Fixed IP? |
|---------|-----------|-----------|
| system + user pods | Azure Load Balancer (Standard, cluster-wide) | Dynamic public IP |
| webhook pods | NAT Gateway with public IP prefix `/28` | **Yes** — 16 fixed IPs |

The webhook NAT Gateway egress makes it possible to whitelist webhook traffic by a known, stable IP range on external systems.

---

## Networking Mode Comparison

### Kubenet (`sim-kubenet`)

```
VNet: vnet-sim-kubenet  (10.10.0.0/16)
├── subnet-nodes     10.10.0.0/22   ← system + user nodes share this subnet
└── subnet-webhook   10.10.4.0/24   ← webhook nodes only; NAT GW attached
```

- **How it works:** AKS manages an overlay network. Pods receive IP addresses from a private RFC 1918 range that is **not** part of the VNet address space. The kubelet performs NAT between pod IPs and the node IP before traffic hits the VNet.
- **Pod IPs:** Not routable from the VNet directly. Other VNet resources see the **node IP**, not the pod IP.
- **Route tables:** AKS automatically creates and manages a route table attached to the subnet to route pod CIDR ranges across nodes. The cluster identity needs **Network Contributor** on the VNet to manage these routes.
- **Subnets required:** 2 (one shared by system+user, one for webhook).
- **NAT GW scope:** Attached to `subnet-webhook` only. Webhook node IPs exit via the NAT GW; pod egress also exits via NAT GW because kubenet NATs pods to the node IP first.

### Azure CNI Pod Subnet (`sim-podsubnet`)

```
VNet: vnet-sim-podsubnet  (10.20.0.0/16)
├── subnet-nodes        10.20.0.0/22    ← system + user nodes
├── subnet-pods         10.20.8.0/21    ← system + user pods  (delegated, /21 = 2048 IPs)
├── subnet-wh-nodes     10.20.16.0/24   ← webhook nodes; NAT GW attached
└── subnet-wh-pods      10.20.17.0/24   ← webhook pods  (delegated + NAT GW)
```

- **How it works:** Each pod is assigned a **real VNet IP** from a dedicated pod subnet. No NAT between pod and VNet — the pod IP is directly routable.
- **Pod IPs:** Fully routable within the VNet and to peered networks. Other VNet resources see the actual pod IP.
- **Delegation:** Pod subnets must be delegated to `Microsoft.ContainerService/managedClusters` before cluster creation. This prevents other resources from being deployed into those subnets.
- **Subnets required:** 4 (node+pod pair for each logical pool group).
- **NAT GW scope:** Must be attached to **both** `subnet-wh-nodes` and `subnet-wh-pods`. Because pod IPs are real VNet IPs from the pod subnet, pod egress bypasses the node entirely — if only the node subnet has the NAT GW, pod traffic escapes via the Load Balancer instead.
- **Identity requirements:** Two RBAC assignments are needed — the **cluster identity** (pre-creation, to create the cluster in the VNet) and the **kubelet identity** (post-creation, for runtime pod IP allocation).

---

## Side-by-Side Differences

| Dimension | Kubenet | Azure CNI Pod Subnet |
|-----------|---------|----------------------|
| **Network plugin** | `kubenet` | `azure` |
| **Network dataplane** | (default) | `azure` (Cilium-capable) |
| **Pod IPs** | Private overlay, not VNet-routable | Real VNet IPs, fully routable |
| **VNet IP consumption** | Low — only node IPs consume VNet space | High — every pod consumes a VNet IP |
| **Subnets** | 2 | 4 |
| **Pod subnet delegation** | Not required | Required (`Microsoft.ContainerService/managedClusters`) |
| **Route tables** | AKS-managed, auto-created | Not needed (no overlay) |
| **NAT GW for webhook** | Attached to node subnet only | Attached to **both** node and pod subnets |
| **Script steps** | 10 | 13 |
| **RBAC assignments** | 1 (cluster identity → VNet) | 2 (cluster identity + kubelet identity → VNet) |
| **ARM propagation sleep** | Not needed post-identity create | 15s after identity create, 30s after cluster RBAC, 20s after kubelet RBAC |
| **Network policy support** | Limited (via `azure` or `calico` add-on) | Native Cilium / Azure Network Policy |
| **Max pods per node** | 110 (system+user), 110 (webhook) | 110 (system+user), 30 (webhook) |
| **Use when** | IP space is constrained, simpler setup | Direct pod addressability, network policies, VNet integration |

---

## VNet Address Plan

### Kubenet — `10.10.0.0/16`

| Subnet | CIDR | Used for |
|--------|------|---------|
| `subnet-nodes` | `10.10.0.0/22` | system + user nodes (1022 IPs) |
| `subnet-webhook` | `10.10.4.0/24` | webhook nodes (254 IPs) |

### Azure CNI Pod Subnet — `10.20.0.0/16`

| Subnet | CIDR | Used for |
|--------|------|---------|
| `subnet-nodes` | `10.20.0.0/22` | system + user nodes (1022 IPs) |
| `subnet-pods` | `10.20.8.0/21` | system + user pods (2046 IPs, ~18 nodes × 110 pods) |
| `subnet-wh-nodes` | `10.20.16.0/24` | webhook nodes (254 IPs) |
| `subnet-wh-pods` | `10.20.17.0/24` | webhook pods (254 IPs, ~5 nodes × 30 pods) |

---

## Cost Estimate (Italy North, USD, pay-as-you-go)

> Prices retrieved from the Azure Retail Pricing API on 2026-04-16.
> All amounts are approximate and exclude any EA/CSP discounts, reservations, or free-tier credits.

### Rates used

| Component | Unit | Rate (USD) |
|-----------|------|-----------|
| Standard_D4as_v5 (Linux, pay-as-you-go) | per node/hour | $0.202 |
| AKS Standard tier (Uptime SLA) | per cluster/hour | $0.100 |
| NAT Gateway resource | per hour | $0.045 |
| Standard Static IPv4 (Public IP Prefix /28 = 16 IPs) | per IP/hour | $0.005 |
| NAT Gateway data processing | per GB outbound | $0.045 |

### Per-cluster monthly cost (730 hours)

#### Compute — node pools

| Configuration | Nodes | Node cost/month |
|---------------|-------|----------------|
| **Baseline** (system=2, user=2, webhook=2) | 6 | 6 × $0.202 × 730 = **$885** |
| **Peak** (system=3, user=5, webhook=5) | 13 | 13 × $0.202 × 730 = **$1,917** |

#### Fixed infrastructure costs (same per cluster)

| Component | Calculation | Monthly |
|-----------|-------------|---------|
| AKS Standard tier | $0.10 × 730 hrs | **$73** |
| NAT Gateway resource | $0.045 × 730 hrs | **$33** |
| Public IP Prefix `/28` (16 × Standard Static) | 16 × $0.005 × 730 hrs | **$58** |
| **Fixed infrastructure subtotal** | | **$164** |

#### Total per cluster

| Scenario | Compute | Fixed infra | **Total/month** |
|----------|---------|-------------|----------------|
| Baseline (6 nodes) | $885 | $164 | **~$1,049** |
| Peak (13 nodes) | $1,917 | $164 | **~$2,081** |

#### Data processing estimate

The $0.045/GB charge applies to all traffic that flows **through** the NAT Gateway (webhook pods only). For a typical webhook workload:

| Webhook traffic / day | Monthly data cost |
|-----------------------|-------------------|
| 1 GB | ~$1.40 |
| 10 GB | ~$13.50 |
| 100 GB | ~$135 |

### Both clusters combined

| Scenario | Per-cluster | × 2 clusters | **Total/month** |
|----------|-------------|--------------|----------------|
| Baseline | ~$1,049 | | **~$2,098** |
| Peak | ~$2,081 | | **~$4,162** |

---

## Idempotency Design

Every resource creation step is guarded by an existence check:

```bash
if ! az <resource-type> show ... &>/dev/null; then
  az <resource-type> create ...
fi
```

This means you can:
- Re-run the script after a partial failure without side effects.
- Re-run the script to verify the end state (e.g. redeploy apps, re-run egress tests).
- Use the script as documentation that always reflects the live desired state.

NAT GW subnet association is guarded by querying `natGateway.id` on the subnet:

```bash
EXISTING_NATGW=$(az network vnet subnet show ... --query 'natGateway.id' -o tsv)
if [[ -z "$EXISTING_NATGW" ]]; then
  az network vnet subnet update --nat-gateway "$NAT_GW"
fi
```

Role assignments are guarded by checking for an existing assignment before creating:

```bash
if ! az role assignment list --assignee ... --scope ... | grep -q .; then
  az role assignment create ...
fi
```

---

## Egress Verification

Both scripts end with automated egress checks using a curl pod.

> **Note:** The public IP addresses shown in the examples below are illustrative only. Your actual IPs will differ based on the region, subscription, and resources provisioned.

### Step: user-app egress (Load Balancer)

```
[PASS] User-app egress matches LoadBalancer outbound IP
```

A pod in the `user-app` namespace (`user` nodepool) runs `curl ifconfig.me`. The result is compared to the public IP of the cluster's Azure Load Balancer frontend. They must match.

**Kubenet result:**
```
Pod egress IP  : 172.213.170.10
LB outbound IP : 172.213.170.10  ✓
```

**Pod Subnet result:**
```
Pod egress IP  : 4.232.1.156
LB outbound IP : 4.232.1.156  ✓
```

### Step: webhook-app egress (NAT Gateway)

```
[PASS] Webhook-app egress IP (x.x.x.x) is within NAT GW prefix (x.x.x.x/28)
```

A pod in the `webhook` namespace runs `curl ifconfig.me`. The result is compared to the first three octets of the NAT GW public IP prefix. It must fall within the `/28` range.

**Kubenet result:**
```
Pod egress IP    : 172.213.228.75
NAT GW prefix    : 172.213.228.64/28  ✓
```

**Pod Subnet result:**
```
Pod egress IP    : 172.213.213.32
NAT GW prefix    : 172.213.213.32/28  ✓
```

---

## Sample Applications

### `user-app.yaml`

Targets the `user` nodepool via `nodeSelector: role=user`. No tolerations — the system taint (`CriticalAddonsOnly`) and webhook taint (`webhook=true:NoSchedule`) naturally prevent this pod from landing on those pools. Runs 3 replicas with pod anti-affinity for zone spread.

### `webhook-app.yaml`

Targets the `webhook` nodepool. Requires a toleration for `webhook=true:NoSchedule` plus `nodeSelector: role=webhook`. Runs 3 replicas with pod anti-affinity.

Both use `curlimages/curl:latest` in a `sleep` loop so that `kubectl exec` can be used to run ad-hoc curl commands at any time.

---

## Architecture Diagrams

Open the `.excalidraw` files in VS Code (requires the Excalidraw extension) or at [excalidraw.com](https://excalidraw.com):

- `sim-kubenet-architecture.excalidraw` — Kubenet cluster layout
- `sim-podsubnet-architecture.excalidraw` — Azure CNI Pod Subnet cluster layout
