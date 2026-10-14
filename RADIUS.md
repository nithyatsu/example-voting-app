# Deploying the voting app with Radius: ACI + Confidential ACI and Kubernetes

One application definition, [`.radius/app.bicep`](.radius/app.bicep), deploys unchanged to two Radius Environments:

| Environment | Radius group | Recipe pack | Where the app runs |
| --- | --- | --- | --- |
| `aci` | `voting-aci` | [`recipe-packs/voting-aci.bicep`](recipe-packs/voting-aci.bicep) | `vote` (vote + worker + redis) on **Confidential ACI**, `result` on **standard ACI**, `db` on **Azure Database for PostgreSQL Flexible Server** |
| `kubernetes` | `voting-k8s` | [`recipe-packs/voting-kubernetes.bicep`](recipe-packs/voting-kubernetes.bicep) | Everything as Deployments/Services on AKS (`nsi-aks`), `db` as an in-cluster Postgres |

```
vote (containers) ──► db (postgreSqlDatabases) ◄── result (containers)
 ├─ vote   :80   (Flask)
 ├─ worker       (.NET, redis → postgres)
 └─ redis        (sidecar on localhost:6379)
```

Why it is shaped this way:

- **Redis is a sidecar.** The ACI recipe gives each `containers` resource its own VNet and public load balancer, so there is no private network between resources. Containers *within* one resource share `localhost`, so vote, worker, and Redis live together.
- **Postgres is a Radius resource.** The platform decides what it is: in-cluster Postgres on Kubernetes, Azure Flexible Server on ACI. The app reads `POSTGRES_*` env vars, and `POSTGRES_SSLMODE=prefer` makes the same image work with TLS (Azure) and plaintext (in-cluster).
- **`platformOptions.sku`** selects `Confidential` or `Standard` ACI. The Kubernetes recipe ignores it.
- **Images are prebuilt and public** in GHCR, built by [`.github/workflows/publish-images.yaml`](.github/workflows/publish-images.yaml). ACI recipes don't support `containerImages` or registry credentials.
- **No ACA.** There is no Azure Container Apps recipe yet; see [radius#13015](https://github.com/radius-project/radius/issues/13015).

## 0. Prerequisites (once)

```bash
# Tools: az, kubectl, rad (0.61 matches .radius/bicepconfig.json)
curl -fsSL https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh | /bin/bash

SUB=b3374b16-aae6-4e10-8baf-972ff29b42d0
TENANT=$(az account show --query tenantId -o tsv)
LOC=eastus2                     # Postgres B1ms is provisionable here; eastus is restricted
az account set -s $SUB
kubectl config use-context nsi-aks

# Install Radius on AKS with Azure Workload Identity enabled (cluster already has OIDC + WI)
rad install kubernetes --set global.azureWorkloadIdentity.enabled=true
rad workspace create kubernetes ignite --context nsi-aks --force
rad workspace switch ignite

# One Radius group per environment, so the same app name can exist in both
rad group create voting-aci
rad group create voting-k8s

# Database password (Azure rule: 8+ chars, 3 character classes)
export PG_PASSWORD="Vt-$(openssl rand -hex 12)"
```

## Part 1: Azure compute environment (ACI + Confidential ACI)

### 1.1 Azure resource group and identity for Radius

```bash
az group create -n nsi-aci -l $LOC

az identity create -g nsi -n radius-wi -l $LOC
CLIENT_ID=$(az identity show -g nsi -n radius-wi --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g nsi -n radius-wi --query principalId -o tsv)

# Owner so recipes can also create role assignments (e.g. Key Vault access for secrets)
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --role Owner --scope /subscriptions/$SUB/resourceGroups/nsi-aci

# Trust the AKS OIDC issuer for each Radius service account that talks to Azure
OIDC=$(az aks show -g nsi -n nsi-aks --query oidcIssuerProfile.issuerUrl -o tsv)
for sa in ucp applications-rp dynamic-rp bicep-de; do
  az identity federated-credential create -g nsi --identity-name radius-wi --name radius-$sa \
    --issuer $OIDC --subject system:serviceaccount:radius-system:$sa \
    --audiences api://AzureADTokenExchange
done

rad credential register azure wi --client-id $CLIENT_ID --tenant-id $TENANT
```

### 1.2 Environment and recipe pack

[`recipe-packs/voting-aci.bicep`](recipe-packs/voting-aci.bicep) is the upstream `azure-aci` pack (containers, persistent volumes, secrets) plus the `azure-aks` pack's PostgreSQL Flexible Server entry. ACI `desiredCount` is set to 1 because `result` uses socket.io, and the load balancer has no session affinity.

```bash
rad env create aci -g voting-aci --kubernetes-namespace voting-aci --preview
rad env update aci -g voting-aci --azure-subscription-id $SUB --azure-resource-group nsi-aci --preview

rad deploy recipe-packs/voting-aci.bicep -g voting-aci --environment aci
rad env update aci -g voting-aci --recipe-packs voting-aci --preview
rad env show aci -g voting-aci -o json
```

### 1.3 Deploy

```bash
rad deploy .radius/app.bicep -g voting-aci --environment aci -p postgresPassword="$PG_PASSWORD"
```

### 1.4 Verify

```bash
# result exposes its public IP via hosts; vote's resource has empty hosts (its first container, redis, has no port)
rad resource show Radius.Compute/containers result -g voting-aci -o json | jq .properties.hosts

# Two inbound public IPs: one for vote, one for result
az network public-ip list -g nsi-aci --query "[?starts_with(name,'inboundPIP')].{name:name, ip:ipAddress}" -o table

# Confidential vs Standard container groups
az container list -g nsi-aci --query "[].{name:name, sku:sku, state:provisioningState}" -o table
```

Open `http://<vote-ip>` and vote, then open `http://<result-ip>`.

## Part 2: Kubernetes environment

[`recipe-packs/voting-kubernetes.bicep`](recipe-packs/voting-kubernetes.bicep) is a custom pack named `voting-kubernetes` that uses the `kube-recipes` for containers, volumes, secrets, Postgres, and Redis. It doesn't overwrite Radius's built-in `default` pack.

```bash
rad env create kubernetes -g voting-k8s --kubernetes-namespace voting-k8s --preview

rad deploy recipe-packs/voting-kubernetes.bicep -g voting-k8s --environment kubernetes
rad env update kubernetes -g voting-k8s --recipe-packs voting-kubernetes --preview

rad deploy .radius/app.bicep -g voting-k8s --environment kubernetes -p postgresPassword="$PG_PASSWORD"

kubectl get pods,svc -n voting-k8s
kubectl -n voting-k8s port-forward svc/vote-vote   8080:80 &
kubectl -n voting-k8s port-forward svc/result-result 8081:80 &
# http://localhost:8080 (vote), http://localhost:8081 (result)
```

## End state

```bash
rad env list -g voting-aci
rad env list -g voting-k8s
rad app graph example-voting-app -g voting-aci
rad app graph example-voting-app -g voting-k8s
```

## Cleanup

```bash
rad app delete example-voting-app -g voting-aci -y
rad app delete example-voting-app -g voting-k8s -y
az group delete -n nsi-aci -y --no-wait
```

## Known limitations

- Confidential ACI uses the platform's default CCE policy when `platformOptions.confidentialComputeProperties.ccePolicy` is not set. For a production policy, generate one with `az confcom acipolicygen`.
- The ACI recipe passes `secretKeyRef` values through as literal key names, so the Postgres password is set as a plain env value from a `@secure()` parameter.
- The Azure Postgres server allows public access from any IP (same as the upstream `azure-aks` pack); TLS is enforced.
