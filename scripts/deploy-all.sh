#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  部署全部 12 個 PoC"
echo "============================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase 0
echo ">>> Phase 0: 環境建置"
bash "$SCRIPT_DIR/00-setup-cluster.sh"

# Phase 1: 流量管理
echo ""
echo ">>> Phase 1: 流量管理 (PoC 1, 6, 10)"
bash "$SCRIPT_DIR/01-load-balancing.sh"
bash "$SCRIPT_DIR/06-api-gateway.sh"
bash "$SCRIPT_DIR/10-rate-limiting.sh"

# Phase 2: 資料層
echo ""
echo ">>> Phase 2: 資料層 (PoC 2, 9, 11)"
bash "$SCRIPT_DIR/02-caching.sh"
bash "$SCRIPT_DIR/09-sharding.sh"
bash "$SCRIPT_DIR/11-consistent-hashing.sh"

# Phase 3: 訊息傳遞
echo ""
echo ">>> Phase 3: 訊息傳遞 (PoC 4, 5)"
bash "$SCRIPT_DIR/04-message-queue.sh"
bash "$SCRIPT_DIR/05-pub-sub.sh"

# Phase 4: 韌性與擴展
echo ""
echo ">>> Phase 4: 韌性與擴展 (PoC 3, 7, 8, 12)"
bash "$SCRIPT_DIR/03-cdn.sh"
bash "$SCRIPT_DIR/07-circuit-breaker.sh"
bash "$SCRIPT_DIR/08-service-discovery.sh"
bash "$SCRIPT_DIR/12-auto-scaling.sh"

echo ""
echo "============================================"
echo "  全部部署完成！"
echo "============================================"
echo ""
echo "  各 PoC 驗證指令請參考個別腳本的輸出。"
echo ""
echo "  快速查看所有資源:"
echo "  kubectl get all -n poc-arch"
echo ""
echo "  清理:"
echo "  kind delete cluster --name arch-poc"
