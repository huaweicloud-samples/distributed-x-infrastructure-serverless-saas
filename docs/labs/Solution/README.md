# 完整解决方案

本目录是各实验对应的参考实现说明。完整可运行的代码不在此处重复维护，而是集中在仓库的 `src/` 与 `infra/` 两个目录中——每个实验引用同一套实现，避免文档与代码脱节。

## 仓库结构

```
distributed-x-infrastructure-serverless-saas/
├── infra/                     完整 IaC 代码（Terraform）
│   ├── main.tf                全部资源定义
│   ├── variables.tf           变量定义
│   ├── outputs.tf             输出定义
│   ├── versions.tf            provider 与凭据读取方式
│   └── terraform.tfvars.example
├── src/                       函数源代码
│   ├── functions/
│   │   ├── tenant_management.py   租户管理
│   │   ├── product_service.py     产品服务
│   │   ├── order_service.py       订单服务
│   │   ├── authorizer.py          APIG 自定义认证器
│   │   ├── common.py              数据访问层
│   │   ├── logger.py              结构化日志
│   │   └── utils.py               响应封装与计量
│   └── requirements.txt
├── scripts/build-packages.sh  函数打包脚本
├── docs/
│   ├── architecture.md         架构说明
│   ├── deployment-guide.md     部署指南
│   └── labs/                   各实验说明
└── build/                     打包产物（生成物，不入库）
```

## 实验与实现的对应关系

| 实验 | 对应实现 | 关键 IaC 资源 |
|------|---------|--------------|
| Lab 1 租户隔离与数据分层 | `src/functions/common.py` | `huaweicloud_geminidb_instance.main` |
| Lab 2 API 网关与认证 | `src/functions/authorizer.py` | `huaweicloud_apig_custom_authorizer.tenant` |
| Lab 3 租户配置与菜单管理 | `src/functions/tenant_management.py` | `huaweicloud_fgs_function.tenant_management` |
| Lab 4 订阅与用量统计 | `src/functions/utils.py` | `huaweicloud_apig_throttling_policy.tiers` |
| Lab 5 监控与告警 | `src/functions/logger.py` | `huaweicloud_lts_group.app` / `huaweicloud_lts_stream.app` |
| Lab 6 扩展性与性能优化 | `src/functions/common.py` | `huaweicloud_fgs_function.*` |
| Lab 7 安全加固 | `infra/main.tf` | `huaweicloud_identity_agency.fgs` / `huaweicloud_obs_bucket_policy.assets` |

## 快速开始

```bash
# 1. 配置凭据
export HW_ACCESS_KEY="<您的 Access Key>"
export HW_SECRET_KEY="<您的 Secret Key>"

# 2. 打包函数代码
./scripts/build-packages.sh

# 3. 部署
cd infra
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars，填写 geminidb_password 与 jwt_secret
terraform init
terraform apply -var-file="terraform.tfvars"
```

详细步骤见 [../../deployment-guide.md](../../deployment-guide.md)。

## 验证清单

全部实验完成后，系统应具备：

- [ ] 多租户数据隔离（集合名隔离，跨租户不可见）
- [ ] API 认证授权（JWT + 自定义认证器 + 租户状态校验）
- [ ] 租户配置管理
- [ ] 用量统计（套餐配额 + `[METRIC]` 记录）
- [ ] 监控告警（LTS 结构化日志）
- [ ] 安全加固（凭据不落盘、最小权限、私网访问）
