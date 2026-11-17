# -*- coding: utf-8 -*-
"""
公共数据访问层 - 华为云 FunctionGraph 版本

多租户隔离模型（Pooled 模式）：
  - 单一数据库（GEMINI_DB_NAME）
  - 集合按租户维度拆分：<base>_<tenantId>
  - 所有集合读写统一走本模块，避免各函数自行拼接数据库名导致越权

环境变量：
  GEMINI_DB_HOST      GeminiDB 连接地址（host 或 host:port）
  GEMINI_DB_SECRET  业务账号密码
  GEMINI_DB_NAME      业务数据库名
  GEMINI_DB_USER      业务账号名
  GEMINI_DB_REPLICA   副本集名称
"""

import os
import re

from pymongo import MongoClient

# ---------- 环境变量 ----------
GEMINI_DB_HOST = os.environ.get('GEMINI_DB_HOST', '')
DB_SECRET = os.environ.get('GEMINI_DB_SECRET', '')
GEMINI_DB_NAME = os.environ.get('GEMINI_DB_NAME', 'serverless_saas')
GEMINI_DB_USER = os.environ.get('GEMINI_DB_USER', 'saas_app')
GEMINI_DB_REPLICA = os.environ.get('GEMINI_DB_REPLICA', 'replica')

# ---------- 固定集合名（与租户无关的全局集合）----------
COLLECTION_TENANTS = 'tenants'
COLLECTION_SETTINGS = 'settings'

# ---------- 租户集合前缀 ----------
COLLECTION_PRODUCT = 'products'
COLLECTION_ORDER = 'orders'

_mongo_client = None

# 允许作为集合名的租户 ID 字符集
_TENANT_ID_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')


def _parse_host():
    """把 GEMINI_DB_HOST 拆成 (host, port)，默认端口 8635"""
    if not GEMINI_DB_HOST:
        return '127.0.0.1', 8635
    if ':' in GEMINI_DB_HOST:
        host, _, port = GEMINI_DB_HOST.rpartition(':')
        try:
            return host, int(port)
        except ValueError:
            return host, 8635
    return GEMINI_DB_HOST, 8635


def get_db_client():
    """获取 GeminiDB 连接（进程内单例）"""
    global _mongo_client
    if _mongo_client is None:
        host, port = _parse_host()
        kwargs = {
            'host': host,
            'port': port,
            'username': GEMINI_DB_USER,
            'password': DB_SECRET,
            'authSource': 'admin',
            'serverSelectionTimeoutMS': 10000,
        }
        if GEMINI_DB_REPLICA:
            kwargs['replicaSet'] = GEMINI_DB_REPLICA
        _mongo_client = MongoClient(**kwargs)
    return _mongo_client


def get_database():
    """获取业务数据库"""
    return get_db_client()[GEMINI_DB_NAME]


def tenant_collection(base, tenant_id):
    """
    获取租户私有集合
    base：集合前缀，如 products / orders
    tenant_id：租户 ID
    非法租户 ID 直接拒绝，避免集合名注入
    """
    if not tenant_id or not _TENANT_ID_RE.match(str(tenant_id)):
        raise ValueError(f"Invalid tenantId: {tenant_id!r}")
    return get_database()[f"{base}_{tenant_id}"]


def get_tenant_collection():
    """租户详情集合（全局集合，按 tenantId 字段过滤）"""
    return get_database()[COLLECTION_TENANTS]


def get_settings_collection():
    """全局设置集合"""
    return get_database()[COLLECTION_SETTINGS]


def get_tenant_id(event):
    """从 APIG 请求上下文中提取租户 ID"""
    try:
        return (
            event.get('requestContext', {})
            .get('authorizer', {})
            .get('tenantId', 'pooled')
        )
    except Exception:
        return 'pooled'
