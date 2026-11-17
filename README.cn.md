# 华为云 Serverless SaaS 多租户参考架构

![License](https://img.shields.io/badge/License-MIT-0?style=flat-square)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-Serverless%20SaaS-Blue?style=flat-square)
![Terraform](https://img.shields.io/badge/Terraform-1.5%2B-purple?style=flat-square)

[English](README.md)

## 1. 简介 / 概述

本项目是基于华为云 Serverless 服务构建的**多租户 SaaS 参考架构**，实现了一套完整的多租户 SaaS 后端，包含分层套餐、JWT 认证、租户级数据隔离与 API 限流。核心功能包括：

- **多租户管理**：Pooled 部署模式，通过按租户拆分集合实现数据隔离
- **分层套餐**：Basic / Standard / Premium / Platinum 四级租户套餐，每级对应独立的 APIG 凭据与请求配额
- **API 网关**：两个 APIG 专享实例（内网管理端 + 公网租户端），租户端挂载自定义 JWT 认证器
- **弹性扩展**：FunctionGraph 无服务器计算，按调用量付费
- **数据隔离**：GeminiDB MongoDB 副本集，单库 + 按租户拆分集合

适用于需要快速构建多租户 SaaS 后端的企业，特别是电商、CRM、ERP 等 B2B 应用场景。

---

## 2. 架构图

```
┌────────────────────────────────────────────────────────────────────┐
│                        租户终端用户 / 客户端                        │
│              APIG 租户端实例（公网入口）                            │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ HTTPS + JWT
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│           APIG 租户端实例：自定义认证器 + 限流策略                  │
│      4 组 APP 凭据（Basic / Standard / Premium / Platinum）         │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ event
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                     FunctionGraph（Python 3.9）                     │
│       tenant-mgmt / product / order / authorizer（4 个函数）        │
│              结构化日志 + LTS 日志流上报                           │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ data
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│           GeminiDB MongoDB 副本集：单库设计                         │
│    tenants / settings（全局）+ products_<租户ID> / orders_<租户ID>  │
└────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────┐
  │ APIG 管理端  │  │ OBS 桶       │  │ IAM 委托     │  │  LTS    │
  │（内网 + IAM  │  │（函数代码包） │  │（FGS → OBS / │  │（日志） │
  │  认证）      │  │              │  │  VPC）       │  │         │
  └──────────────┘  └──────────────┘  └──────────────┘  └─────────┘
```

---

## 3. 核心特性

| 特性 | 说明 |
|------|------|
| **Serverless 优先** | 核心业务逻辑跑在 FunctionGraph 上，无需维护服务器集群 |
| **多租户隔离** | Pooled 模式；单库 + 按租户拆分集合（`products_<租户ID>`） |
| **分层套餐** | 四个套餐分别映射到独立 APIG APP 凭据，各有独立请求配额 |
| **华为云原生** | APIG、FunctionGraph、GeminiDB、OBS、LTS、IAM，无第三方组件 |
| **IaC 管理** | Terraform 管理全部资源，一条命令完成部署与销毁 |
| **可复现构建** | 一个脚本完成四个函数的打包并由 Terraform 交付到 OBS |

---

## 4. 云服务

### 4.1 服务清单

| 服务 | 规格 | 用途 |
|------|------|------|
| APIG | 2 个专享实例（BASIC） | 管理端（内网）与租户端（公网）API 入口 |
| FunctionGraph | Python 3.9 运行时，4 个函数 | 租户、产品、订单业务逻辑与授权器 |
| GeminiDB | MongoDB 副本集，3 节点，100 GB | 多租户数据持久化 |
| OBS | 标准存储，私有桶 | 函数代码包托管 |
| LTS | 日志组 + 日志流 | 运行期日志采集与保留 |
| IAM | 委托 + AX 角色 | 赋予 FunctionGraph 读代码包与接入 VPC 的权限 |
| VPC | 1 个 VPC + 1 个子网 + 安全组 | 函数与数据库的网络平面 |

### 4.2 资源清理

> 实践验证完成后，请按「清理资源」章节销毁本次创建的资源。

---

## 5. 前置条件

- 华为云账号（已完成实名认证）
- Terraform >= 1.5.0
- Python 3.8+（用于打包函数代码）
- 具备 APIG、FunctionGraph、GeminiDB、OBS、LTS、IAM、VPC 权限的华为云 AK/SK

---

## 6. 快速开始 / 一键部署

```bash
# 1. 克隆代码
git clone <repository-url>
cd distributed-x-infrastructure-serverless-saas

# 2. 通过环境变量配置凭据（切勿写入任何文件）
export HW_ACCESS_KEY="<your-access-key>"
export HW_SECRET_KEY="<your-secret-key>"

# 3. 打包函数代码
./scripts/build-packages.sh

# 4. 初始化 Terraform
cd infra
terraform init

# 5. 配置变量
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars，填写 geminidb_password 与 jwt_secret

# 6. 部署
terraform apply -var-file="terraform.tfvars"
```

### 6.1 关键输入变量

| 变量 | 说明 | 必填 | 默认值 |
|------|------|------|--------|
| `region` | 部署区域 | 否 | `cn-north-4` |
| `project_name` | 资源命名前缀 | 否 | `serverless-saas` |
| `environment` | 环境标识（dev / staging / prod） | 否 | `dev` |
| `geminidb_password` | GeminiDB 管理员与业务账号密码 | **是** | — |
| `jwt_secret` | 授权器校验 JWT 用的 HMAC 密钥（HS256） | **是** | — |
| `obs_bucket_name` | OBS 桶基础名 | 否 | `serverless-saas-assets` |
| `geminidb_node_num` | GeminiDB 节点数 | 否 | `3` |
| `public_ingress_enabled` | 是否为租户端 APIG 开通公网入口 | 否 | `true` |
| `ingress_bandwidth_size` | 公网入口带宽（MB/s） | 否 | `5` |
| `log_retention_days` | LTS 日志保留天数 | 否 | `30` |

完整变量清单见 [`infra/variables.tf`](infra/variables.tf)。

---

## 7. 分步部署

详细的分步部署说明见 [docs/deployment-guide.md](docs/deployment-guide.md)。

```bash
# 第 1 步：打包函数代码（产出 build/*.zip）
./scripts/build-packages.sh

# 第 2 步：部署网络层
terraform apply -target=huaweicloud_vpc.main
terraform apply -target=huaweicloud_vpc_subnet.primary

# 第 3 步：部署数据库
terraform apply -target=huaweicloud_geminidb_instance.main
terraform apply -target=huaweicloud_geminidb_account.app

# 第 4 步：部署函数（依赖委托与 OBS 桶）
terraform apply -target=huaweicloud_fgs_function.tenant_management

# 第 5 步：部署 API 网关
terraform apply -target=huaweicloud_apig_instance.tenant
terraform apply -target=huaweicloud_apig_api.tenant_get_product

# 第 6 步：部署其余资源
terraform apply
```

---

## 8. 使用与验证

### 8.1 获取 API 地址

```bash
terraform output apig_info
```

租户端可从公网访问，管理端仅内网可达并使用 IAM 认证。

### 8.2 创建租户（内网管理端 API）

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

### 8.3 签发 JWT 并调用租户端 API

授权器校验使用 `jwt_secret` 签名、HS256 算法的令牌。

```python
import jwt, time
token = jwt.encode(
    {"tenant_id": "acme-corp", "user_role": "user", "sub": "user-1", "exp": int(time.time()) + 3600},
    "<jwt_secret>",
    algorithm="HS256",
)
```

```bash
# 创建产品
curl -X POST "https://<tenant-api-url>/products" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <jwt-token>" \
  -d '{"productName": "Widget A", "price": 99.99, "stock": 10}'

# 查询产品
curl "https://<tenant-api-url>/products/<product-id>" \
  -H "Authorization: Bearer <jwt-token>"

# 下单
curl -X POST "https://<tenant-api-url>/orders" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <jwt-token>" \
  -d '{"productId": "<product-id>", "quantity": 2}'
```

### 8.4 获取 APP 凭据

```bash
terraform output -raw api_keys
```

每个套餐的 `app_key` / `app_secret` 在限流策略中绑定了各自的配额。

---

## 9. 清理资源

```bash
# 销毁全部资源
terraform destroy -var-file="terraform.tfvars"

# 输入 yes 确认
```

> ⚠️ 清理后 GeminiDB 数据将永久丢失，请确认无重要数据后再执行。

---

## 10. 详细说明

### 10.1 多租户隔离

- **存储模型**：单个 GeminiDB 数据库（默认 `serverless_saas`）
- **全局集合**：`tenants` 与 `settings`，按 `tenantId` 字段区分
- **租户集合**：`products_<租户ID>` 与 `orders_<租户ID>`，每个租户一个集合
- **访问控制**：所有读写统一走 `common.tenant_collection()`，该函数先用严格字符集校验租户 ID 再拼接集合名，避免通过集合名注入实现跨租户越权

### 10.2 API 认证流程

```
1. 租户用户登录 → 获取 JWT（HS256，共享密钥）
2. 客户端携带 Authorization: Bearer <token> 请求
3. APIG 自定义认证器（network_type = V2）触发授权器函数
4. 函数校验签名与有效期，并回查数据库确认租户处于启用状态
5. 校验通过后把 tenantId / userRole 注入请求上下文
6. 业务函数从 requestContext.authorizer 读取 tenantId，据此限定所有数据访问
```

管理端 API 使用 IAM 认证，不经过自定义认证器。

### 10.3 数据模型

| 集合 | 范围 | 关键字段 |
|------|------|----------|
| `tenants` | 全局 | `tenantId`、`tenantName`、`tenantTier`、`isActive`、`dedicatedTenancy` |
| `settings` | 全局 | `settingName`、`settingValue`（如 `apiGatewayUrl-Pooled`） |
| `products_<租户ID>` | 按租户 | `productId`、`productName`、`price`、`stock` |
| `orders_<租户ID>` | 按租户 | `orderId`、`productId`、`quantity`、`totalAmount`、`status` |

### 10.4 限流策略

租户端实例上配置一条 `API-based` 限流策略，按 APP 维度分别设配额：

| 套餐 | 每分钟请求数 |
|------|--------------|
| Basic | 50 |
| Standard | 100 |
| Premium | 150 |
| Platinum | 200 |

策略通过 `huaweicloud_apig_throttling_policy_associate` 与已发布的 API 关联。

---

## 11. 依赖

### 主要依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| pymongo | 4.x | GeminiDB MongoDB 连接 |
| PyJWT | 2.x | JWT 签名校验 |

详见 [`src/requirements.txt`](src/requirements.txt)。

---

## 12. 常见问题

**Q: GeminiDB 连接失败？**
A: 检查安全组规则——函数所在子网必须放通 8635 端口；同时确认账号已被授予 `serverless_saas` 数据库的权限。

**Q: APIG 返回 401？**
A: 查看 LTS 中授权器函数的日志，确认令牌是用与 `jwt_secret` 相同的密钥做 HS256 签名且未过期。

**Q: 部署后函数首次调用失败？**
A: 挂载 VPC 的函数需要委托生效，绑定 VPC 后的首次冷启动明显更慢，稍等片刻重试即可。

**Q: 如何调整套餐配额？**
A: 修改 `infra/main.tf` 中的 `app_throttles` 块后重新 apply。

**Q: `terraform apply` 报代码包找不到？**
A: 先执行 `./scripts/build-packages.sh`——Terraform 需要把 `build/*.zip` 上传到 OBS。

---

## 13. 贡献指南

欢迎提交 Issue 与 Pull Request。

```bash
# Fork 本仓库
# 创建特性分支
git checkout -b feature/your-feature

# 提交改动
git commit -m "Add your feature"

# 推送分支
git push origin feature/your-feature

# 创建 Pull Request
```

---

## 14. 许可协议

[MIT](./LICENSE)
