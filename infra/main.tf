# ============================================================
# 华为云 Serverless SaaS 多租户架构 - Terraform IaC
# 参考架构：多租户 SaaS（Pooled / Silo 两种隔离模式）
# 区域：var.region（默认 cn-north-4）
#
# 资源依赖顺序：
#   VPC/子网/安全组
#     -> IAM 委托 + OBS 代码桶
#       -> FunctionGraph 函数（含 LTS 日志流）
#         -> GeminiDB Mongo 副本集 + 业务账号
#           -> APIG 专享实例 -> API 分组 -> 自定义认证器 -> API 定义 -> 发布
#
# 凭据：不落在本文件，由 provider 从环境变量读取
#   （见 versions.tf：HW_ACCESS_KEY / HW_SECRET_KEY / HW_SECURITY_TOKEN）
# ============================================================

locals {
  # ---------- 命名 ----------
  name = "${var.project_name}-${var.environment}"

  # ---------- 可用区 ----------
  # APIG 专享实例需要显式指定可用区列表；单可用区足以承载本示例
  az_names = slice(data.huaweicloud_availability_zones.azs.names, 0, 1)

  # ---------- OBS 代码桶 ----------
  # 桶名全局唯一，追加账户 ID 后缀避免冲突
  assets_bucket = "${var.obs_bucket_name}-${data.huaweicloud_account.current.id}"

  # ---------- 函数代码包 ----------
  # OBS 中的对象键名与本地构建产物一一对应
  function_packages = {
    tenant_management = "tenant-management.zip"
    product_service   = "product-service.zip"
    order_service     = "order-service.zip"
    tenant_authorizer = "tenant-authorizer.zip"
  }

  # ---------- APIG 认证方式 ----------
  # 管理端走 IAM（内网），租户端走自定义认证器（公网）
  api_type_public  = "Public"
  api_type_private = "Private"

  auth_mode_iam        = "IAM"
  auth_mode_authorizer = "AUTHORIZER"
  auth_mode_none       = "NONE"

  # ---------- 统一的环境变量 ----------
  # 注意：密码类变量以明文注入函数环境变量，这是 FunctionGraph 的既有模型；
  # 生产环境建议改用加密环境变量或凭据管理服务。
  fgs_common_env = {
    GEMINI_DB_HOST               = huaweicloud_geminidb_instance.main.port
    GEMINI_DB_SECRET             = var.geminidb_password
    GEMINI_DB_NAME               = var.geminidb_database
    GEMINI_DB_USER               = var.geminidb_account_name
    GEMINI_DB_REPLICA            = var.geminidb_replica_set
    JWT_SECRET_KEY               = var.jwt_secret
    LOG_LEVEL                    = var.log_level
    METRICS_NAMESPACE            = var.metrics_namespace
    POWERTOOLS_METRICS_NAMESPACE = var.metrics_namespace
  }
}

# ============================================================
# 数据源
# ============================================================
data "huaweicloud_availability_zones" "azs" {}

data "huaweicloud_account" "current" {}

data "huaweicloud_identity_projects" "project" {
  name = var.region
}

# ============================================================
# VPC 与子网
# ============================================================
resource "huaweicloud_vpc" "main" {
  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  tags = local.common_tags
}

resource "huaweicloud_vpc_subnet" "primary" {
  name       = "${local.name}-subnet"
  vpc_id     = huaweicloud_vpc.main.id
  cidr       = var.subnet_cidr
  gateway_ip = cidrhost(var.subnet_cidr, 1)

  tags = local.common_tags
}

# ============================================================
# 安全组：放通函数访问 GeminiDB 所需端口
# ============================================================
resource "huaweicloud_networking_secgroup" "saas" {
  name        = "${local.name}-sg"
  description = "安全组：FunctionGraph 到 GeminiDB Mongo 的访问控制"

  tags = local.common_tags
}

resource "huaweicloud_networking_secgroup_rule" "allow_mongo" {
  security_group_id = huaweicloud_networking_secgroup.saas.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8635
  port_range_max    = 8635
  remote_ip_prefix  = var.vpc_cidr
}

