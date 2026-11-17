#!/usr/bin/env bash
# ============================================================================
# 构建各函数代码包 -> build/<name>.zip
#   - 依赖：Python 3.8+ 与系统 zip 命令（或 python -m zipfile）
#   - 产物：build/tenant-management.zip ... build/tenant-authorizer.zip（4 个）
#   - 之后由 Terraform（infra/main.tf 的 huaweicloud_obs_bucket_object）上传到 OBS
#
# 每个包的目录结构（平铺，FunctionGraph 直接按 handler 名索引）：
#   tenant_management.py    函数入口（handler = tenant_management.handler）
#   product_service.py
#   order_service.py
#   authorizer.py
#   common.py               公共数据访问层
#   logger.py               结构化日志
#   utils.py                响应封装与指标
#
# 用法： ./scripts/build-packages.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/functions"
BUILD="$ROOT/build"
STAGE="$BUILD/.stage"

# 公共模块：每个包都要带上
COMMON_FILES=(common.py logger.py utils.py)

# 函数名 -> 入口源文件
declare -A ENTRY=(
  [tenant-management]="$SRC/tenant_management.py"
  [product-service]="$SRC/product_service.py"
  [order-service]="$SRC/order_service.py"
  [tenant-authorizer]="$SRC/authorizer.py"
)

echo "[1/3] 检查源文件"
for name in "${!ENTRY[@]}"; do
  entry="${ENTRY[$name]}"
  [ -f "$entry" ] || { echo "缺少入口文件: $entry" >&2; exit 1; }
done
for f in "${COMMON_FILES[@]}"; do
  [ -f "$SRC/$f" ] || { echo "缺少公共模块: $SRC/$f" >&2; exit 1; }
done

echo "[2/3] 打包各函数代码"
rm -rf "$STAGE"
mkdir -p "$STAGE"

for name in "${!ENTRY[@]}"; do
  pkg="$STAGE/$name"
  mkdir -p "$pkg"

  cp "${ENTRY[$name]}" "$pkg/"
  for f in "${COMMON_FILES[@]}"; do
    cp "$SRC/$f" "$pkg/$f"
  done

  rm -f "$BUILD/$name.zip"
  if command -v zip >/dev/null 2>&1; then
    ( cd "$pkg" && zip -q -r "$BUILD/$name.zip" . )
  else
    ( cd "$pkg" && python -m zipfile -c "$BUILD/$name.zip" ./*.py )
  fi
  echo "  - $name.zip"
done

echo "[3/3] 清理暂存目录"
rm -rf "$STAGE"

echo
echo "完成：函数代码包已生成于 $BUILD/"
ls -1 "$BUILD"/*.zip
echo
echo "下一步： cd infra && terraform init && terraform apply"
echo "（Terraform 会自动建桶并把 build/*.zip 上传到 OBS，无需手工 obsutil 上传）"
