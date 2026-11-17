# Lab 4：订阅与用量统计

## 目标

实现 SaaS 订阅管理和用量统计。

## 架构

本方案用两层机制实现「套餐 + 用量」：

| 层次 | 承载物 | 说明 |
|------|--------|------|
| 套餐归属 | `tenants` 集合的 `tenantTier` 字段 | 记录租户所属套餐（BASIC / STANDARD / PREMIUM / PLATINUM） |
| 调用配额 | APIG 限流策略的 `app_throttles` | 按 APP 凭据维度限制每分钟请求数 |
| 用量记录 | LTS 日志中的 `[METRIC]` 结构化行 | 函数每次写操作输出一条计量记录 |

```
tenantTier (数据层)  ──►  决定该租户应使用哪一组 APP 凭据
app_throttles (网关层) ──►  按凭据维度强制执行每分钟上限
[METRIC] 日志行 (观测层) ──►  记录每次操作的计数，供统计与告警
```

## 步骤

### 1. 确认限流策略

```bash
terraform output throttling_policy
```

一条 `API-based` 类型的策略，四个 APP 各自绑定独立配额：

```hcl
# infra/main.tf
resource "huaweicloud_apig_throttling_policy" "tiers" {
  type             = "API-based"
  period           = 1
  period_unit      = "MINUTE"
  max_api_requests = 200

  app_throttles {
    max_api_requests     = 50
    throttling_object_id = huaweicloud_apig_application.basic.id
  }
  # standard 100 / premium 150 / platinum 200
}
```

### 2. 取各套餐凭据

```bash
terraform output -raw api_keys
```

每组 `app_key` / `app_secret` 对应一个套餐，按租户的 `tenantTier` 分发即可。

### 3. 用量记录

业务函数在关键操作后写一条计量记录：

```python
# src/functions/utils.py
def record_metric(event, metric_name, unit, value):
    metric_data = {
        'metric_name': metric_name,
        'unit': unit,
        'value': value,
        'tenant_id': tenant_id,
        'timestamp': datetime.now(timezone.utc).isoformat()
    }
    print(f"[METRIC] {json.dumps(metric_data, ensure_ascii=False)}")
```

产出的记录可在 LTS 中按 `metric_name` 检索，例如 `TenantCreated`、`ProductCreated`、`OrderCreated`。

### 4. 部署

```bash
terraform apply -target=huaweicloud_apig_throttling_policy.tiers
terraform apply -target=huaweicloud_apig_throttling_policy_associate.tiers
```

## 验证

- [ ] 四个套餐的凭据可正常获取且互不相同
- [ ] 超出套餐配额的请求被网关拒绝
- [ ] LTS 中能检索到各租户的 `[METRIC]` 记录
- [ ] 记录中的 `tenant_id` 与调用方一致
