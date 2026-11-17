# Lab 6：扩展性与性能优化

## 目标

学习如何优化 Serverless 应用的性能。

## 内容

- 函数冷启动优化
- 数据库连接管理
- 代码包体积控制

## 步骤

### 1. 冷启动优化

**挂载 VPC 会显著拉长冷启动**——函数需要先加入 VPC 弹性网卡。优化手段：

- 合理设置 `memory_size`：内存与 CPU 同步调整，内存越大初始化越快
- 避免在模块导入阶段做重活（不要在顶层执行数据库查询）
- 预热：在流量到来前手动调用一次函数

```hcl
# infra/main.tf
resource "huaweicloud_fgs_function" "product_service" {
  memory_size = 256   # 按实际负载调整
  timeout     = 30
}
```

### 2. 数据库连接管理

`common.py` 使用进程内单例，避免每次请求重建连接：

```python
_mongo_client = None

def get_db_client():
    """获取 GeminiDB 连接（进程内单例）"""
    global _mongo_client
    if _mongo_client is None:
        host, port = _parse_host()
        _mongo_client = MongoClient(
            host=host,
            port=port,
            username=GEMINI_DB_USER,
            password=os.environ.get('GEMINI_DB_SECRET', ''),  # 凭据取自环境变量，不落盘
            authSource='admin',
            replicaSet=GEMINI_DB_REPLICA,
            serverSelectionTimeoutMS=10000,
        )
    return _mongo_client
```

关键点：
- `serverSelectionTimeoutMS` 设为 10 秒，避免网络异常时函数长时间挂起
- 连接放在全局单例中，函数被复用时无需重连
- 副本集模式下必须指定 `replicaSet`，否则驱动会做单节点拓扑发现

### 3. 代码包体积控制

每个函数包只包含入口文件与三个公共模块，依赖由 FunctionGraph 运行时提供：

```bash
# 打包后查看内容，确认没有多余依赖
python -m zipfile -l build/product-service.zip
```

| 文件 | 作用 |
|------|------|
| `<function>.py` | 入口，`handler = <function>.handler` |
| `common.py` | 数据库访问层 |
| `logger.py` | 结构化日志 |
| `utils.py` | 响应封装与计量 |

不要把 `node_modules`、`.git`、本地虚拟环境打进代码包——既拖慢冷启动，也会泄漏开发环境信息。

### 4. 并发与扩缩容

```hcl
# 按需调整最大实例数与并发数
resource "huaweicloud_fgs_function" "product_service" {
  max_instance_num = 100
  concurrency_num  = 40
}
```

## 验证

- [ ] 连续调用时连接被复用，未出现连接数暴涨
- [ ] 数据库网络异常时函数在超时窗口内返回错误而非挂死
- [ ] 代码包内无多余文件
- [ ] 冷启动耗时可接受，业务调用未超时
