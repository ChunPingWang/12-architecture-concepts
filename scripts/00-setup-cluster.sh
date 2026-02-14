#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  Phase 0: 建立 Kind 多節點叢集"
echo "============================================"

CLUSTER_NAME="arch-poc"

# 檢查是否已存在
if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "叢集 $CLUSTER_NAME 已存在，跳過建立。"
  echo "如需重建，請先執行: kind delete cluster --name $CLUSTER_NAME"
else
  echo ">>> 建立 Kind 叢集: $CLUSTER_NAME (1 control-plane + 3 workers)"
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 30000
        hostPort: 30000
        protocol: TCP
      - containerPort: 30001
        hostPort: 30001
        protocol: TCP
      - containerPort: 30002
        hostPort: 30002
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
EOF
fi

echo ""
echo ">>> 安裝 metrics-server (AutoScaling 需要)"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || true
# Kind 環境需要 patch --kubelet-insecure-tls
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true

echo ""
echo ">>> 安裝 NGINX Ingress Controller"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml 2>/dev/null || true

echo ""
echo ">>> 等待 Ingress Controller 就緒..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s 2>/dev/null || echo "Ingress Controller 尚未就緒，請稍後確認。"

echo ""
echo ">>> 建立共用 Namespace"
kubectl create namespace poc-arch 2>/dev/null || true

echo ""
echo "============================================"
echo "  叢集建立完成！"
echo "  kubectl cluster-info --context kind-$CLUSTER_NAME"
echo "============================================"
kubectl get nodes
