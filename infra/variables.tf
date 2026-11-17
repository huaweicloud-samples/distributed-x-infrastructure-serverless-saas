# ============================================================
# Terraform 变量定义
# 敏感变量请通过环境变量或 tfvars 传入，切勿提交到版本库
# ============================================================

variable "region" {
  description = "部署区域"
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "资源命名前缀"
  type        = string
  default     = "serverless-saas"
}

variable "environment" {
  description = "环境标识：dev / staging / prod"
  type        = string
  default     = "dev"
}

# ---------- 网络 ----------
variable "vpc_cidr" {
  description = "VPC 网段"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "子网网段"
  type        = string
  default     = "10.0.1.0/24"
}

# ---------- OBS ----------
variable "obs_bucket_name" {
  description = "OBS 代码桶基础名（桶名全局唯一，部署时会自动追加账户 ID 后缀）"
  type        = string
  default     = "serverless-saas-assets"
}

# ---------- GeminiDB ----------
variable "geminidb_password" {
  description = "GeminiDB 实例管理员密码与业务账号密码"
  type        = string
  sensitive   = true
}

variable "geminidb_account_name" {
  description = "GeminiDB 业务账号名（不能使用内置 root 账号名）"
  type        = string
  default     = "saas_app"
}

variable "geminidb_database" {
  description = "GeminiDB 业务数据库名"
  type        = string
  default     = "serverless_saas"
}

variable "geminidb_replica_set" {
  description = "GeminiDB Mongo 副本集名称（客户端连接时需指定）"
  type        = string
  default     = "replica"
}

variable "geminidb_spec_code" {
  description = "GeminiDB Mongo 副本集实例规格编码"
  type        = string
  default     = "geminidb.mongodb.repset.large.4"
}

variable "geminidb_node_num" {
  description = "GeminiDB 节点数量（副本集模式建议 3，开发可降配为 1）"
  type        = number
  default     = 3
}

variable "geminidb_storage_size" {
  description = "GeminiDB 存储容量（GB）"
  type        = number
  default     = 100
}

variable "geminidb_storage_type" {
  description = "GeminiDB 存储类型：ULTRAHIGH / HIGH / MEDIUM"
  type        = string
  default     = "ULTRAHIGH"
}

# ---------- 认证 ----------
variable "jwt_secret" {
  description = "自定义认证函数用于校验 JWT 的 HMAC 签名密钥（HS256）"
  type        = string
  sensitive   = true
}

# ---------- APIG ----------
variable "apig_instance_edition" {
  description = "APIG 专享实例规格（BASIC / STANDARD 等）"
  type        = string
  default     = "BASIC"
}

variable "public_ingress_enabled" {
  description = "是否为租户端 APIG 实例启用公网入口带宽（启用后通过 ingress_bandwidth_* 开通，与 eip_id 互斥）"
  type        = bool
  default     = true
}

variable "ingress_bandwidth_size" {
  description = "公网入口带宽大小（MB/s），仅在 public_ingress_enabled 为 true 时生效"
  type        = number
  default     = 5
}

variable "ingress_bandwidth_charging_mode" {
  description = "公网入口带宽模式：bandwidth（按带宽）/ traffic（按流量）"
  type        = string
  default     = "bandwidth"
}

# ---------- FunctionGraph ----------
variable "fgs_app_name" {
  description = "FunctionGraph 应用名（仅允许小写字母、数字与下划线）"
  type        = string
  default     = "serverless_saas"
}

variable "fgs_runtime" {
  description = "FunctionGraph Python 运行时版本"
  type        = string
  default     = "Python3.9"
}

variable "log_level" {
  description = "函数日志级别：DEBUG / INFO / WARNING / ERROR"
  type        = string
  default     = "INFO"
}

variable "metrics_namespace" {
  description = "自定义指标命名空间"
  type        = string
  default     = "ServerlessSaaS"
}

# ---------- 日志 ----------
variable "log_retention_days" {
  description = "LTS 日志保留天数"
  type        = number
  default     = 30
}
