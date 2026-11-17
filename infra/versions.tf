# ============================================================
# Terraform 版本与 Provider 约束
# 华为云区域: cn-north-4
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = ">= 1.72"
    }
  }
}

# 访问密钥通过环境变量 HW_ACCESS_KEY / HW_SECRET_KEY 提供（provider 原生读取，
# 使用 STS 临时凭据时额外提供 HW_SECURITY_TOKEN）。切勿把访问密钥写入任何代码或配置文件。
provider "huaweicloud" {
  region = var.region
}

locals {
  name_prefix = var.project_name

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
