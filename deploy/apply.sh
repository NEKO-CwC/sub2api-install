#!/usr/bin/env bash
# 把 site/ 打包成 ConfigMap，再连同 Deployment / Service / HTTPRoute 一起 apply。
#
#   ./deploy/apply.sh            # 部署
#   ./deploy/apply.sh --dry-run  # 只做 server-side dry-run
#
# 需要 kubectl 和能访问 sub2api namespace 的 kubeconfig。

set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/sub2api-rancher.json}"
NAMESPACE="sub2api"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="$ROOT/site"
OUT="$ROOT/deploy/generated"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -d "$SITE_DIR" ] || { echo "找不到 $SITE_DIR" >&2; exit 1; }
[ -f "$KUBECONFIG_PATH" ] || { echo "找不到 kubeconfig: $KUBECONFIG_PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo ":: 生成 ConfigMap ..."
kubectl --kubeconfig "$KUBECONFIG_PATH" create configmap install-site \
  --namespace "$NAMESPACE" \
  --from-file=index.html="$SITE_DIR/index.html" \
  --from-file=install.sh="$SITE_DIR/install.sh" \
  --from-file=install.ps1="$SITE_DIR/install.ps1" \
  --from-file=nginx.conf="$ROOT/deploy/nginx.conf" \
  --dry-run=client -o yaml > "$OUT/configmap.yaml"

if [ -d "$SITE_DIR/shots" ] && [ -n "$(ls -A "$SITE_DIR/shots" 2>/dev/null)" ]; then
  echo ":: 生成截图 ConfigMap ..."
  kubectl --kubeconfig "$KUBECONFIG_PATH" create configmap install-site-shots \
    --namespace "$NAMESPACE" \
    --from-file="$SITE_DIR/shots" \
    --dry-run=client -o yaml > "$OUT/configmap-shots.yaml"
else
  echo ":: 没有截图，跳过（占位图会保留）"
  rm -f "$OUT/configmap-shots.yaml"
fi

echo ":: 合并清单 ..."
{
  cat "$OUT/configmap.yaml"
  echo "---"
  [ -f "$OUT/configmap-shots.yaml" ] && { cat "$OUT/configmap-shots.yaml"; echo "---"; }
  cat "$ROOT/deploy/workloads.yaml"
} > "$OUT/all.yaml"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ":: server-side dry-run ..."
  kubectl --kubeconfig "$KUBECONFIG_PATH" apply --dry-run=server -f "$OUT/all.yaml"
  exit 0
fi

echo ":: apply ..."
kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f "$OUT/all.yaml"

echo ":: 等待 rollout ..."
kubectl --kubeconfig "$KUBECONFIG_PATH" rollout status deployment/install-site -n "$NAMESPACE" --timeout=180s

echo ":: 检查 HTTPRoute ..."
kubectl --kubeconfig "$KUBECONFIG_PATH" get httproute install-site-public -n "$NAMESPACE" -o wide

echo
echo "完成。站点地址: https://install.ncuos.com"