resource "huaweicloud_networking_secgroup_rule" "allow_https" {
  security_group_id = huaweicloud_networking_secgroup.saas.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
}

# ============================================================
# IAM：函数执行委托
# FGS 需要委托才能访问 OBS 与 VPC
# ============================================================
resource "huaweicloud_identity_role" "fgs_runner" {
  name        = "${local.name}-fgs-runner"
  description = "FunctionGraph 执行委托角色：访问 OBS 代码包与 VPC"
  type        = "AX"

  policy = jsonencode({
    Version = "1.1"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "obs:object:*",
          "vpc:*",
          "vpc:*:*",
          "vpc:*:get",
          "vpc:*:list",
          "vpc:*:create",
          "vpc:*:update",
          "vpc:*:delete",
          "vpc:*:ports:*",
          "vpc:*:routes:*",
          "vpc:*:subnets:*",
          "vpc:*:bandwidths:*",
          "elb:*",
          "dns:*"
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "huaweicloud_identity_agency" "fgs" {
  name                  = "${local.name}-fgs-agency"
  description           = "FunctionGraph 执行委托"
  delegated_domain_name = "op_svc_cff"
  domain_roles          = [huaweicloud_identity_role.fgs_runner.name]

  project_role {
    project = data.huaweicloud_identity_projects.project.projects[0].id
    roles   = [huaweicloud_identity_role.fgs_runner.name]
  }
}

# ============================================================
# OBS：函数代码桶（私有）
# ============================================================
resource "huaweicloud_obs_bucket" "assets" {
  bucket        = local.assets_bucket
  acl           = "private"
  storage_class = "STANDARD"
  force_destroy = true

  tags = local.common_tags
}

# 授权执行委托读取 code/ 目录下的代码包
resource "huaweicloud_obs_bucket_policy" "assets" {
  bucket = huaweicloud_obs_bucket.assets.bucket

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowFgsAgencyReadCode"
        Effect    = "Allow"
        Principal = "domain/${data.huaweicloud_account.current.id}:agency/${huaweicloud_identity_agency.fgs.name}"
        Action    = ["obs:object:getObject", "obs:object:listObjects"]
        Resource  = "${huaweicloud_obs_bucket.assets.bucket}/code/*"
      }
    ]
  })
}

# 上传函数代码包（由 scripts/build-packages.sh 生成到 build/ 目录）
resource "huaweicloud_obs_bucket_object" "code" {
  for_each = local.function_packages

  bucket = huaweicloud_obs_bucket.assets.bucket
  key    = "code/${each.value}"
  source = "${path.module}/../build/${each.value}"
}

