# 华为云 Serverless SaaS 多租户架构

## 1. 架构概述

本方案基于华为云 Serverless 服务（APIG、FunctionGraph、GeminiDB、OBS、LTS、IAM）构建完整的多租户 SaaS 参考架构，采用 Pooled（共享）部署模式，通过数据层隔离实现多租户。

### 1.1 核心设计目标

- **多租户隔离**: 租户间数据完全隔离，单库 + 按租户拆分集合
- **Serverless 优先**: 核心业务使用 FunctionGraph，无服务器运维
- **弹性扩展**: 基于 APIG 流量限制和 FunctionGraph 自动扩缩容
- **分级套餐**: 支持 Basic/Standard/Premium/Platinum 四级租户套餐

### 1.2 华为云服务清单

| 服务 | 用途 | 规格说明 |
|------|------|---------|
| APIG | 多租户 API 网关 | 双实例（Admin 内网 / Tenant 公网），BASIC 版 |
| FunctionGraph | 核心业务逻辑 | Python 3.9 运行时，4 个函数 |
| GeminiDB | 多租户数据存储 | MongoDB 副本集，3 节点，100 GB |
| OBS | 函数代码包托管 | 标准存储，私有桶，桶策略授权委托读取 |
| IAM | 身份与访问管理 | AX 角色 + FGS 执行委托 |
| LTS | 日志管理 | 日志组 + 日志流，30 天保留 |
| VPC | 虚拟私有网络 | 1 个 VPC + 1 个子网 + 安全组 |

---

## 2. 架构图

```
┌────────────────────────────────────────────────────────────────────┐
│                        租户终端用户 / 客户端                        │
│                 APIG 租户端实例（公网入口）                          │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ HTTPS + JWT
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                  APIG（Admin + Tenant 两个专享实例）                │
│         自定义认证器：JWT 校验 + 租户上下文注入 + 分级限流           │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ event
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                     FunctionGraph（Python 3.9）                     │
│        tenant-mgmt / product / order / authorizer（4 个函数）       │
│                    结构化日志 + 指标记录                            │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ data
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│              GeminiDB MongoDB 副本集：单库设计                      │
│   tenants / settings（全局）+ products_<租户ID> / orders_<租户ID>   │
└────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────┐
  │ APIG 管理端  │  │ OBS 代码桶   │  │ IAM 委托     │  │  LTS    │
  │（内网 + IAM  │  │              │  │（FGS → OBS / │  │（日志） │
  │  认证）      │  │              │  │  VPC）       │  │         │
  └──────────────┘  └──────────────┘  └──────────────┘  └─────────┘
```

---

## 3. 多租户隔离策略

### 3.1 Pooled 模式（共享部署，本方案实现）

多个租户共享同一套基础设施，通过集合名在数据层隔离：

```
请求 → APIG → 自定义认证器（注入 tenantId）→ FunctionGraph → GeminiDB 集合
                                                                          ↓
                                          products_acme    （租户 A 数据）
                                          products_tenantb （租户 B 数据）
```

**特点**:
- 资源共享度高：共享计算资源与数据库实例
- 隔离级别：数据层隔离（集合级别）
- 隔离实现：集合名统一由 `common.tenant_collection()` 生成，拼接前先用严格字符集校验租户 ID，避免集合名注入

### 3.2 Silo 模式（独立部署，架构预留）

每个租户拥有独立的基础设施：

```
请求 → APIG → 自定义认证器 → FunctionGraph → 独立 GeminiDB 实例
```

**特点**:
- 隔离最强：完全独立资源
- 资源独占：每个租户独立实例
- 适用场景：大型企业租户或有合规要求的租户
- 当前实现：数据模型已预留 `dedicatedTenancy` 字段，标识租户是否要求独立部署

---

## 4. 数据模型

### 4.1 核心集合结构

#### tenants（租户详情，全局集合）
```json
{
  "tenantId": "acme-corp",
  "tenantName": "Acme Corporation",
  "tenantAddress": "123 Main St",
  "tenantEmail": "admin@acme.com",
  "tenantPhone": "+86-10-12345678",
  "tenantTier": "PLATINUM",
  "dedicatedTenancy": false,
  "isActive": true,
  "apiGatewayUrl": "https://xxx.apic.cn-north-4.huaweicloudapis.com",
  "createdAt": "2026-01-15T10:00:00+00:00"
}
```

