# Lab 3：租户配置与菜单管理

## 目标

实现租户级别的配置和菜单管理。

## 架构

配置数据落在 GeminiDB 的 `settings` 集合中，与租户详情同属一个数据库：

```
serverless_saas
├── tenants    租户元数据
└── settings   配置项，按 tenantId + settingName 定位
```

## 步骤

### 1. 扩展配置集合

`settings` 集合已在 `common.py` 中定义，无需建表：

```python
# src/functions/common.py
COLLECTION_SETTINGS = 'settings'

def get_settings_collection():
    """全局设置集合"""
    return get_database()[COLLECTION_SETTINGS]
```

### 2. 实现配置管理

配置项以 `tenantId` + `settingName` 为定位键：

```python
# src/functions/tenant_management.py
def update_tenant(event, context):
    """更新租户信息——配置项复用同一入口"""
    body = json.loads(event.get('body') or '{}')
    update_fields = {k: v for k, v in body.items() if k not in ('tenantId', '_id')}
    update_fields['updatedAt'] = _now_iso()

    result = get_tenant_collection().update_one(
        {'tenantId': tenant_id},
        {'$set': update_fields}
    )
```

写入共享配置（如 Pooled 租户的 API 网关地址）：

```python
settings = get_settings_collection().find_one({'settingName': 'apiGatewayUrl-Pooled'})
api_gateway_url = settings.get('settingValue', '') if settings else ''
```

### 3. 部署

```bash
terraform apply -target=huaweicloud_fgs_function.tenant_management
```

## 验证

- [ ] 租户可以查看自己的配置
- [ ] 租户可以修改自己的配置
- [ ] 配置变更立即生效
- [ ] 一个租户的修改不影响另一个租户的同名配置项