# ============================================================
# LTS：日志组与日志流（替代 CloudWatch Logs）
# ============================================================
resource "huaweicloud_lts_group" "app" {
  group_name  = "${local.name}-app"
  ttl_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "huaweicloud_lts_stream" "app" {
  group_id    = huaweicloud_lts_group.app.id
  stream_name = "${local.name}-stream"
}

# ============================================================
# GeminiDB Mongo：副本集模式（Pooled 多租户共享实例，按租户分集合）
# ============================================================
resource "huaweicloud_geminidb_instance" "main" {
  name              = "${local.name}-geminidb"
  mode              = "ReplicaSet"
  availability_zone = local.az_names[0]
  vpc_id            = huaweicloud_vpc.main.id
  subnet_id         = huaweicloud_vpc_subnet.primary.id
  security_group_id = huaweicloud_networking_secgroup.saas.id
  password          = var.geminidb_password

  datastore {
    type           = "mongodb"
    version        = "4.0"
    storage_engine = "rocksDB"
  }

  flavor {
    spec_code = var.geminidb_spec_code
    num       = var.geminidb_node_num
    storage   = var.geminidb_storage_type
    size      = var.geminidb_storage_size
  }

  tags = local.common_tags
}

# 业务账号：授权固定数据库，供函数连接
resource "huaweicloud_geminidb_account" "app" {
  instance_id = huaweicloud_geminidb_instance.main.id
  name        = var.geminidb_account_name
  password    = var.geminidb_password
  privilege   = "readWrite"
  databases   = [var.geminidb_database]
}

# ============================================================
# FunctionGraph：四个函数
# 说明：
#   - code_type = "obs"，代码包由 OBS 提供
#   - app 名只允许小写字母/数字/下划线，故用 serverless_saas
#   - 挂 VPC 需要委托，且冷启动较慢
#   - 开启 LTS 日志上报
# ============================================================
resource "huaweicloud_fgs_function" "tenant_management" {
  name        = "${local.name}-tenant-management"
  app         = var.fgs_app_name
  description = "租户管理服务：注册、套餐与配置"
  handler     = "tenant_management.handler"
  runtime     = var.fgs_runtime
  memory_size = 256
  timeout     = 30

  code_type             = "obs"
  code_url              = "https://${huaweicloud_obs_bucket.assets.bucket}.obs.${var.region}.myhuaweicloud.com/code/${local.function_packages.tenant_management}"
  functiongraph_version = "v2"

  agency    = huaweicloud_identity_agency.fgs.name
  user_data = jsonencode(local.fgs_common_env)

  vpc_id     = huaweicloud_vpc.main.id
  network_id = huaweicloud_vpc_subnet.primary.id

  enable_lts_log = true
  log_group_id   = huaweicloud_lts_group.app.id
  log_stream_id  = huaweicloud_lts_stream.app.id

  tags = local.common_tags
}

resource "huaweicloud_fgs_function" "product_service" {
  name        = "${local.name}-product-service"
  app         = var.fgs_app_name
  description = "产品服务：租户产品 CRUD"
  handler     = "product_service.handler"
  runtime     = var.fgs_runtime
  memory_size = 256
  timeout     = 30

  code_type             = "obs"
  code_url              = "https://${huaweicloud_obs_bucket.assets.bucket}.obs.${var.region}.myhuaweicloud.com/code/${local.function_packages.product_service}"
  functiongraph_version = "v2"

  agency    = huaweicloud_identity_agency.fgs.name
  user_data = jsonencode(local.fgs_common_env)

  vpc_id     = huaweicloud_vpc.main.id
  network_id = huaweicloud_vpc_subnet.primary.id

  enable_lts_log = true
  log_group_id   = huaweicloud_lts_group.app.id
  log_stream_id  = huaweicloud_lts_stream.app.id

  tags = local.common_tags
}

resource "huaweicloud_fgs_function" "order_service" {
  name        = "${local.name}-order-service"
  app         = var.fgs_app_name
  description = "订单服务：租户订单 CRUD"
  handler     = "order_service.handler"
  runtime     = var.fgs_runtime
  memory_size = 256
  timeout     = 30

  code_type             = "obs"
  code_url              = "https://${huaweicloud_obs_bucket.assets.bucket}.obs.${var.region}.myhuaweicloud.com/code/${local.function_packages.order_service}"
  functiongraph_version = "v2"

  agency    = huaweicloud_identity_agency.fgs.name
  user_data = jsonencode(local.fgs_common_env)

  vpc_id     = huaweicloud_vpc.main.id
  network_id = huaweicloud_vpc_subnet.primary.id

  enable_lts_log = true
  log_group_id   = huaweicloud_lts_group.app.id
  log_stream_id  = huaweicloud_lts_stream.app.id

  tags = local.common_tags
}

resource "huaweicloud_fgs_function" "tenant_authorizer" {
  name        = "${local.name}-tenant-authorizer"
  app         = var.fgs_app_name
  description = "租户授权器：APIG 自定义认证函数"
  handler     = "authorizer.handler"
  runtime     = var.fgs_runtime
  memory_size = 256
  timeout     = 10

  code_type             = "obs"
  code_url              = "https://${huaweicloud_obs_bucket.assets.bucket}.obs.${var.region}.myhuaweicloud.com/code/${local.function_packages.tenant_authorizer}"
  functiongraph_version = "v2"

  agency    = huaweicloud_identity_agency.fgs.name
  user_data = jsonencode(local.fgs_common_env)

  vpc_id     = huaweicloud_vpc.main.id
  network_id = huaweicloud_vpc_subnet.primary.id

  enable_lts_log = true
  log_group_id   = huaweicloud_lts_group.app.id
  log_stream_id  = huaweicloud_lts_stream.app.id

  tags = local.common_tags
}

# ============================================================
# APIG 专享实例
#   - admin：内网管理入口，type = Private
#   - tenant：租户业务入口，type = Public
# 公网实例通过 ingress_bandwidth_* 开通带宽入口；
# 若改为绑定自有 EIP，请使用 eip_id（与带宽字段互斥）。
# ============================================================
resource "huaweicloud_apig_instance" "admin" {
  name               = "${local.name}-admin-api"
  edition            = var.apig_instance_edition
  vpc_id             = huaweicloud_vpc.main.id
  subnet_id          = huaweicloud_vpc_subnet.primary.id
  security_group_id  = huaweicloud_networking_secgroup.saas.id
  availability_zones = local.az_names

  tags = local.common_tags
}

resource "huaweicloud_apig_instance" "tenant" {
  name               = "${local.name}-tenant-api"
  edition            = var.apig_instance_edition
  vpc_id             = huaweicloud_vpc.main.id
  subnet_id          = huaweicloud_vpc_subnet.primary.id
  security_group_id  = huaweicloud_networking_secgroup.saas.id
  availability_zones = local.az_names

  # 公网入口带宽：与 eip_id 互斥，二选一
  ingress_bandwidth_size          = var.public_ingress_enabled ? var.ingress_bandwidth_size : null
  ingress_bandwidth_charging_mode = var.public_ingress_enabled ? var.ingress_bandwidth_charging_mode : null

  tags = local.common_tags
}

# ============================================================
# APIG API 分组
# ============================================================
resource "huaweicloud_apig_group" "admin" {
  instance_id = huaweicloud_apig_instance.admin.id
  name        = "${local.name}-admin-group"
  description = "管理端 API 分组"
}

resource "huaweicloud_apig_group" "tenant" {
  instance_id = huaweicloud_apig_instance.tenant.id
  name        = "${local.name}-tenant-group"
  description = "租户端 API 分组"
}

# ============================================================
# APIG 自定义认证器（JWT 校验 + 租户上下文注入）
# network_type = V2 对应 FunctionGraph v2
# function_version 使用 latest，URN 不带 :latest
# ============================================================
resource "huaweicloud_apig_custom_authorizer" "tenant" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  name             = "${local.name}-jwt-authorizer"
  type             = "FRONTEND"
  network_type     = "V2"
  function_urn     = trimsuffix(huaweicloud_fgs_function.tenant_authorizer.urn, ":latest")
  function_version = "latest"
  cache_age        = 300
  is_body_send     = false

  user_data = jsonencode({
    GEMINI_DB_HOST    = huaweicloud_geminidb_instance.main.port
    GEMINI_DB_SECRET  = var.geminidb_password
    GEMINI_DB_NAME    = var.geminidb_database
    GEMINI_DB_USER    = var.geminidb_account_name
    GEMINI_DB_REPLICA = var.geminidb_replica_set
    JWT_SECRET_KEY    = var.jwt_secret
  })

  identity {
    name     = "Authorization"
    location = "HEADER"
  }
}