#### products_<租户ID>（产品，按租户分集合）
```json
{
  "tenantId": "acme-corp",
  "productId": "PROD-001",
  "productName": "Widget A",
  "productDescription": "High-quality widget",
  "price": 99.99,
  "category": "Electronics",
  "stock": 100,
  "createdAt": "2026-01-15T10:00:00+00:00",
  "updatedAt": "2026-01-15T10:00:00+00:00"
}
```

#### orders_<租户ID>（订单，按租户分集合）
```json
{
  "tenantId": "acme-corp",
  "orderId": "ORD-001",
  "productId": "PROD-001",
  "quantity": 5,
  "unitPrice": 99.99,
  "totalAmount": 499.95,
  "status": "PENDING",
  "createdAt": "2026-01-15T11:00:00+00:00",
  "updatedAt": "2026-01-15T11:00:00+00:00"
}
```

### 4.2 集合划分策略

| 集合 | 范围 | 隔离方式 | 说明 |
|----|-----|---------|------|
| tenants | 全局 | `tenantId` 字段 | 租户数有限，无需分集合 |
| settings | 全局 | 配置键 | 存放共享配置（如 `apiGatewayUrl-Pooled`） |
| products_<租户ID> | 按租户 | 集合名 | 每个租户独立产品空间 |
| orders_<租户ID> | 按租户 | 集合名 | 每个租户独立订单空间 |

> 说明：GeminiDB MongoDB 副本集模式为单分片部署，不支持 DynamoDB 式的分片表，因此本方案不再使用 `shardId` 哈希字段，改用集合名承载隔离维度。

---

## 5. API 设计

### 5.1 Admin API（运营管理，APIG 内网实例，IAM 认证）

| 方法 | 路径 | 说明 | 对应资源 |
|------|------|------|----------|
| POST | /tenant | 创建租户 | `apig_api.admin_create_tenant` |
| GET | /tenants | 获取租户列表 | `apig_api.admin_list_tenants` |

> 其余租户管理操作（查询、更新、删除、启停）已由 `tenant_management` 函数实现并可通过同一函数直接扩展 API 定义。

### 5.2 Tenant API（租户业务，APIG 公网实例，自定义认证器）

| 方法 | 路径 | 说明 | 对应资源 |
|------|------|------|----------|
| GET | /products | 列出产品 | `apig_api.tenant_list_products` |
| GET | /products/{id} | 获取产品 | `apig_api.tenant_get_product` |
| POST | /products | 创建产品 | `apig_api.tenant_create_product` |
| GET | /orders | 列出订单 | 由 `order_service` 处理 |
| GET | /orders/{id} | 获取订单 | `apig_api.tenant_get_order` |
| POST | /orders | 创建订单 | `apig_api.tenant_create_order` |

---

## 6. 流量限制策略

采用一条 `API-based` 类型的限流策略，按 APP 维度分别设配额：

| 套餐 | 请求限额 | 说明 |
|------|---------|------|
| BASIC | 50 req/min | 基础限额 |
| STANDARD | 100 req/min | 基础业务 |
| PREMIUM | 150 req/min | 中型业务 |
| PLATINUM | 200 req/min | 大型企业 |

策略通过 `huaweicloud_apig_throttling_policy_associate` 与已发布的 API 关联。

---

## 7. 安全性设计

### 7.1 认证流程

```
1. 租户用户登录 → 获取 JWT token（HS256 共享密钥签名）
2. 请求携带 Authorization: Bearer <token>
3. APIG 自定义认证器（network_type = V2）触发 authorizer 函数
4. 函数校验 JWT 签名与有效期，并回查数据库确认租户处于启用状态
5. 验证通过后注入 tenantId 到请求上下文
6. 业务函数从 requestContext.authorizer 获取 tenantId
```

管理端 API 使用 IAM 认证，不经过自定义认证器。

### 7.2 数据隔离

- **网络层**: VPC 网络隔离，安全组只放通函数子网到数据库端口 8635
- **应用层**: 集合级别隔离，每个租户独立数据空间；集合名由统一函数生成并做字符集校验
- **API 层**: APIG 限流策略，防止跨租户资源耗尽
- **执行层**: FunctionGraph 通过 IAM 委托访问 OBS 与 VPC，函数自身不带 AK/SK

---

## 8. 高可用设计

- **APIG**: 双实例部署（Admin / Tenant），显式指定可用区
- **FunctionGraph**: 函数级自动扩缩容，按调用量付费
- **GeminiDB**: MongoDB 副本集，3 节点高可用
- **OBS**: 多副本存储，11 个 9 持久性
- **VPC**: 独立子网承载函数与数据库，安全组按最小权限放通
