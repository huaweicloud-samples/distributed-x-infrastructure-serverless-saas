# -*- coding: utf-8 -*-
"""
租户管理服务 - 华为云 FunctionGraph 版本
租户管理服务：注册、套餐与配置

数据隔离：Pooled 模式共用一个 GeminiDB 数据库，租户详情写入全局 tenants 集合，
按 tenantId 字段区分；产品与订单集合按租户拆分（见 common.tenant_collection）。
"""

import os
import re
import json
from datetime import datetime, timezone

from logger import logger
from utils import generate_response, record_metric
from common import (
    get_tenant_collection,
    get_settings_collection,
    GEMINI_DB_NAME,
)

LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')

# 租户 ID 允许字符集
TENANT_ID_PATTERN = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')

# 允许的套餐
VALID_TIERS = ('BASIC', 'STANDARD', 'PREMIUM', 'PLATINUM')


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def create_tenant(event, context):
    """
    创建租户
    POST /tenant
    Body: { tenantId, tenantName, tenantAddress, tenantEmail, tenantPhone, tenantTier, dedicatedTenancy }
    """
    logger.info("Request received to create a tenant")

    try:
        body = json.loads(event.get('body') or '{}')

        tenant_id = body.get('tenantId')
        tenant_name = body.get('tenantName')
        tenant_address = body.get('tenantAddress')
        tenant_email = body.get('tenantEmail')
        tenant_phone = body.get('tenantPhone')
        tenant_tier = (body.get('tenantTier') or 'BASIC').upper()
        dedicated_tenancy = str(body.get('dedicatedTenancy', 'false')).lower() == 'true'

        # 租户 ID 格式校验
        if not tenant_id or not TENANT_ID_PATTERN.match(str(tenant_id)):
            return generate_response({'error': 'Invalid tenantId format'}, status_code=400)

        if tenant_tier not in VALID_TIERS:
            return generate_response(
                {'error': f"Invalid tenantTier, expected one of {list(VALID_TIERS)}"},
                status_code=400
            )

        # 租户 ID 唯一性校验
        if get_tenant_collection().find_one({'tenantId': tenant_id}):
            return generate_response({'error': 'Tenant already exists'}, status_code=409)

        # Pooled 租户从设置表取共享 API 网关地址
        api_gateway_url = ''
        if not dedicated_tenancy:
            setting = get_settings_collection().find_one(
                {'settingName': 'apiGatewayUrl-Pooled'}
            )
            if setting:
                api_gateway_url = setting.get('settingValue', '')

        tenant_record = {
            'tenantId': tenant_id,
            'tenantName': tenant_name,
            'tenantAddress': tenant_address,
            'tenantEmail': tenant_email,
            'tenantPhone': tenant_phone,
            'tenantTier': tenant_tier,
            'dedicatedTenancy': dedicated_tenancy,
            'isActive': True,
            'apiGatewayUrl': api_gateway_url,
            'createdAt': _now_iso(),
        }

        get_tenant_collection().insert_one(tenant_record)

        logger.info(f"Tenant created successfully: {tenant_id}")
        record_metric(event, "TenantCreated", "Count", 1)

        return generate_response({
            'message': 'Tenant created successfully',
            'tenantId': tenant_id,
            'apiGatewayUrl': api_gateway_url
        })

    except Exception as e:
        logger.error(f"Error creating tenant: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def get_tenant(event, context):
    """获取租户详情 GET /tenant/{tenantId}"""
    tenant_id = _tenant_id_from_event(event)

    if not tenant_id:
        return generate_response({'error': 'Tenant ID required'}, status_code=400)

    logger.info(f"Request received to get tenant: {tenant_id}")

    try:
        tenant = get_tenant_collection().find_one({'tenantId': tenant_id})
        if not tenant:
            return generate_response({'error': 'Tenant not found'}, status_code=404)

        tenant.pop('_id', None)
        return generate_response(tenant)

    except Exception as e:
        logger.error(f"Error getting tenant: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def update_tenant(event, context):
    """更新租户信息 PUT /tenant/{tenantId}"""
    tenant_id = _tenant_id_from_event(event)

    if not tenant_id:
        return generate_response({'error': 'Tenant ID required'}, status_code=400)

    logger.info(f"Request received to update tenant: {tenant_id}")

    try:
        body = json.loads(event.get('body') or '{}')

        update_fields = {k: v for k, v in body.items() if k not in ('tenantId', '_id')}
        if not update_fields:
            return generate_response({'error': 'No fields to update'}, status_code=400)
        update_fields['updatedAt'] = _now_iso()

        result = get_tenant_collection().update_one(
            {'tenantId': tenant_id},
            {'$set': update_fields}
        )

        if result.matched_count == 0:
            return generate_response({'error': 'Tenant not found'}, status_code=404)

        return generate_response({'message': 'Tenant updated successfully'})

    except Exception as e:
        logger.error(f"Error updating tenant: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def delete_tenant(event, context):
    """删除租户 DELETE /tenant/{tenantId}"""
    tenant_id = _tenant_id_from_event(event)

    if not tenant_id:
        return generate_response({'error': 'Tenant ID required'}, status_code=400)

    logger.info(f"Request received to delete tenant: {tenant_id}")

    try:
        result = get_tenant_collection().delete_one({'tenantId': tenant_id})

        if result.deleted_count == 0:
            return generate_response({'error': 'Tenant not found'}, status_code=404)

        return generate_response({'message': 'Tenant deleted successfully'})

    except Exception as e:
        logger.error(f"Error deleting tenant: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def list_tenants(event, context):
    """获取租户列表 GET /tenants"""
    logger.info("Request received to list tenants")

    try:
        tenants = list(get_tenant_collection().find({}, {'_id': 0}))

        return generate_response({
            'tenants': tenants,
            'count': len(tenants)
        })

    except Exception as e:
        logger.error(f"Error listing tenants: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def activate_tenant(event, context):
    """激活租户 POST /tenant/{tenantId}/activate"""
    tenant_id = _tenant_id_from_event(event)

    if not tenant_id:
        return generate_response({'error': 'Tenant ID required'}, status_code=400)

    logger.info(f"Request received to activate tenant: {tenant_id}")

    try:
        result = get_tenant_collection().update_one(
            {'tenantId': tenant_id},
            {'$set': {'isActive': True, 'activatedAt': _now_iso()}}
        )

        if result.matched_count == 0:
            return generate_response({'error': 'Tenant not found'}, status_code=404)

        return generate_response({'message': 'Tenant activated successfully'})

    except Exception as e:
        logger.error(f"Error activating tenant: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def deactivate_tenant(event, context):
    """停用租户 POST /tenant/{tenantId}/deactivate"""
    tenant_id = _tenant_id_from_event(event)

    if not tenant_id:
        return generate_response({'error': 'Tenant ID required'}, status_code=400)

    logger.info(f"Request received to deactivate tenant: {tenant_id}")

    try:
        result = get_tenant_collection().update_one(
            {'tenantId': tenant_id},
            {'$set': {'isActive': False, 'deactivatedAt': _now_iso()}}
        )

        if result.matched_count == 0:
            return generate_response({'error': 'Tenant not found'}, status_code=404)

        return generate_response({'message': 'Tenant deactivated successfully'})

    except Exception as e:
        logger.error(f"Error deactivating tenant: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


def _tenant_id_from_event(event):
    """从路径参数或认证上下文中取租户 ID"""
    tenant_id = event.get('pathParameters', {}).get('tenantId')
    if tenant_id:
        return tenant_id
    return event.get('requestContext', {}).get('authorizer', {}).get('tenantId')


# ---------------- FunctionGraph 入口 ----------------
def handler(event, context):
    """按 HTTP 方法与路径路由到对应处理函数"""
    logger.info(f"Tenant handler invoked with event: {event}")

    http_method = (event.get('httpMethod') or 'GET').upper()
    path = event.get('path') or '/'

    # 去掉 APIG 分组前缀与查询串，只保留资源路径
    path = path.split('?')[0].rstrip('/') or '/'

    # 路径参数提取：/tenant/{tenantId}[/activate|/deactivate]
    match = re.match(r'^/tenant/([a-zA-Z0-9_-]+)(?:/(activate|deactivate))?$', path)
    if match:
        event['pathParameters'] = {'tenantId': match.group(1)}
        action = match.group(2)

        if action == 'activate' and http_method == 'POST':
            return activate_tenant(event, context)
        if action == 'deactivate' and http_method == 'POST':
            return deactivate_tenant(event, context)

        if http_method == 'GET':
            return get_tenant(event, context)
        if http_method == 'PUT':
            return update_tenant(event, context)
        if http_method == 'DELETE':
            return delete_tenant(event, context)

        return generate_response({'error': 'Method not allowed'}, status_code=405)

    # 集合级路由
    if path == '/tenant':
        if http_method == 'POST':
            return create_tenant(event, context)
        if http_method == 'GET':
            return get_tenant(event, context)
        if http_method == 'PUT':
            return update_tenant(event, context)
        if http_method == 'DELETE':
            return delete_tenant(event, context)

    if path == '/tenants' and http_method == 'GET':
        return list_tenants(event, context)

    return generate_response({'error': 'Not Found'}, status_code=404)
