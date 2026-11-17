# -*- coding: utf-8 -*-
"""
租户授权器 - 华为云 FunctionGraph 版本
APIG 自定义认证函数

职责：
  1. 从 Authorization 头取出 JWT
  2. 用共享密钥（HS256）校验签名与有效期
  3. 从载荷取租户 ID 与用户角色，必要时回查数据库确认租户处于启用状态
  4. 返回 APIG 自定义认证器的允许/拒绝响应
"""

import os
import json
import jwt

from logger import logger
from common import (
    get_tenant_collection,
    GEMINI_DB_USER,
)

# 环境变量
JWT_SECRET_KEY = os.environ.get('JWT_SECRET_KEY', '')
GEMINI_DB_USER_NAME = GEMINI_DB_USER


def verify_token(token):
    """
    验证 JWT 令牌（HS256）

    返回解码后的载荷；失败返回 None
    """
    if not JWT_SECRET_KEY:
        logger.error("JWT_SECRET_KEY is not configured")
        return None

    try:
        payload = jwt.decode(
            token,
            JWT_SECRET_KEY,
            algorithms=['HS256'],
            options={'verify_signature': True, 'verify_exp': True}
        )
        return payload
    except jwt.ExpiredSignatureError:
        logger.error("Token expired")
        return None
    except jwt.InvalidTokenError as e:
        logger.error(f"Invalid token: {str(e)}")
        return None
    except Exception as e:
        logger.error(f"Token verification error: {str(e)}")
        return None


def get_tenant_from_db(tenant_id):
    """从数据库获取租户信息"""
    try:
        tenant = get_tenant_collection().find_one({'tenantId': tenant_id})
        if tenant:
            tenant.pop('_id', None)
        return tenant
    except Exception as e:
        logger.error(f"Error getting tenant from DB: {str(e)}")
        return None


def handler(event, context):
    """
    APIG 自定义认证函数入口

    返回格式：
      允许：{"isAuthorized": true,  "context": {...}}
      拒绝：{"isAuthorized": false, "message": "..."}
    """
    logger.info(f"Authorizer invoked with event: {json.dumps(event, default=str)}")

    try:
        headers = event.get('headers', {}) or {}
        auth_header = headers.get('Authorization') or headers.get('authorization', '')

        if not auth_header:
            logger.warning("No Authorization header found")
            return _deny_response("Missing authentication")

        bearer = auth_header
        if auth_header.lower().startswith('bearer '):
            bearer = auth_header[7:]

        payload = verify_token(bearer)
        if not payload:
            logger.warning("Token verification failed")
            return _deny_response("Invalid token")

        tenant_id = payload.get('tenant_id') or payload.get('tenantId', 'pooled')
        user_role = payload.get('user_role') or payload.get('userRole', 'user')

        # 非管理员需回查数据库确认租户状态
        if user_role != 'SystemAdmin':
            tenant = get_tenant_from_db(tenant_id)
            if not tenant:
                return _deny_response("Tenant not found")
            if not tenant.get('isActive', False):
                return _deny_response("Tenant is inactive")

        logger.info(f"Authorization successful for tenant: {tenant_id}")

        return _allow_response({
            'tenantId': tenant_id,
            'userRole': user_role,
            'userId': payload.get('sub') or payload.get('user_id', ''),
            'email': payload.get('email', '')
        })

    except Exception as e:
        logger.error(f"Authorizer error: {str(e)}")
        return _deny_response("Authorization error")


def _allow_response(context):
    """返回 APIG 自定义认证器的允许响应"""
    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json'
        },
        'body': json.dumps({
            'isAuthorized': True,
            'context': context
        })
    }


def _deny_response(message):
    """返回拒绝访问的响应"""
    return {
        'statusCode': 401,
        'headers': {
            'Content-Type': 'application/json'
        },
        'body': json.dumps({
            'isAuthorized': False,
            'message': message
        })
    }