# ============================================================
# APIG API 定义
# type：Public（公网）/ Private（内网）
# security_authentication：IAM / AUTHORIZER / NONE
# ============================================================

# ---- 管理端：创建租户（内网 + IAM 认证）----
resource "huaweicloud_apig_api" "admin_create_tenant" {
  instance_id      = huaweicloud_apig_instance.admin.id
  group_id         = huaweicloud_apig_group.admin.id
  name             = "admin-create-tenant"
  description      = "创建租户"
  request_protocol = "HTTPS"
  request_method   = "POST"
  request_path     = "/tenant"
  type             = local.api_type_private

  security_authentication = local.auth_mode_iam

  func_graph {
    function_urn    = huaweicloud_fgs_function.tenant_management.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }
}

# ---- 管理端：查询租户列表（内网 + IAM 认证）----
resource "huaweicloud_apig_api" "admin_list_tenants" {
  instance_id      = huaweicloud_apig_instance.admin.id
  group_id         = huaweicloud_apig_group.admin.id
  name             = "admin-list-tenants"
  description      = "查询租户列表"
  request_protocol = "HTTPS"
  request_method   = "GET"
  request_path     = "/tenants"
  type             = local.api_type_private

  security_authentication = local.auth_mode_iam

  func_graph {
    function_urn    = huaweicloud_fgs_function.tenant_management.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }
}

