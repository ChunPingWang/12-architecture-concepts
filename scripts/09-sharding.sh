#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 9: Sharding"
echo "  元件: CockroachDB (內建分片/Range-based)"
echo "============================================"

NAMESPACE="poc-arch"

# CockroachDB 比 Vitess 更適合 Kind PoC (資源需求較低)
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: Service
metadata:
  name: cockroachdb
  labels:
    poc: sharding
spec:
  clusterIP: None
  selector:
    app: cockroachdb
  ports:
    - name: grpc
      port: 26257
      targetPort: 26257
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cockroachdb
  labels:
    poc: sharding
spec:
  serviceName: cockroachdb
  replicas: 3
  selector:
    matchLabels:
      app: cockroachdb
  template:
    metadata:
      labels:
        app: cockroachdb
    spec:
      containers:
        - name: cockroachdb
          image: cockroachdb/cockroach:v23.2.0
          command:
            - /cockroach/cockroach
            - start
            - --insecure
            - --advertise-addr=$(POD_NAME).cockroachdb.poc-arch.svc.cluster.local
            - --join=cockroachdb-0.cockroachdb.poc-arch.svc.cluster.local,cockroachdb-1.cockroachdb.poc-arch.svc.cluster.local,cockroachdb-2.cockroachdb.poc-arch.svc.cluster.local
            - --cache=64MiB
            - --max-sql-memory=64MiB
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - containerPort: 26257
            - containerPort: 8080
          resources:
            limits:
              memory: 256Mi
              cpu: 250m
          volumeMounts:
            - name: data
              mountPath: /cockroach/cockroach-data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
---
# 初始化叢集 Job
apiVersion: batch/v1
kind: Job
metadata:
  name: crdb-init
  labels:
    poc: sharding
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: init
          image: cockroachdb/cockroach:v23.2.0
          command:
            - /cockroach/cockroach
            - init
            - --insecure
            - --host=cockroachdb-0.cockroachdb.poc-arch.svc.cluster.local
---
# Sharding Demo ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: shard-demo
  labels:
    poc: sharding
data:
  demo.sql: |
    -- 建立分片表 (Hash-based sharding)
    CREATE DATABASE IF NOT EXISTS poc_shard;
    USE poc_shard;

    -- 按 customer_id 做 Hash Sharding
    CREATE TABLE IF NOT EXISTS orders (
      order_id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
      customer_id INT NOT NULL,
      product VARCHAR(100),
      amount DECIMAL(10,2),
      created_at TIMESTAMP DEFAULT now(),
      INDEX idx_customer (customer_id) USING HASH
    );

    -- 插入測試資料 (分散到不同 Range/Shard)
    INSERT INTO orders (customer_id, product, amount) VALUES
      (1001, 'Laptop', 999.99),
      (2002, 'Phone', 699.99),
      (3003, 'Tablet', 499.99),
      (4004, 'Monitor', 349.99),
      (5005, 'Keyboard', 129.99),
      (1001, 'Mouse', 49.99),
      (2002, 'Headset', 199.99),
      (6006, 'Camera', 899.99),
      (7007, 'Speaker', 249.99),
      (8008, 'SSD', 159.99);

    -- 查看 Range 分佈 (Sharding 狀態)
    SHOW RANGES FROM TABLE orders;

    -- 查詢特定分片的資料
    SELECT customer_id, product, amount FROM orders WHERE customer_id = 1001;

    -- 查看叢集節點
    SELECT node_id, address, is_live FROM crdb_internal.gossip_nodes;
EOF

echo ""
echo ">>> 等待 CockroachDB 就緒..."
kubectl wait --for=condition=ready pod cockroachdb-0 -n $NAMESPACE --timeout=120s 2>/dev/null || echo "CockroachDB 部署中..."

echo ""
echo "============================================"
echo "  驗證 Sharding"
echo "============================================"
echo ""
echo "  # 1. 開啟 CockroachDB UI"
echo "  kubectl port-forward svc/cockroachdb -n $NAMESPACE 8084:8080 &"
echo "  # http://localhost:8084 查看 Range 分佈圖"
echo ""
echo "  # 2. 執行 Sharding Demo SQL"
echo "  kubectl exec -it cockroachdb-0 -n $NAMESPACE -- \\"
echo "    /cockroach/cockroach sql --insecure < /dev/stdin <<< \"\$(kubectl get cm shard-demo -n $NAMESPACE -o jsonpath='{.data.demo\\.sql}')\""
echo ""
echo "  # 或互動模式"
echo "  kubectl exec -it cockroachdb-0 -n $NAMESPACE -- /cockroach/cockroach sql --insecure"
echo ""
echo "預期結果: 資料自動分散到 3 個節點的不同 Range (Shard)"
