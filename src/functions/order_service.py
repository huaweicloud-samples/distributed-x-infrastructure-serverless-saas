# -*- coding: utf-8 -*-
"""
订单服务 - 华为云 FunctionGraph 版本
订单服务：租户订单 CRUD

多租户隔离：单库 + 按租户拆集合（orders_<tenantId>），
下单时校验产品同属当前租户的 products 集合，避免跨租户下单。
"""

import os
import re
import json
from datetime import datetime, timezone
from decimal import Decimal

from logger import logger
from utils import generate_response, record_metric
from common import (
    tenant_collection,
    get_tenant_id,
    COLLECTION_PRODUCT,
    COLLECTION_ORDER,
)


class Tracer:
    """轻量追踪器：记录调用信息与租户标注"""

    @staticmethod
    def capture_lambda_handler(func):
        def wrapper(*args, **kwargs):
            logger.info(f"Function invoked: {func.__name__}")
            return func(*args, **kwargs)
        return wrapper

    def put_annotation(self, key, value):
        """写入一条追踪标注"""
        logger.info(f"Annotation {key}={value}")


# 模块级追踪器实例
tracer = Tracer()

# 环境变量
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


class DecimalEncoder(json.JSONEncoder):
    """处理 Decimal 类型"""
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def parse_body(body_str):
    """解析请求体，保留 Decimal 精度"""
    if not body_str:
        return {}
    try:
        return json.loads(body_str, parse_float=Decimal)
    except (ValueError, TypeError):
        return {}


@Tracer.capture_lambda_handler
def get_order(event, context):
    """获取订单 GET /orders/{id}"""
    tenant_id = get_tenant_id(event)
    tracer.put_annotation(key="TenantId", value=tenant_id)

    order_id = event.get('pathParameters', {}).get('id')
    if not order_id:
        return generate_response({'error': 'Order ID required'}, status_code=400)

    try:
        order = tenant_collection(COLLECTION_ORDER, tenant_id).find_one(
            {'orderId': order_id}
        )
        if not order:
            return generate_response({'error': 'Order not found'}, status_code=404)

        order.pop('_id', None)
        record_metric(event, "SingleOrderRequested", "Count", 1)

        return generate_response(order)

    except Exception as e:
        logger.error(f"Error getting order: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def create_order(event, context):
    """创建订单 POST /orders"""
    tenant_id = get_tenant_id(event)
    tracer.put_annotation(key="TenantId", value=tenant_id)

    try:
        payload = parse_body(event.get('body'))

        order_id = payload.get('orderId') or f"ORD-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"
        product_id = payload.get('productId')

        if not product_id:
            return generate_response({'error': 'productId required'}, status_code=400)

        # 校验产品属于当前租户
        product = tenant_collection(COLLECTION_PRODUCT, tenant_id).find_one(
            {'productId': product_id}
        )
        if not product:
            return generate_response({'error': 'Product not found'}, status_code=404)

        quantity = int(payload.get('quantity', 1))
        if quantity <= 0:
            return generate_response({'error': 'quantity must be positive'}, status_code=400)

        unit_price = float(product.get('price', 0))
        total_amount = round(quantity * unit_price, 2)

        order = {
            'tenantId': tenant_id,
            'orderId': order_id,
            'productId': product_id,
            'quantity': quantity,
            'unitPrice': unit_price,
            'totalAmount': total_amount,
            'status': 'PENDING',
            'createdAt': _now_iso(),
            'updatedAt': _now_iso()
        }

        tenant_collection(COLLECTION_ORDER, tenant_id).insert_one(order)
        order.pop('_id', None)

        record_metric(event, "OrderCreated", "Count", 1)

        return generate_response(order, status_code=201)

    except ValueError as e:
        logger.error(f"Invalid request: {str(e)}")
        return generate_response({'error': str(e)}, status_code=400)
    except Exception as e:
        logger.error(f"Error creating order: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def update_order(event, context):
    """更新订单状态 PUT /orders/{id}"""
    tenant_id = get_tenant_id(event)

    order_id = event.get('pathParameters', {}).get('id')
    if not order_id:
        return generate_response({'error': 'Order ID required'}, status_code=400)

    try:
        payload = parse_body(event.get('body'))

        update_data = {
            k: (float(v) if isinstance(v, Decimal) else v)
            for k, v in payload.items()
            if k not in ('orderId', 'tenantId', '_id')
        }
        update_data['updatedAt'] = _now_iso()

        result = tenant_collection(COLLECTION_ORDER, tenant_id).update_one(
            {'orderId': order_id},
            {'$set': update_data}
        )

        if result.matched_count == 0:
            return generate_response({'error': 'Order not found'}, status_code=404)

        record_metric(event, "OrderUpdated", "Count", 1)

        return generate_response({'message': 'Order updated successfully'})

    except Exception as e:
        logger.error(f"Error updating order: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def list_orders(event, context):
    """列出订单 GET /orders"""
    tenant_id = get_tenant_id(event)

    try:
        orders = list(
            tenant_collection(COLLECTION_ORDER, tenant_id).find({}, {'_id': 0})
        )

        record_metric(event, "OrdersListed", "Count", 1)

        return generate_response({
            'orders': orders,
            'count': len(orders)
        })

    except Exception as e:
        logger.error(f"Error listing orders: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


# ---------------- FunctionGraph 入口 ----------------
def handler(event, context):
    """统一入口：按方法与路径分发"""
    http_method = (event.get('httpMethod') or 'GET').upper()
    path = (event.get('path') or '/').split('?')[0].rstrip('/') or '/'

    match = re.match(r'^/orders/([a-zA-Z0-9_-]+)$', path)
    if match:
        event['pathParameters'] = {'id': match.group(1)}
        dispatch = {
            'GET': get_order,
            'PUT': update_order,
        }
        handler_func = dispatch.get(http_method)
        if handler_func:
            return handler_func(event, context)
        if http_method == 'DELETE':
            return generate_response(
                {'error': 'Order deletion is not supported in this sample'},
                status_code=501
            )
        return generate_response({'error': 'Method not allowed'}, status_code=405)

    if path == '/orders':
        if http_method == 'GET':
            return list_orders(event, context)
        if http_method == 'POST':
            return create_order(event, context)

    return generate_response({'error': 'Not Found'}, status_code=404)