# ---- 租户端：产品查询（公网 + 自定义认证器）----
resource "huaweicloud_apig_api" "tenant_get_product" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  group_id         = huaweicloud_apig_group.tenant.id
  name             = "tenant-get-product"
  description      = "查询单个产品"
  request_protocol = "HTTPS"
  request_method   = "GET"
  request_path     = "/products/{id}"
  type             = local.api_type_public

  security_authentication = local.auth_mode_authorizer
  authorizer_id           = huaweicloud_apig_custom_authorizer.tenant.id

  request_params {
    name     = "id"
    type     = "REQUEST"
    location = "PATH"
    required = true
  }

  backend_params {
    name     = "id"
    type     = "REQUEST"
    location = "PATH"
    value    = "id"
  }

  func_graph {
    function_urn    = huaweicloud_fgs_function.product_service.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }

  # func_graph 无法原地更新，变更时忽略以避免强制重建
  lifecycle {
    ignore_changes = [func_graph]
  }
}

# ---- 租户端：产品列表（公网 + 自定义认证器）----
resource "huaweicloud_apig_api" "tenant_list_products" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  group_id         = huaweicloud_apig_group.tenant.id
  name             = "tenant-list-products"
  description      = "查询产品列表"
  request_protocol = "HTTPS"
  request_method   = "GET"
  request_path     = "/products"
  type             = local.api_type_public

  security_authentication = local.auth_mode_authorizer
  authorizer_id           = huaweicloud_apig_custom_authorizer.tenant.id

  func_graph {
    function_urn    = huaweicloud_fgs_function.product_service.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }

  lifecycle {
    ignore_changes = [func_graph]
  }
}

# ---- 租户端：创建产品（公网 + 自定义认证器）----
resource "huaweicloud_apig_api" "tenant_create_product" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  group_id         = huaweicloud_apig_group.tenant.id
  name             = "tenant-create-product"
  description      = "创建产品"
  request_protocol = "HTTPS"
  request_method   = "POST"
  request_path     = "/products"
  type             = local.api_type_public

  security_authentication = local.auth_mode_authorizer
  authorizer_id           = huaweicloud_apig_custom_authorizer.tenant.id

  func_graph {
    function_urn    = huaweicloud_fgs_function.product_service.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }

  lifecycle {
    ignore_changes = [func_graph]
  }
}

# ---- 租户端：订单查询（公网 + 自定义认证器）----
resource "huaweicloud_apig_api" "tenant_get_order" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  group_id         = huaweicloud_apig_group.tenant.id
  name             = "tenant-get-order"
  description      = "查询单个订单"
  request_protocol = "HTTPS"
  request_method   = "GET"
  request_path     = "/orders/{id}"
  type             = local.api_type_public

  security_authentication = local.auth_mode_authorizer
  authorizer_id           = huaweicloud_apig_custom_authorizer.tenant.id

  request_params {
    name     = "id"
    type     = "REQUEST"
    location = "PATH"
    required = true
  }

  backend_params {
    name     = "id"
    type     = "REQUEST"
    location = "PATH"
    value    = "id"
  }

  func_graph {
    function_urn    = huaweicloud_fgs_function.order_service.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }

  lifecycle {
    ignore_changes = [func_graph]
  }
}

