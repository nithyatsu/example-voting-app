# Deploying the voting app with Radius: ACI + Confidential ACI and Kubernetes

One application definition, `.radius/app.bicep`, deploys unchanged to two Radius Environments:

| Environment | Radius group | Recipe pack | Where the app runs |
| --- | --- | --- | --- |
| `aci` | `voting-aci` | `recipe-packs/voting-aci.bicep` | `vote` (vote + worker + redis) on Confidential ACI, `result` on standard ACI, `db` on Azure Database for PostgreSQL Flexible Server, all in Azure resource group `nsi-aci` |
| `kubernetes` | `voting-k8s` | `recipe-packs/voting-kubernetes.bicep` | Everything as Deployments/Services on AKS `nsi-aks`, `db` as in-cluster Postgres |

Azure layout:

| Azure resource group | Contains |
| --- | --- |
| `nsi` (exists) | AKS cluster `nsi-aks` running the Radius control plane |
| `nsi-aci` (new) | Everything Radius creates for the `aci` environment |

App shape:

```
vote (containers) ──► db (postgreSqlDatabases) ◄── result (containers)
 ├─ vote   :80   (Flask)
 ├─ worker       (.NET, redis → postgres)
 └─ redis        (sidecar on localhost:6379)
```

- **Redis is a sidecar.** The ACI recipe gives each containers resource its own VNet and public load balancer, so there is no private network between resources. Containers within one resource share localhost.
- **Postgres is a Radius resource.** The platform decides what it is: in-cluster Postgres on Kubernetes, Azure Flexible Server on ACI. `POSTGRES_SSLMODE=prefer` makes the same image work with TLS (Azure) and plaintext (in-cluster).
- **`platformOptions.sku`** selects Confidential or Standard ACI. The Kubernetes recipe ignores it.
- **Images are prebuilt and public** in GHCR (`ghcr.io/nithyatsu/example-voting-app-*`).

---

## Step 0. Get the code and tools

```bash
git clone https://github.com/nithyatsu/example-voting-app.git
cd example-voting-app

# rad CLI (0.61 matches .radius/bicepconfig.json)
curl -fsSL https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh | /bin/bash
rad version

az login
az account set -s b3374b16-aae6-4e10-8baf-972ff29b42d0
kubectl config use-context nsi-aks
```

## Step 1. Shared variables

```bash
export SUB=b3374b16-aae6-4e10-8baf-972ff29b42d0
export LOC=eastus2
export PG_PASSWORD="Vt-$(openssl rand -hex 12)"   # Azure rule: 8+ chars, 3 character classes
echo $PG_PASSWORD                                  # save this
```

## Step 2. Install Radius on nsi-aks

```bash
rad install kubernetes
kubectl get pods -n radius-system          # wait until all pods are Running

rad workspace create kubernetes ignite --context nsi-aks --force
rad workspace switch ignite

rad group create voting-aci
rad group create voting-k8s
```

---

## Part 1: ACI environment

### Step 3. Create the ACI resource group and a service principal

```bash
az group create -n nsi-aci -l $LOC

az ad sp create-for-rbac \
  --name radius-ignite-sp \
  --role Contributor \
  --scopes /subscriptions/$SUB/resourceGroups/nsi-aci \
  -o json > sp.json

export SP_CLIENT_ID=$(jq -r .appId sp.json)
export SP_SECRET=$(jq -r .password sp.json)
export SP_TENANT=$(jq -r .tenant sp.json)
```

Contributor on `nsi-aci` is enough for this app (ACI, networking, Postgres). If you later add a `Radius.Security/secrets` resource (Key Vault), use `--role Owner`, because that recipe creates role assignments.

### Step 4. Register the credential with Radius

```bash
rad credential register azure sp \
  --client-id $SP_CLIENT_ID \
  --client-secret $SP_SECRET \
  --tenant-id $SP_TENANT

rad credential show azure                 # check: registered, kind ServicePrincipal
rm sp.json                                # it contains the secret
```

### Step 5. Create the `aci` environment and attach its recipe pack

`recipe-packs/voting-aci.bicep` is the upstream `azure-aci` pack (containers, persistent volumes, secrets) plus a PostgreSQL Flexible Server recipe. `desiredCount: 1` because `result` uses socket.io and the ACI load balancer has no session affinity.

