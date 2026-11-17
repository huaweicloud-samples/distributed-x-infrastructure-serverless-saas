# Huawei Cloud Serverless SaaS Multi-Tenant Reference Architecture

![License](https://img.shields.io/badge/License-MIT-0?style=flat-square)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-Serverless%20SaaS-Blue?style=flat-square)
![Terraform](https://img.shields.io/badge/Terraform-1.5%2B-purple?style=flat-square)

[中文版](README.cn.md)

---

## 1. Introduction

This project is a **multi-tenant SaaS reference architecture** built entirely on Huawei Cloud serverless services. It implements a complete multi-tenant SaaS backend with tiered plans, JWT authentication, per-tenant data isolation and API rate limiting.

Core capabilities:

- **Multi-Tenant Management**: Pooled deployment mode with per-tenant collection isolation
- **Tiered Plans**: Four tenant tiers — Basic, Standard, Premium, Platinum — each with its own APIG credential and request quota
- **API Gateway**: Two APIG dedicated instances (internal admin + public tenant), with a custom JWT authorizer
- **Elastic Scaling**: FunctionGraph serverless computing, billed by invocation
- **Data Isolation**: GeminiDB MongoDB replica set, one database with per-tenant collections

Suitable for enterprises that need to stand up a multi-tenant SaaS backend quickly, especially B2B scenarios such as e-commerce, CRM and ERP.

---

## 2. Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                     Tenant end users / clients                     │
│                 APIG tenant instance (public ingress)              │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ HTTPS + JWT
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│            APIG tenant instance: custom authorizer + quota        │
│         4 APP credentials (Basic / Standard / Premium / Platinum)   │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ event
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                     FunctionGraph (Python 3.9)                     │
│        tenant-mgmt / product / order / authorizer (4 functions)    │
│             structured logger + LTS log streaming                  │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ data
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│            GeminiDB MongoDB replica set: 1 database                │
│        tenants / settings (global) + products_<id> / orders_<id>   │
└────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────┐
  │ APIG admin   │  │ OBS bucket   │  │ IAM agency   │  │  LTS    │
  │ (internal,   │  │ (function    │  │ (FGS → OBS / │  │ (logs)  │
  │  IAM auth)   │  │  code pkgs)  │  │  VPC)        │  │         │
  └──────────────┘  └──────────────┘  └──────────────┘  └─────────┘
```

---

## 3. Key Features

| Feature | Description |
|---------|-------------|
| **Serverless First** | Core business logic runs on FunctionGraph — no server fleet to maintain |
| **Multi-Tenant Isolation** | Pooled mode; one database, per-tenant collections (`products_<tenantId>`) |
| **Tiered Plans** | Four tiers, each mapped to an APIG APP credential with its own request quota |
| **Huawei Cloud Native** | APIG, FunctionGraph, GeminiDB, OBS, LTS, IAM — no third-party components |
| **IaC Management** | Terraform manages the full resource set; one-command deploy and destroy |
| **Reproducible Build** | A single shell script packages all four functions for OBS delivery |

---

## 4. Cloud Services

### 4.1 Service List

| Service | Specification | Purpose |
|---------|---------------|---------|
| APIG | 2 dedicated instances (BASIC) | Admin (internal) and tenant (public) API entry points |
| FunctionGraph | Python 3.9 runtime, 4 functions | Tenant, product, order business logic and the authorizer |
| GeminiDB | MongoDB replica set, 3 nodes, 100 GB | Multi-tenant data persistence |
| OBS | Standard, private bucket | Function code package hosting |
| LTS | Log group + log stream | Runtime log collection and retention |
| IAM | Delegated agency + AX role | Lets FunctionGraph read code packages and attach to the VPC |
| VPC | 1 VPC + 1 subnet + security group | Network plane for functions and the database |

### 4.2 Resource Cleanup

> After verification, destroy the resources created by this practice following the "Cleanup Resources" section.

---

## 5. Prerequisites

- Huawei Cloud account (real-name verified)
- Terraform >= 1.5.0
- Python 3.8+ (for packaging function code)
- Huawei Cloud Access Key / Secret Key with permissions for APIG, FunctionGraph, GeminiDB, OBS, LTS, IAM and VPC

---

## 6. Quick Start / One-Click Deploy

```bash
# 1. Clone code
git clone <repository-url>
cd distributed-x-infrastructure-serverless-saas

# 2. Configure credentials via environment variables (never write them to disk)
export HW_ACCESS_KEY="<your-access-key>"
export HW_SECRET_KEY="<your-secret-key>"

# 3. Package the function code
./scripts/build-packages.sh

# 4. Initialize Terraform
cd infra
terraform init

# 5. Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and fill in geminidb_password and jwt_secret

# 6. Deploy
terraform apply -var-file="terraform.tfvars"
```

### 6.1 Key Input Variables

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `region` | Deployment region | No | `cn-north-4` |
| `project_name` | Resource name prefix | No | `serverless-saas` |
| `environment` | Environment tag (dev / staging / prod) | No | `dev` |
| `geminidb_password` | GeminiDB admin and application account secret | **Yes** | — |
| `jwt_secret` | HMAC secret (HS256) used by the authorizer | **Yes** | — |
| `obs_bucket_name` | OBS bucket base name | No | `serverless-saas-assets` |
| `geminidb_node_num` | GeminiDB node count | No | `3` |
| `public_ingress_enabled` | Public ingress for the tenant APIG instance | No | `true` |
| `ingress_bandwidth_size` | Public ingress bandwidth (MB/s) | No | `5` |
| `log_retention_days` | LTS log retention | No | `30` |

The full list lives in [`infra/variables.tf`](infra/variables.tf).

---

## 7. Step-by-Step Deployment

For detailed step-by-step deployment instructions, see [docs/deployment-guide.md](docs/deployment-guide.md).

```bash
# Step 1: Package the function code (produces build/*.zip)
./scripts/build-packages.sh

# Step 2: Deploy the network layer
terraform apply -target=huaweicloud_vpc.main
terraform apply -target=huaweicloud_vpc_subnet.primary

# Step 3: Deploy the database
terraform apply -target=huaweicloud_geminidb_instance.main
terraform apply -target=huaweicloud_geminidb_account.app

# Step 4: Deploy the functions (requires the agency and the OBS bucket)
terraform apply -target=huaweicloud_fgs_function.tenant_management

# Step 5: Deploy the API gateway
terraform apply -target=huaweicloud_apig_instance.tenant
terraform apply -target=huaweicloud_apig_api.tenant_get_product

# Step 6: Deploy everything else
terraform apply
```

---

## 8. Usage / Verification

### 8.1 Get API Addresses

```bash
terraform output apig_info
```

The tenant API is reachable over the public ingress; the admin API is internal-only and authenticates with IAM.

### 8.2 Create a Tenant (internal admin API)

```bash
curl -X POST "https://<admin-api-url>/tenant" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: <iam-token>" \
  -d '{
    "tenantId": "acme-corp",
    "tenantName": "Acme Corporation",
    "tenantTier": "PLATINUM"
  }'
```

### 8.3 Sign a JWT and Call the Tenant API

The authorizer validates HS256 tokens signed with the `jwt_secret` you supplied.

```python
import jwt, time
token = jwt.encode(
    {"tenant_id": "acme-corp", "user_role": "user", "sub": "user-1", "exp": int(time.time()) + 3600},
    "<jwt_secret>",
    algorithm="HS256",
)
```

```bash
# Create a product
curl -X POST "https://<tenant-api-url>/products" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <jwt-token>" \
  -d '{"productName": "Widget A", "price": 99.99, "stock": 10}'

# Read a product
curl "https://<tenant-api-url>/products/<product-id>" \
  -H "Authorization: Bearer <jwt-token>"

# Place an order
curl -X POST "https://<tenant-api-url>/orders" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <jwt-token>" \
  -d '{"productId": "<product-id>", "quantity": 2}'
```

### 8.4 Retrieve the APP Credentials

```bash
terraform output -raw api_keys
```

Each tier's `app_key` / `app_secret` is bound to a distinct quota in the throttling policy.

---

## 9. Cleanup Resources

```bash
# Destroy all resources
terraform destroy -var-file="terraform.tfvars"

# Enter yes to confirm
```

> ⚠️ After cleanup, GeminiDB data will be permanently lost. Please confirm before executing.

---

## 10. Detailed Documentation

### 10.1 Multi-Tenant Isolation

- **Storage model**: a single GeminiDB database (`serverless_saas` by default)
- **Global collections**: `tenants` and `settings`, filtered by the `tenantId` field
- **Tenant collections**: `products_<tenantId>` and `orders_<tenantId>`, one collection per tenant
- **Access control**: every read and write goes through `common.tenant_collection()`, which validates the tenant ID against a strict character set before touching a collection name — this prevents cross-tenant access through collection-name injection

### 10.2 API Authentication Flow

```
1. Tenant user signs in → obtains a JWT (HS256, shared secret)
2. Client sends Authorization: Bearer <token>
3. APIG custom authorizer (network_type = V2) invokes the authorizer function
4. The function verifies the signature and expiry, then confirms tenant status in the database
5. On success, tenantId / userRole are injected into the request context
6. The business function reads tenantId from requestContext.authorizer and scopes all data access
```

The admin API uses IAM authentication and never passes through the custom authorizer.

### 10.3 Data Model

| Collection | Scope | Key fields |
|------------|-------|------------|
| `tenants` | Global | `tenantId`, `tenantName`, `tenantTier`, `isActive`, `dedicatedTenancy` |
| `settings` | Global | `settingName`, `settingValue` (e.g. `apiGatewayUrl-Pooled`) |
| `products_<tenantId>` | Per tenant | `productId`, `productName`, `price`, `stock` |
| `orders_<tenantId>` | Per tenant | `orderId`, `productId`, `quantity`, `totalAmount`, `status` |

### 10.4 Rate Limiting

A single `API-based` throttling policy applies a per-APP quota on the tenant instance:

| Tier | Requests per minute |
|------|---------------------|
| Basic | 50 |
| Standard | 100 |
| Premium | 150 |
| Platinum | 200 |

The policy is associated with the published APIs through `huaweicloud_apig_throttling_policy_associate`.

---

## 11. Dependencies

### Main Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| pymongo | 4.x | GeminiDB MongoDB connection |
| PyJWT | 2.x | JWT signature verification |

See [`src/requirements.txt`](src/requirements.txt).

---

## 12. FAQ / Troubleshooting

**Q: GeminiDB connection failed?**
A: Check the security group rules — the function subnet must be allowed to reach port 8635. Also confirm the account was granted access to the `serverless_saas` database.

**Q: APIG returns 401?**
A: Check the authorizer function logs in LTS. Verify the token is HS256-signed with the same secret as `jwt_secret`, and that it has not expired.

**Q: Functions fail on the first invocation after deployment?**
A: Functions attached to a VPC need the delegated agency to take effect. The first cold start after attaching a VPC takes noticeably longer; retry after a short wait.

**Q: How do I change a tenant tier's quota?**
A: Edit the `app_throttles` block in `infra/main.tf` and re-apply.

**Q: `terraform apply` fails with "object not found" for the code package?**
A: Run `./scripts/build-packages.sh` first — Terraform uploads `build/*.zip` to OBS.

---

## 13. Contributing

Issues and pull requests are welcome.

```bash
# Fork this repository
# Create feature branch
git checkout -b feature/your-feature

# Commit changes
git commit -m "Add your feature"

# Push branch
git push origin feature/your-feature

# Create Pull Request
```

---

## 14. License

[MIT](./LICENSE)
