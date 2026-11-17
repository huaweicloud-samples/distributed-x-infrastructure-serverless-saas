# Lab 7：安全加固

## 目标

实现 SaaS 应用的安全加固。

## 内容

- 凭据管理
- VPC 私有网络与安全组
- 最小权限原则
- 审计日志

## 步骤

### 1. 凭据不落盘

访问密钥通过环境变量传给 provider，切勿写入 tfvars 或任何文件：

```bash
export HW_ACCESS_KEY="<您的 Access Key>"
export HW_SECRET_KEY="<您的 Secret Key>"
```

`terraform.tfvars` 中只放业务参数，敏感项用 `sensitive = true` 标注：

```hcl
# infra/variables.tf
variable "geminidb_password" {
  description = "GeminiDB 实例管理员密码与业务账号密码"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "自定义认证函数用于校验 JWT 的 HMAC 签名密钥（HS256）"
  type        = string
  sensitive   = true
}
```

> 注意：FunctionGraph 的环境变量模型会把值注入到函数运行环境中。虽然函数本身运行在 VPC 内、访问需要 IAM 委托，但生产环境仍建议改用加密环境变量或专门的凭据管理服务。

### 2. VPC 私有网络与安全组

函数与数据库都在 VPC 内，安全组按最小权限放通：

```hcl
# infra/main.tf
resource "huaweicloud_networking_secgroup_rule" "allow_mongo" {
  security_group_id = huaweicloud_networking_secgroup.saas.id
  direction         = "ingress"
  protocol          = "tcp"
  port_range_min    = 8635
  port_range_max    = 8635
  remote_ip_prefix  = var.vpc_cidr   # 只放通 VPC 内网，不放通 0.0.0.0/0
}
```

管理端 APIG 实例为 `Private` 类型，仅内网可达；租户端才开放公网入口。

### 3. 最小权限原则

FunctionGraph 通过 IAM 委托访问资源，函数代码中不含任何 AK/SK：

```hcl
resource "huaweicloud_identity_agency" "fgs" {
  name                  = "${local.name}-fgs-agency"
  delegated_domain_name = "op_svc_cff"
  domain_roles          = [huaweicloud_identity_role.fgs_runner.name]

  project_role {
    project = data.huaweicloud_identity_projects.project.projects[0].id
    roles   = [huaweicloud_identity_role.fgs_runner.name]
  }
}
```

OBS 桶为私有桶，且通过桶策略精确授权到 `code/*` 路径：

```hcl
resource "huaweicloud_obs_bucket_policy" "assets" {
  bucket = huaweicloud_obs_bucket.assets.bucket

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowFgsAgencyReadCode"
      Effect    = "Allow"
      Principal = "domain/${data.huaweicloud_account.current.id}:agency/${huaweicloud_identity_agency.fgs.name}"
      Action    = ["obs:object:getObject", "obs:object:listObjects"]
      Resource  = "${huaweicloud_obs_bucket.assets.bucket}/code/*"
    }]
  })
}
```

### 4. 认证安全

- JWT 使用 HS256 签名，`jwt.decode` 开启 `verify_signature` 与 `verify_exp`
- 非管理员请求必须回查数据库确认租户处于启用状态
- 租户 ID 在拼接集合名前做字符集校验，阻断集合名注入

```python
_TENANT_ID_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')
```

### 5. 审计日志

授权器记录每一次认证结果，便于事后追溯：

```python
logger.info(f"Authorizer invoked with event: {json.dumps(event, default=str)}")
logger.info(f"Authorization successful for tenant: {tenant_id}")
logger.warning("Token verification failed")
```

LTS 日志保留期由 `log_retention_days` 控制，合规场景可适当延长。

## 验证

- [ ] 代码仓内无任何明文凭据（跑一遍凭据扫描）
- [ ] `terraform.tfvars` 未被提交到版本库
- [ ] 数据库端口只对 VPC 内网放通
- [ ] 管理端 API 无法从公网访问
- [ ] OBS 桶为私有，桶策略仅授权 `code/*`
- [ ] 认证失败与成功都有审计记录
