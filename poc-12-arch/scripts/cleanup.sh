#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  清理所有 PoC 資源"
echo "============================================"

read -p "確定要刪除整個 Kind 叢集 arch-poc? (y/N) " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
  # 清理 Strimzi
  kubectl delete -f "https://strimzi.io/install/latest?namespace=kafka" -n kafka 2>/dev/null || true
  kubectl delete namespace kafka 2>/dev/null || true

  # 刪除 Kind 叢集
  kind delete cluster --name arch-poc
  echo ">>> 叢集已刪除。"
else
  echo ">>> 取消清理。"
  echo ""
  echo "如需只清理特定 PoC:"
  echo "  kubectl delete all,cm,ingress -l poc=load-balancing -n poc-arch"
  echo "  kubectl delete all,cm,ingress -l poc=caching -n poc-arch"
  echo "  kubectl delete all,cm -l poc=cdn -n poc-arch"
  echo "  kubectl delete all,cm -l poc=message-queue -n poc-arch"
  echo "  kubectl delete all,cm -l poc=pub-sub -n poc-arch  # + Kafka CR"
  echo "  kubectl delete all,cm -l poc=api-gateway -n poc-arch  # + Helm"
  echo "  kubectl delete all,cm -l poc=circuit-breaker -n poc-arch"
  echo "  kubectl delete all,cm -l poc=service-discovery -n poc-arch"
  echo "  kubectl delete all,cm,pvc -l poc=sharding -n poc-arch"
  echo "  kubectl delete all,cm,ingress -l poc=rate-limiting -n poc-arch"
  echo "  kubectl delete all,cm -l poc=consistent-hashing -n poc-arch"
  echo "  kubectl delete all,cm,hpa -l poc=auto-scaling -n poc-arch"
fi