# ---- 租户端：创建订单（公网 + 自定义认证器）----
resource "huaweicloud_apig_api" "tenant_create_order" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  group_id         = huaweicloud_apig_group.tenant.id
  name             = "tenant-create-order"
  description      = "创建订单"
  request_protocol = "HTTPS"
  request_method   = "POST"
  request_path     = "/orders"
  type             = local.api_type_public

  security_authentication = local.auth_mode_authorizer
  authorizer_id           = huaweicloud_apig_custom_authorizer.tenant.id

  func_graph {
    function_urn    = huaweicloud_fgs_function.order_service.urn
    invocation_type = "sync"
    timeout         = 30000
    network_type    = "V2"
    version         = "latest"
  }

  lifecycle {
    ignore_changes = [func_graph]
  }
}

# ============================================================
# APIG 环境与发布
# ============================================================
resource "huaweicloud_apig_environment" "release" {
  instance_id = huaweicloud_apig_instance.tenant.id
  name        = "RELEASE"
  description = "正式环境"
}

resource "huaweicloud_apig_api_publishment" "tenant" {
  for_each = {
    get_product    = huaweicloud_apig_api.tenant_get_product.id
    list_products  = huaweicloud_apig_api.tenant_list_products.id
    create_product = huaweicloud_apig_api.tenant_create_product.id
    get_order      = huaweicloud_apig_api.tenant_get_order.id
    create_order   = huaweicloud_apig_api.tenant_create_order.id
  }

  instance_id = huaweicloud_apig_instance.tenant.id
  api_id      = each.value
  env_id      = huaweicloud_apig_environment.release.id
}

# ============================================================
# APIG APP（替代 API Keys）与限流策略
# 四个套餐对应四个 APP，各自在同一限流策略下按 APP 维度限流
# ============================================================
resource "huaweicloud_apig_application" "basic" {
  instance_id = huaweicloud_apig_instance.tenant.id
  name        = "${local.name}-app-basic"
  description = "Basic 套餐凭据"
}

resource "huaweicloud_apig_application" "standard" {
  instance_id = huaweicloud_apig_instance.tenant.id
  name        = "${local.name}-app-standard"
  description = "Standard 套餐凭据"
}

resource "huaweicloud_apig_application" "premium" {
  instance_id = huaweicloud_apig_instance.tenant.id
  name        = "${local.name}-app-premium"
  description = "Premium 套餐凭据"
}

resource "huaweicloud_apig_application" "platinum" {
  instance_id = huaweicloud_apig_instance.tenant.id
  name        = "${local.name}-app-platinum"
  description = "Platinum 套餐凭据"
}

resource "huaweicloud_apig_throttling_policy" "tiers" {
  instance_id      = huaweicloud_apig_instance.tenant.id
  name             = "${local.name}-tier-throttling"
  description      = "按套餐分级的请求限流策略"
  type             = "API-based"
  period           = 1
  period_unit      = "MINUTE"
  max_api_requests = 200

  app_throttles {
    max_api_requests     = 50
    throttling_object_id = huaweicloud_apig_application.basic.id
  }

  app_throttles {
    max_api_requests     = 100
    throttling_object_id = huaweicloud_apig_application.standard.id
  }

  app_throttles {
    max_api_requests     = 150
    throttling_object_id = huaweicloud_apig_application.premium.id
  }

  app_throttles {
    max_api_requests     = 200
    throttling_object_id = huaweicloud_apig_application.platinum.id
  }
}

resource "huaweicloud_apig_throttling_policy_associate" "tiers" {
  instance_id = huaweicloud_apig_instance.tenant.id
  policy_id   = huaweicloud_apig_throttling_policy.tiers.id
  publish_ids = [for p in huaweicloud_apig_api_publishment.tenant : p.publish_id]
}
