# -*- coding: utf-8 -*-
"""
工具函数库 - 华为云 FunctionGraph 版本
公共工具：响应封装、租户上下文日志、指标记录
"""

import json
from datetime import datetime, timezone


def generate_response(body, status_code=200):
    """
    生成 APIG 格式的响应

    返回格式：statusCode + headers + body
    """
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-Tenant-Id,X-Api-Key',
            'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS'
        },
        'body': json.dumps(body, default=_json_serial)
    }


def _json_serial(obj):
    """处理 datetime 等非常规 JSON 类型"""
    if isinstance(obj, datetime):
        return obj.isoformat()
    raise TypeError(f"Type {type(obj)} not serializable")


def log_with_tenant_context(event, message):
    """
    记录带租户上下文的日志

    从 APIG 自定义认证器返回的上下文中提取 tenantId
    """
    tenant_id = 'unknown'
    try:
        tenant_id = (
            event.get('requestContext', {})
            .get('authorizer', {})
            .get('tenantId', 'unknown')
        )
    except Exception:
        pass
    print(f"[Tenant:{tenant_id}] {message}")


def record_metric(event, metric_name, unit, value):
    """
    记录自定义指标

    以结构化行写入 LTS 日志流，由 LTS 侧做检索与告警
    """
    tenant_id = 'pooled'
    try:
        tenant_id = (
            event.get('requestContext', {})
            .get('authorizer', {})
            .get('tenantId', 'pooled')
        )
    except Exception:
        pass
    metric_data = {
        'metric_name': metric_name,
        'unit': unit,
        'value': value,
        'tenant_id': tenant_id,
        'timestamp': datetime.now(timezone.utc).isoformat()
    }
    print(f"[METRIC] {json.dumps(metric_data, ensure_ascii=False)}")


def utc_now_iso():
    """当前 UTC 时间（ISO 8601）"""
    return datetime.now(timezone.utc).isoformat()
