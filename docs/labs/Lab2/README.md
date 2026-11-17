# Lab 2：API 网关与认证

## 目标

学习使用 APIG 实现 API 认证与授权。

## 架构

- 两个 APIG 专享实例：管理端（内网 + IAM 认证）、租户端（公网 + 自定义认证）
- 自定义认证器 `network_type = "V2"`，对应 FunctionGraph v2 运行时
- JWT Token 验证（HS256 共享密钥）

```
租户端请求
   │  Authorization: Bearer <jwt>
   ▼
APIG 租户端实例 ──► 自定义认证器 ──► authorizer 函数
   │                                      │
   │                          校验签名 / 有效期 / 租户状态
   │                                      │
   └────────── 注入 tenantId 到请求上下文 ◄─┘
   ▼
业务函数 → 从 requestContext.authorizer 读取 tenantId
```

## 步骤

### 1. 创建 APIG 实例

```bash
terraform apply -target=huaweicloud_apig_instance.admin
terraform apply -target=huaweicloud_apig_instance.tenant
```

公网入口通过 `ingress_bandwidth_size` + `ingress_bandwidth_charging_mode` 开通（与 `eip_id` 互斥，二选一）。

### 2. 部署认证函数

```bash
terraform apply -target=huaweicloud_fgs_function.tenant_authorizer
```

认证函数要点：

```python
# src/functions/authorizer.py
def verify_token(token):
    """校验 JWT（HS256）"""
    return jwt.decode(
        token,
        JWT_SECRET_KEY,          # 来自环境变量 JWT_SECRET_KEY
        algorithms=['HS256'],
        options={'verify_signature': True, 'verify_exp': True}
    )

def handler(event, context):
    headers = event.get('headers', {}) or {}
    auth_header = headers.get('Authorization') or headers.get('authorization', '')

    if not auth_header:
        return _deny_response("Missing authentication")

    bearer = auth_header[7:] if auth_header.lower().startswith('bearer ') else auth_header
    payload = verify_token(bearer)
    if not payload:
        return _deny_response("Invalid token")

    tenant_id = payload.get('tenant_id') or payload.get('tenantId', 'pooled')
    user_role = payload.get('user_role') or payload.get('userRole', 'user')

    # 非管理员需回查数据库确认租户状态
    if user_role != 'SystemAdmin':
        tenant = get_tenant_from_db(tenant_id)
        if not tenant:
            return _deny_response("Tenant not found")
        if not tenant.get('isActive', False):
            return _deny_response("Tenant is inactive")

    return _allow_response({'tenantId': tenant_id, 'userRole': user_role})
```

APIG 自定义认证器的返回格式是 `isAuthorized` 字段，而不是 `principalId`：

```python
def _allow_response(context):
    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps({'isAuthorized': True, 'context': context})
    }
```

### 3. 创建认证器并绑定到 API

```bash
terraform apply -target=huaweicloud_apig_custom_authorizer.tenant
terraform apply -target=huaweicloud_apig_api.tenant_get_product
```

API 定义中通过 `security_authentication = "AUTHORIZER"` 与顶层 `authorizer_id` 关联认证器。

### 4. 签发测试令牌

```python
import jwt, time
token = jwt.encode(
    {"tenant_id": "acme-corp", "user_role": "user", "sub": "user-1",
     "exp": int(time.time()) + 3600},
    "<jwt_secret>",
    algorithm="HS256",
)
```

## 验证

- [ ] 有效 Token 可以访问租户端 API
- [ ] 无效 Token 返回 401（`isAuthorized: false`）
- [ ] Token 过期后无法访问
- [ ] 已停用租户的 Token 被拒绝
- [ ] 管理端 API 不经过认证器，直接使用 IAM 认证

## 清理

```bash
terraform destroy -target=huaweicloud_apig_custom_authorizer.tenant
terraform destroy -target=huaweicloud_apig_api.tenant_get_product
```
