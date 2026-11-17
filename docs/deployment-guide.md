# 华为云 Serverless SaaS 部署指南

## 1. 前置条件

### 1.1 账号与权限

- 华为云账号（已实名认证）
- 具有以下服务管理权限：
  - VPC / 子网 / 安全组管理
  - OBS 存储桶与对象管理
  - APIG 实例、API、认证器、限流策略管理
  - FunctionGraph 函数管理
  - GeminiDB 实例与账号管理
  - IAM 角色与委托管理
  - LTS 日志组与日志流管理

### 1.2 工具准备

| 工具 | 版本要求 | 说明 |
|------|---------|------|
| Terraform | >= 1.5.0 | IaC 基础设施编排 |
| Python | 3.8+ | 函数代码打包 |
| zip（或 python -m zipfile） | 系统自带 | 生成函数代码包 |

> 无需安装 obsutil——Terraform 会自动把 `build/*.zip` 上传到 OBS。

### 1.3 环境变量

访问密钥通过环境变量提供，切勿写入任何文件或 tfvars：

```bash
export HW_ACCESS_KEY="<您的华为云 Access Key>"
export HW_SECRET_KEY="<您的华为云 Secret Key>"

# 使用 STS 临时凭据时额外提供
export HW_SECURITY_TOKEN="<您的 Token>"
```

---

## 2. 快速部署

### 2.1 克隆代码

```bash
cd /path/to/workspace
git clone <repository-url>
cd distributed-x-infrastructure-serverless-saas
```

### 2.2 打包函数代码

```bash
./scripts/build-packages.sh
```

脚本会在 `build/` 目录生成四个代码包：

```
build/tenant-management.zip
build/product-service.zip
build/order-service.zip
build/tenant-authorizer.zip
```

每个包内含入口文件与三个公共模块（`common.py` / `logger.py` / `utils.py`）。

### 2.3 初始化 Terraform

```bash
cd infra
terraform init

# 配置变量
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`，至少填写两项：

```hcl
geminidb_password = "<数据库密码>"
jwt_secret        = "<JWT 签名密钥>"
```

### 2.4 预览资源

```bash
terraform plan -var-file="terraform.tfvars"
```

**预期输出**：
```
Plan: 30 to add, 0 to change, 0 to destroy.
```

### 2.5 执行部署

```bash
terraform apply -var-file="terraform.tfvars"
```

**输入 `yes` 确认部署**，预计耗时 10-15 分钟。

---

## 3. 分步部署（可选）

如果需要分步验证，可按以下顺序手动部署各模块。

### 3.1 Step 1：创建 VPC 网络

```bash
terraform apply -target=huaweicloud_vpc.main
terraform apply -target=huaweicloud_vpc_subnet.primary
terraform apply -target=huaweicloud_networking_secgroup.saas
```

### 3.2 Step 2：部署 GeminiDB

```bash
terraform apply -target=huaweicloud_geminidb_instance.main
terraform apply -target=huaweicloud_geminidb_account.app
```

### 3.3 Step 3：部署 IAM 委托与 OBS 代码桶

```bash
terraform apply -target=huaweicloud_identity_role.fgs_runner
terraform apply -target=huaweicloud_identity_agency.fgs
terraform apply -target=huaweicloud_obs_bucket.assets
terraform apply -target=huaweicloud_obs_bucket_policy.assets
terraform apply -target=huaweicloud_obs_bucket_object.code
```

### 3.4 Step 4：部署 LTS 与 FunctionGraph 函数

```bash
terraform apply -target=huaweicloud_lts_group.app
terraform apply -target=huaweicloud_lts_stream.app

terraform apply -target=huaweicloud_fgs_function.tenant_management
terraform apply -target=huaweicloud_fgs_function.product_service
terraform apply -target=huaweicloud_fgs_function.order_service
terraform apply -target=huaweicloud_fgs_function.tenant_authorizer
```

### 3.5 Step 5：部署 APIG

```bash
terraform apply -target=huaweicloud_apig_instance.admin
terraform apply -target=huaweicloud_apig_instance.tenant
terraform apply -target=huaweicloud_apig_group.tenant
terraform apply -target=huaweicloud_apig_custom_authorizer.tenant
terraform apply -target=huaweicloud_apig_api.tenant_get_product
```

### 3.6 Step 6：配置限流与发布

```bash
terraform apply -target=huaweicloud_apig_application.basic
terraform apply -target=huaweicloud_apig_application.standard
terraform apply -target=huaweicloud_apig_application.premium
terraform apply -target=huaweicloud_apig_application.platinum
terraform apply -target=huaweicloud_apig_throttling_policy.tiers
terraform apply -target=huaweicloud_apig_api_publishment.tenant
terraform apply -target=huaweicloud_apig_throttling_policy_associate.tiers
```

---

## 4. 验证部署

### 4.1 获取 API 地址

```bash
terraform output apig_info
```

**输出示例**：
```
admin = {
  "group"  = "serverless-saas-dev-admin-group"
  "instance_id" = "xxxxx"
  "url"    = "https://xxxxx.apic.cn-north-4.huaweicloudapis.com"
}
tenant = {
  "group"  = "serverless-saas-dev-tenant-group"
  "instance_id" = "yyyyy"
  "url"    = "https://yyyyy.apic.cn-north-4.huaweicloudapis.com"
}
```

### 4.2 测试 Admin API（内网，IAM 认证）

