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
KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -d "$SITE_DIR" ] || { echo "找不到 $SITE_DIR" >&2; exit 1; }
[ -f "$KUBECONFIG_PATH" ] || { echo "找不到 kubeconfig: $KUBECONFIG_PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo ":: 等待旧 Pod 退出（PVC 是 ReadWriteOnce，必须 Recreate）..."
"${KUBECTL[@]}" scale deployment/install-site -n "$NAMESPACE" --replicas=0 2>/dev/null || true
"${KUBECTL[@]}" wait --for=delete pod -l app=install-site -n "$NAMESPACE" --timeout=90s 2>/dev/null || true

echo ":: 生成 ConfigMap ..."
"${KUBECTL[@]}" create configmap install-site \
  --namespace "$NAMESPACE" \
  --from-file=index.html="$SITE_DIR/index.html" \
  --from-file=install.sh="$SITE_DIR/install.sh" \
  --from-file=install.ps1="$SITE_DIR/install.ps1" \
  --from-file=nginx.conf="$ROOT/deploy/nginx.conf" \
  --dry-run=client -o yaml > "$OUT/configmap.yaml"

{
  cat "$OUT/configmap.yaml"
  echo "---"
  cat "$ROOT/deploy/workloads.yaml"
} > "$OUT/all.yaml"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ":: server-side dry-run ..."
  "${KUBECTL[@]}" apply --dry-run=server -f "$OUT/all.yaml"
  exit 0
fi

echo ":: apply ..."
# configmap 可能还在旧 Pod 里被引用；先应用其余资源，再补一次 ConfigMap
"${KUBECTL[@]}" apply -f "$OUT/all.yaml"

echo ":: 等待 rollout ..."
"${KUBECTL[@]}" rollout status deployment/install-site -n "$NAMESPACE" --timeout=180s

echo ":: 同步截图到 PVC ..."
POD="$("${KUBECTL[@]}" get pod -n "$NAMESPACE" -l app=install-site \
  -o jsonpath='{.items[0].metadata.name}')"

if compgen -G "$SITE_DIR/shots/*.png" > /dev/null; then
  if tar -C "$SITE_DIR" -cf - shots | "${KUBECTL[@]}" exec -i "$POD" -n "$NAMESPACE" -- \
      sh -ec 'rm -rf /usr/share/nginx/html/shots/* && tar -xf - -C /usr/share/nginx/html'; then
    echo "   已同步 $(ls "$SITE_DIR/shots"/*.png | wc -l | tr -d ' ') 张截图"
  else
    echo "   （截图写入失败，页面会显示占位图）"
  fi
else
  echo ":: 没有截图，跳过（占位图会保留）"
fi

echo ":: 检查 HTTPRoute ..."
"${KUBECTL[@]}" get httproute install-site-public -n "$NAMESPACE" -o wide

echo
echo "完成。站点地址: https://install.ncuos.com"
