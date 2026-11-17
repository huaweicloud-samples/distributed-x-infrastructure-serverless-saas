# Lab 1：租户隔离与数据分层

## 目标

学习如何在华为云上实现多租户数据隔离。

## 架构

本实验使用 GeminiDB MongoDB 的集合级别数据隔离：

- **单库模型**：所有租户共用一个数据库 `serverless_saas`
- **按租户分集合**：产品存放在 `products_<租户ID>`，订单存放在 `orders_<租户ID>`
- **全局集合**：租户元数据存放在 `tenants`，按 `tenantId` 字段区分

```
serverless_saas (数据库)
├── tenants          全局集合，租户元数据
├── settings         全局集合，共享配置
├── products_acme    租户 acme-corp 的产品
├── products_globex  租户 globex 的产品
├── orders_acme      租户 acme-corp 的订单
└── orders_globex    租户 globex 的订单
```

## 步骤

### 1. 部署数据库

```bash
terraform apply -target=huaweicloud_geminidb_instance.main
terraform apply -target=huaweicloud_geminidb_account.app
```

副本集模式下数据库监听 8635 端口，安全组规则 `allow_mongo` 只放通 VPC 内的该端口。

### 2. 理解集合名生成规则

隔离的关键在于所有集合名都由统一函数生成，拼接前校验租户 ID：

```python
# src/functions/common.py
_TENANT_ID_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')

def tenant_collection(base, tenant_id):
    """获取租户私有集合"""
    if not tenant_id or not _TENANT_ID_RE.match(str(tenant_id)):
        raise ValueError(f"Invalid tenantId: {tenant_id!r}")
    return get_database()[f"{base}_{tenant_id}"]
```

字符集校验是必要的——否则攻击者可以通过构造 `tenantId` 注入集合名，访问到其他租户的数据。

### 3. 写入租户数据

```bash
# 在管理端创建租户（内网 API，IAM 认证）
curl -X POST "https://<admin-api-url>/tenant" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: <iam-token>" \
  -d '{"tenantId": "acme-corp", "tenantName": "Acme", "tenantTier": "PLATINUM"}'
```

### 4. 验证隔离效果

用两个不同租户的 JWT 分别调用租户端 API：

```bash
# 租户 A 创建产品
curl -X POST "https://<tenant-api-url>/products" \
  -H "Authorization: Bearer <token-acme>" \
  -d '{"productName": "Product A", "price": 10}'

# 租户 B 查询产品列表——结果中不应出现 Product A
curl "https://<tenant-api-url>/products" \
  -H "Authorization: Bearer <token-globex>"
```

## 验证

- [ ] 租户元数据正确写入 `tenants` 集合
- [ ] 不同租户的产品落在不同集合中
- [ ] 租户 B 查询不到租户 A 的产品
- [ ] 非法租户 ID（超出字符集）被拒绝，返回 400

## 清理

```bash
# 删除租户（管理端 API）
curl -X DELETE "https://<admin-api-url>/tenant/acme-corp" \
  -H "X-Auth-Token: <iam-token>"

# 销毁数据库
terraform destroy -target=huaweicloud_geminidb_instance.main
```