```bash
rad env create aci -g voting-aci --kubernetes-namespace voting-aci --preview
rad env update aci -g voting-aci \
  --azure-subscription-id $SUB --azure-resource-group nsi-aci --preview

rad deploy recipe-packs/voting-aci.bicep -g voting-aci --environment aci
rad env update aci -g voting-aci --recipe-packs voting-aci --preview

rad env show aci -g voting-aci -o json    # check: Azure scope + recipe pack voting-aci
```

### Step 6. Deploy the app to ACI (about 10–15 minutes, mostly Postgres)

```bash
rad deploy .radius/app.bicep -g voting-aci --environment aci \
  -p postgresPassword="$PG_PASSWORD"
```

### Step 7. Check the ACI deployment

```bash
az container list -g nsi-aci --query "[].{name:name, sku:sku, state:provisioningState}" -o table
# Expect one Confidential group (vote) and one Standard group (result)

az network public-ip list -g nsi-aci \
  --query "[?starts_with(name,'inboundPIP')].{name:name, ip:ipAddress}" -o table

rad resource show Radius.Compute/containers result -g voting-aci -o json | jq .properties.hosts
```

Open `http://<vote-ip>` and vote, then `http://<result-ip>`. The `hosts` value is the result IP; the other inbound IP is vote.

---

## Part 2: Kubernetes environment

### Step 8. Create the `kubernetes` environment and attach its recipe pack

`recipe-packs/voting-kubernetes.bicep` is a custom pack using the `kube-recipes`. It doesn't overwrite Radius's built-in `default` pack.

```bash
rad env create kubernetes -g voting-k8s --kubernetes-namespace voting-k8s --preview

rad deploy recipe-packs/voting-kubernetes.bicep -g voting-k8s --environment kubernetes
rad env update kubernetes -g voting-k8s --recipe-packs voting-kubernetes --preview

rad env show kubernetes -g voting-k8s -o json
```

### Step 9. Deploy the same app.bicep

```bash
rad deploy .radius/app.bicep -g voting-k8s --environment kubernetes \
  -p postgresPassword="$PG_PASSWORD"
```

### Step 10. Check the Kubernetes deployment

```bash
kubectl get pods,svc -n voting-k8s       # vote (3/3), result, db Running

kubectl -n voting-k8s port-forward svc/vote-vote 8080:80 &
kubectl -n voting-k8s port-forward svc/result-result 8081:80 &
```

Open http://localhost:8080 (vote) and http://localhost:8081 (result).

---

## Step 11. Final check: two environments, one app

```bash
rad env list -g voting-aci
rad env list -g voting-k8s
rad app graph example-voting-app -g voting-aci
rad app graph example-voting-app -g voting-k8s
```

## Troubleshooting

- **Azure auth errors in step 6:** run `rad credential show azure`. If the secret is wrong or expired, run `az ad sp credential reset --id $SP_CLIENT_ID` and register again (step 4).
- **Vote works but result stays at 0:** check worker logs with `az container logs` (ACI) or `kubectl logs deploy/vote -c worker -n voting-k8s` (Kubernetes).
- **Confidential ACI rejected in eastus2:** use another region, or change `sku: 'Confidential'` to `'Standard'` in `.radius/app.bicep`.
- **Which recipe failed:** `kubectl logs -n radius-system deploy/dynamic-rp`.

## Cleanup

```bash
rad app delete example-voting-app -g voting-aci -y
rad app delete example-voting-app -g voting-k8s -y
az group delete -n nsi-aci -y --no-wait        # never delete "nsi": it holds the AKS cluster
az ad sp delete --id $SP_CLIENT_ID
```

## Known limitations

- Confidential ACI uses the platform's default CCE policy when `platformOptions.confidentialComputeProperties.ccePolicy` is not set. For production, generate one with `az confcom acipolicygen`.
- The ACI recipe passes `secretKeyRef` values through as literal key names, so the Postgres password is a plain env value from a `@secure()` parameter.
- The Azure Postgres server allows public access from any IP (same as the upstream `azure-aks` pack); TLS is enforced.
- The SP secret expires after 1 year by default.