管理端实例为内网类型，调用前需在同 VPC 内发起请求并携带 IAM 令牌：

```bash
curl -X POST "https://<admin-api-url>/tenant" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: <iam-token>" \
  -d '{
    "tenantId": "acme-corp",
    "tenantName": "Acme Corporation",
    "tenantAddress": "123 Main St",
    "tenantEmail": "admin@acme.com",
    "tenantPhone": "+86-10-12345678",
    "tenantTier": "PLATINUM",
    "dedicatedTenancy": false
  }'
```

### 4.3 签发 JWT

授权器使用 HS256 校验，密钥与 `jwt_secret` 一致：

```python
import jwt, time
token = jwt.encode(
    {
        "tenant_id": "acme-corp",
        "user_role": "user",
        "sub": "user-1",
        "exp": int(time.time()) + 3600,
    },
    "<jwt_secret>",
    algorithm="HS256",
)
```

### 4.4 测试 Tenant API（公网）

```bash
# 创建产品
curl -X POST "https://<tenant-api-url>/products" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <tenant-token>" \
  -d '{
    "productName": "Widget A",
    "productDescription": "High-quality widget",
    "price": 99.99,
    "category": "Electronics",
    "stock": 100
  }'

# 获取产品
curl "https://<tenant-api-url>/products/<product-id>" \
  -H "Authorization: Bearer <tenant-token>"

# 下单
curl -X POST "https://<tenant-api-url>/orders" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <tenant-token>" \
  -d '{"productId": "<product-id>", "quantity": 5}'
```

### 4.5 验证多租户隔离

租户身份来自 JWT 载荷中的 `tenant_id`，由授权器校验后注入请求上下文：

```bash
# 租户 A 创建产品（token 中 tenant_id = acme-corp）
curl -X POST "https://<tenant-api-url>/products" \
  -H "Authorization: Bearer <token-acme>" \
  -d '{"productName": "Product A", "price": 10}'

# 租户 B 查询产品列表（token 中 tenant_id = globex）——不应看到租户 A 的产品
curl "https://<tenant-api-url>/products" \
  -H "Authorization: Bearer <token-globex>"
```

隔离由集合名 `products_<tenantId>` 承担，跨租户访问会落到不同集合，天然不可见。

### 4.6 获取各套餐 APP 凭据

```bash
terraform output -raw api_keys
```

每组 `app_key` / `app_secret` 在限流策略中绑定了各自的每分钟配额。

---

## 5. 资源规格说明

### 5.1 资源清单

| 资源 | 规格 | 用途 |
|------|------|------|
| APIG 实例 | BASIC × 2（管理面内网 / 租户面公网） | REST API 入口 |
| FunctionGraph | Python 3.9 运行时 × 4 | 业务逻辑执行 |
| GeminiDB | MongoDB 副本集 3 节点 / 100 GB | 多租户数据存储 |
| OBS | 标准存储私有桶 | 函数代码包托管 |
| LTS | 日志组 + 日志流，30 天 | 运行期日志采集 |
| IAM | AX 角色 + FGS 委托 | 函数访问 OBS 与 VPC 的授权 |
| VPC / 子网 / 安全组 | 1 VPC / 1 子网 / 1 安全组 | 网络隔离与访问控制 |

### 5.2 规格选择建议

- **开发 / 测试环境**：把 `geminidb_node_num` 降到 1 可显著减少资源开销，验证完成后按第 7 节清理
- **生产环境**：按实际并发选择 APIG 实例规格与函数并发上限
- **日志**：调整 `log_retention_days` 以满足审计与排障要求

---

## 6. 故障排除

### 6.1 函数调用失败

```bash
# 查看函数日志
# 华为云控制台 → FunctionGraph → 函数管理 → 日志
# 或 terraform output lts_info 后到 LTS 查看对应日志流
```

常见问题：

- **GeminiDB 连接失败**：检查安全组是否放通 8635 端口（`allow_mongo` 规则）
- **首次调用超时**：函数挂载 VPC 需要委托生效，首次冷启动较慢，稍后重试
- **权限不足**：检查 IAM 委托 `fgs_runner` 的策略与 OBS 桶策略是否都已生效

### 6.2 APIG 返回 401

```bash
# 检查 authorizer 函数日志（LTS）
# 1. 确认令牌是 HS256 签名且密钥与 jwt_secret 一致
# 2. 确认令牌未过期（载荷含 exp）
# 3. 确认租户在 tenants 集合中存在且 isActive 为 true
```

### 6.3 跨域问题

```bash
# APIG 默认不处理 CORS，需在 API 定义中配置 CORS 规则，
# 或在函数响应的 headers 中返回跨域头（utils.generate_response 已内置）
```

---

## 7. 清理资源

### 7.1 销毁所有资源

```bash
# 确认无重要数据后执行
terraform destroy -var-file="terraform.tfvars"

# 输入 yes 确认销毁
```

### 7.2 手动清理（如有残留）

```
# 华为云控制台 → GeminiDB → 删除实例
# 华为云控制台 → OBS → 删除桶
# 华为云控制台 → APIG → 删除专享实例
# 华为云控制台 → FunctionGraph → 删除函数
```

---

## 8. 后续操作

- [ ] 配置自定义域名与 HTTPS 证书
- [ ] 设置监控告警（AOM）
- [ ] 配置日志告警规则（LTS）
- [ ] 编写租户入驻流程文档
- [ ] 配置 CI/CD 自动化部署
