# Lab 5：监控与告警

## 目标

实现租户级别的日志采集与监控告警。

## 架构

| 组件 | 作用 |
|------|------|
| LTS 日志组 | 承载本方案所有运行期日志，保留 30 天 |
| LTS 日志流 | 函数统一上报到同一条流，便于按关键字检索 |
| 结构化日志 | 每条日志含 `timestamp` / `service` / `level` / `message` |
| 计量记录 | `[METRIC]` 前缀的 JSON 行，含租户维度 |

## 步骤

### 1. 部署日志资源

```bash
terraform apply -target=huaweicloud_lts_group.app
terraform apply -target=huaweicloud_lts_stream.app
```

日志组与日志流由 Terraform 管理，保留期通过变量调整：

```hcl
# infra/variables.tf
variable "log_retention_days" {
  description = "LTS 日志保留天数"
  type        = number
  default     = 30
}
```

### 2. 函数开启 LTS 上报

每个函数都需显式开启日志上报并绑定日志组与日志流：

```hcl
# infra/main.tf
resource "huaweicloud_fgs_function" "product_service" {
  # ...
  enable_lts_log = true
  log_group_id   = huaweicloud_lts_group.app.id
  log_stream_id  = huaweicloud_lts_stream.app.id
}
```

### 3. 结构化日志输出

```python
# src/functions/logger.py
def info(self, message):
    print(json.dumps({
        'timestamp': self._now(),
        'service': self.service_name,
        'level': 'INFO',
        'message': message,
    }, ensure_ascii=False))
```

带租户上下文的日志会额外带上 `tenant_id`：

```python
def log_with_tenant_context(self, event, message):
    tenant_id = event.get('requestContext', {}).get('authorizer', {}).get('tenantId', 'unknown')
    print(json.dumps({
        'timestamp': self._now(),
        'service': self.service_name,
        'tenant_id': tenant_id,
        'message': message,
    }, ensure_ascii=False))
```

### 4. 查看日志

```bash
# 获取日志组与日志流 ID
terraform output lts_info
```

在 LTS 控制台按以下关键字检索：

| 关键字 | 用途 |
|--------|------|
| `"level":"ERROR"` | 定位错误 |
| `"tenant_id":"acme-corp"` | 按租户过滤 |
| `[METRIC]` | 提取用量记录 |
| `Authorization successful` | 排查认证链路 |

## 验证

- [ ] 函数日志能写入指定的日志组与日志流
- [ ] 日志为结构化 JSON，可按字段检索
- [ ] 日志中包含正确的 `tenant_id`
- [ ] `[METRIC]` 记录可被单独检索出来

## 清理

```bash
terraform destroy -target=huaweicloud_lts_stream.app
terraform destroy -target=huaweicloud_lts_group.app
```
