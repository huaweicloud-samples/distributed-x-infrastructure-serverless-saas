# -*- coding: utf-8 -*-
"""
产品服务 - 华为云 FunctionGraph 版本
产品服务：租户产品 CRUD

多租户隔离：单库 + 按租户拆集合（products_<tenantId>），
集合名由 common.tenant_collection 统一生成，避免越权访问。
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
def get_product(event, context):
    """获取单个产品 GET /products/{id}"""
    tenant_id = get_tenant_id(event)
    tracer.put_annotation(key="TenantId", value=tenant_id)

    product_id = event.get('pathParameters', {}).get('id')
    if not product_id:
        return generate_response({'error': 'Product ID required'}, status_code=400)

    logger.info(f"Getting product: {product_id}")

    try:
        product = tenant_collection(COLLECTION_PRODUCT, tenant_id).find_one(
            {'productId': product_id}
        )
        if not product:
            return generate_response({'error': 'Product not found'}, status_code=404)

        product.pop('_id', None)
        record_metric(event, "SingleProductRequested", "Count", 1)

        return generate_response(product)

    except Exception as e:
        logger.error(f"Error getting product: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def create_product(event, context):
    """创建产品 POST /products"""
    tenant_id = get_tenant_id(event)
    tracer.put_annotation(key="TenantId", value=tenant_id)

    try:
        payload = parse_body(event.get('body'))

        product_id = payload.get('productId') or f"PROD-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"

        product = {
            'tenantId': tenant_id,
            'productId': product_id,
            'productName': payload.get('productName', ''),
            'productDescription': payload.get('productDescription', ''),
            'price': float(payload.get('price', 0)),
            'category': payload.get('category', ''),
            'stock': int(payload.get('stock', 0)),
            'createdAt': _now_iso(),
            'updatedAt': _now_iso()
        }

        tenant_collection(COLLECTION_PRODUCT, tenant_id).insert_one(product)
        product.pop('_id', None)

        record_metric(event, "ProductCreated", "Count", 1)

        return generate_response(product, status_code=201)

    except ValueError as e:
        logger.error(f"Invalid request: {str(e)}")
        return generate_response({'error': str(e)}, status_code=400)
    except Exception as e:
        logger.error(f"Error creating product: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def update_product(event, context):
    """更新产品 PUT /products/{id}"""
    tenant_id = get_tenant_id(event)

    product_id = event.get('pathParameters', {}).get('id')
    if not product_id:
        return generate_response({'error': 'Product ID required'}, status_code=400)

    try:
        payload = parse_body(event.get('body'))

        update_data = {
            k: (float(v) if isinstance(v, Decimal) else v)
            for k, v in payload.items()
            if k not in ('productId', 'tenantId', '_id')
        }
        # 数值型字段统一落库为 float，避免 Decimal 序列化为字符串
        for numeric_field in ('price',):
            if numeric_field in update_data:
                update_data[numeric_field] = float(update_data[numeric_field])
        update_data['updatedAt'] = _now_iso()

        result = tenant_collection(COLLECTION_PRODUCT, tenant_id).update_one(
            {'productId': product_id},
            {'$set': update_data}
        )

        if result.matched_count == 0:
            return generate_response({'error': 'Product not found'}, status_code=404)

        record_metric(event, "ProductUpdated", "Count", 1)

        return generate_response({'message': 'Product updated successfully'})

    except Exception as e:
        logger.error(f"Error updating product: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def delete_product(event, context):
    """删除产品 DELETE /products/{id}"""
    tenant_id = get_tenant_id(event)

    product_id = event.get('pathParameters', {}).get('id')
    if not product_id:
        return generate_response({'error': 'Product ID required'}, status_code=400)

    try:
        result = tenant_collection(COLLECTION_PRODUCT, tenant_id).delete_one(
            {'productId': product_id}
        )

        if result.deleted_count == 0:
            return generate_response({'error': 'Product not found'}, status_code=404)

        record_metric(event, "ProductDeleted", "Count", 1)

        return generate_response({'message': 'Product deleted successfully'})

    except Exception as e:
        logger.error(f"Error deleting product: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


@Tracer.capture_lambda_handler
def list_products(event, context):
    """列出产品 GET /products"""
    tenant_id = get_tenant_id(event)

    try:
        products = list(
            tenant_collection(COLLECTION_PRODUCT, tenant_id).find({}, {'_id': 0})
        )

        record_metric(event, "ProductsListed", "Count", 1)

        return generate_response({
            'products': products,
            'count': len(products)
        })

    except Exception as e:
        logger.error(f"Error listing products: {str(e)}")
        return generate_response({'error': str(e)}, status_code=500)


# ---------------- FunctionGraph 入口 ----------------
def handler(event, context):
    """统一入口：按方法与路径分发"""
    http_method = (event.get('httpMethod') or 'GET').upper()
    path = (event.get('path') or '/').split('?')[0].rstrip('/') or '/'

    match = re.match(r'^/products/([a-zA-Z0-9_-]+)$', path)
    if match:
        event['pathParameters'] = {'id': match.group(1)}
        dispatch = {
            'GET': get_product,
            'PUT': update_product,
            'DELETE': delete_product,
        }
        handler_func = dispatch.get(http_method)
        if handler_func:
            return handler_func(event, context)
        return generate_response({'error': 'Method not allowed'}, status_code=405)

    if path == '/products':
        if http_method == 'GET':
            return list_products(event, context)
        if http_method == 'POST':
            return create_product(event, context)

    return generate_response({'error': 'Not Found'}, status_code=404)
