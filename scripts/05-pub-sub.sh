#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 5: Publish-Subscribe"
echo "  元件: Apache Kafka (Strimzi Operator)"
echo "============================================"

NAMESPACE="poc-arch"

# 安裝 Strimzi Operator
echo ">>> 安裝 Strimzi Kafka Operator..."
kubectl create namespace kafka 2>/dev/null || true
kubectl apply -f "https://strimzi.io/install/latest?namespace=kafka" -n kafka 2>/dev/null || true

echo ">>> 等待 Strimzi Operator 就緒..."
kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=120s 2>/dev/null || echo "Operator 部署中..."

# 建立 Kafka 叢集
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: poc-kafka
  labels:
    poc: pub-sub
spec:
  kafka:
    version: 3.7.0
    replicas: 1
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
    storage:
      type: ephemeral
    resources:
      limits:
        memory: 512Mi
        cpu: 500m
  zookeeper:
    replicas: 1
    storage:
      type: ephemeral
    resources:
      limits:
        memory: 256Mi
        cpu: 250m
  entityOperator:
    topicOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: events
  labels:
    strimzi.io/cluster: poc-kafka
    poc: pub-sub
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: 600000
EOF

echo ""
echo ">>> Kafka 叢集部署中 (需要 2-3 分鐘)..."
echo ">>> 可用以下指令確認狀態:"
echo "    kubectl get kafka -n $NAMESPACE"
echo ""
echo "============================================"
echo "  驗證 Publish-Subscribe"
echo "============================================"
echo ""
echo "  # 等 Kafka Ready 後..."
echo ""
echo "  # 1. 啟動 Consumer Group A (Terminal 1)"
echo "  kubectl run kafka-consumer-a --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 -- \\"
echo "    bin/kafka-console-consumer.sh --bootstrap-server poc-kafka-kafka-bootstrap:9092 \\"
echo "      --topic events --group group-a --from-beginning"
echo ""
echo "  # 2. 啟動 Consumer Group B (Terminal 2)"
echo "  kubectl run kafka-consumer-b --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 -- \\"
echo "    bin/kafka-console-consumer.sh --bootstrap-server poc-kafka-kafka-bootstrap:9092 \\"
echo "      --topic events --group group-b --from-beginning"
echo ""
echo "  # 3. Producer 發送訊息 (Terminal 3)"
echo "  kubectl run kafka-producer --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 -- \\"
echo "    bin/kafka-console-producer.sh --bootstrap-server poc-kafka-kafka-bootstrap:9092 \\"
echo "      --topic events"
echo ""
echo "預期結果: 每條訊息會被 Group A 和 Group B 各收到一次 (Fan-out)"
