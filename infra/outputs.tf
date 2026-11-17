# ============================================================
# Terraform 输出定义
# ============================================================

output "project_info" {
  description = "项目基本信息"
  value = {
    project_name = var.project_name
    environment  = var.environment
    region       = var.region
    account_id   = data.huaweicloud_account.current.id
  }
}

# ---------- 网络 ----------
output "vpc_info" {
  description = "VPC 网络信息"
  value = {
    vpc_id      = huaweicloud_vpc.main.id
    vpc_cidr    = huaweicloud_vpc.main.cidr
    subnet_id   = huaweicloud_vpc_subnet.primary.id
    subnet_cidr = huaweicloud_vpc_subnet.primary.cidr
  }
}

# ---------- OBS ----------
output "obs_info" {
  description = "OBS 代码桶信息"
  value = {
    bucket_name   = huaweicloud_obs_bucket.assets.bucket
    bucket_domain = huaweicloud_obs_bucket.assets.bucket_domain_name
  }
}

# ---------- GeminiDB ----------
output "geminidb_info" {
  description = "GeminiDB 数据库信息"
  value = {
    instance_id   = huaweicloud_geminidb_instance.main.id
    instance_name = huaweicloud_geminidb_instance.main.name
    database      = var.geminidb_database
    account       = var.geminidb_account_name
    port          = huaweicloud_geminidb_instance.main.port
  }
  sensitive = true
}

# ---------- FunctionGraph ----------
output "function_info" {
  description = "FunctionGraph 函数信息"
  value = {
    tenant_management = {
      urn  = huaweicloud_fgs_function.tenant_management.urn
      name = huaweicloud_fgs_function.tenant_management.name
    }
    product_service = {
      urn  = huaweicloud_fgs_function.product_service.urn
      name = huaweicloud_fgs_function.product_service.name
    }
    order_service = {
      urn  = huaweicloud_fgs_function.order_service.urn
      name = huaweicloud_fgs_function.order_service.name
    }
    tenant_authorizer = {
      urn  = huaweicloud_fgs_function.tenant_authorizer.urn
      name = huaweicloud_fgs_function.tenant_authorizer.name
    }
  }
}

# ---------- APIG ----------
output "apig_info" {
  description = "APIG API 网关信息"
  value = {
    admin = {
      instance_id = huaweicloud_apig_instance.admin.id
      # 内网域名格式：<groupId>.apic.<region>.huaweicloudapis.com
      url   = "https://${huaweicloud_apig_instance.admin.id}.apic.${var.region}.huaweicloudapis.com"
      group = huaweicloud_apig_group.admin.name
    }
    tenant = {
      instance_id = huaweicloud_apig_instance.tenant.id
      url         = "https://${huaweicloud_apig_instance.tenant.id}.apic.${var.region}.huaweicloudapis.com"
      group       = huaweicloud_apig_group.tenant.name
    }
    authorizer_id  = huaweicloud_apig_custom_authorizer.tenant.id
    environment_id = huaweicloud_apig_environment.release.id
  }
}

output "api_keys" {
  description = "各套餐的 APP 凭据（app_key / app_secret）"
  value = {
    basic = {
      app_key    = huaweicloud_apig_application.basic.app_key
      app_secret = huaweicloud_apig_application.basic.app_secret
    }
    standard = {
      app_key    = huaweicloud_apig_application.standard.app_key
      app_secret = huaweicloud_apig_application.standard.app_secret
    }
    premium = {
      app_key    = huaweicloud_apig_application.premium.app_key
      app_secret = huaweicloud_apig_application.premium.app_secret
    }
    platinum = {
      app_key    = huaweicloud_apig_application.platinum.app_key
      app_secret = huaweicloud_apig_application.platinum.app_secret
    }
  }
  sensitive = true
}

output "throttling_policy" {
  description = "限流策略信息"
  value = {
    name             = huaweicloud_apig_throttling_policy.tiers.name
    type             = huaweicloud_apig_throttling_policy.tiers.type
    period_unit      = huaweicloud_apig_throttling_policy.tiers.period_unit
    period           = huaweicloud_apig_throttling_policy.tiers.period
    max_api_requests = huaweicloud_apig_throttling_policy.tiers.max_api_requests
  }
}

# ---------- 日志 ----------
output "lts_info" {
  description = "LTS 日志信息"
  value = {
    group_id   = huaweicloud_lts_group.app.id
    group_name = huaweicloud_lts_group.app.group_name
    stream_id  = huaweicloud_lts_stream.app.id
  }
}

# ---------- 部署摘要 ----------
output "deployment_summary" {
  description = "部署完成后的关键信息与后续步骤"
  value       = <<-EOT
    ===============================================
    华为云 Serverless SaaS 多租户架构部署完成
    ===============================================

    租户端 API（公网）：
    https://${huaweicloud_apig_instance.tenant.id}.apic.${var.region}.huaweicloudapis.com/${huaweicloud_apig_group.tenant.name}

    管理端 API（内网，IAM 认证）：
    https://${huaweicloud_apig_instance.admin.id}.apic.${var.region}.huaweicloudapis.com/${huaweicloud_apig_group.admin.name}

    下一步：
    1. 用 terraform output -raw api_keys 取各套餐 APP 凭据
    2. 签发 JWT（HS256，密钥与 jwt_secret 一致）并置入 Authorization 头
    3. 调用租户端 API 验证鉴权与限流
    4. 按部署文档第 8 节清理资源
    ===============================================
  EOT
}
