# -*- coding: utf-8 -*-
"""
日志模块 - 华为云 FunctionGraph 版本
结构化日志组件：统一输出 JSON 行，便于在 LTS 中检索
"""

import os
import json
import logging
from datetime import datetime, timezone

# 配置日志级别
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO').upper()

# 标准库日志：用于捕获依赖库的输出
logging.basicConfig(level=LOG_LEVEL, format='%(asctime)s %(levelname)s %(message)s')
logging.getLogger().setLevel(LOG_LEVEL)


class Logger:
    """结构化日志组件（统一字段输出）"""

    def __init__(self, service_name=None):
        self.service_name = service_name or os.environ.get('SERVICE_NAME', 'serverless-saas')

    @staticmethod
    def _now():
        return datetime.now(timezone.utc).isoformat()

    def log_with_tenant_context(self, event, message):
        """记录带租户上下文的日志"""
        tenant_id = 'unknown'
        try:
            tenant_id = (
                event.get('requestContext', {})
                .get('authorizer', {})
                .get('tenantId', 'unknown')
            )
        except Exception:
            pass

        log_entry = {
            'timestamp': self._now(),
            'service': self.service_name,
            'tenant_id': tenant_id,
            'message': message,
        }
        print(json.dumps(log_entry, ensure_ascii=False))

    def info(self, message):
        print(json.dumps({
            'timestamp': self._now(),
            'service': self.service_name,
            'level': 'INFO',
            'message': message,
        }, ensure_ascii=False))

    def error(self, message):
        print(json.dumps({
            'timestamp': self._now(),
            'service': self.service_name,
            'level': 'ERROR',
            'message': message,
        }, ensure_ascii=False))

    def warning(self, message):
        print(json.dumps({
            'timestamp': self._now(),
            'service': self.service_name,
            'level': 'WARNING',
            'message': message,
        }, ensure_ascii=False))

    def debug(self, message):
        print(json.dumps({
            'timestamp': self._now(),
            'service': self.service_name,
            'level': 'DEBUG',
            'message': message,
        }, ensure_ascii=False))


# 默认日志实例
logger = Logger()
log = logger

# 兼容旧调用方式：from logger import logger / from logger import log_with_tenant_context
log_with_tenant_context = logger.log_with_tenant_context
