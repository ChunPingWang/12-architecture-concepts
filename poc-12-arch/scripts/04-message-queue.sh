#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 4: Message Queue"
echo "  元件: RabbitMQ"
echo "============================================"

NAMESPACE="poc-arch"

cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rabbitmq
  labels:
    poc: message-queue
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
        - name: rabbitmq
          image: rabbitmq:3-management-alpine
          ports:
            - containerPort: 5672
              name: amqp
            - containerPort: 15672
              name: management
          env:
            - name: RABBITMQ_DEFAULT_USER
              value: "guest"
            - name: RABBITMQ_DEFAULT_PASS
              value: "guest"
          resources:
            limits:
              memory: 256Mi
              cpu: 500m
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  labels:
    poc: message-queue
spec:
  selector:
    app: rabbitmq
  ports:
    - name: amqp
      port: 5672
      targetPort: 5672
    - name: management
      port: 15672
      targetPort: 15672
---
# --- Producer Job ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mq-producer
  labels:
    poc: message-queue
data:
  producer.py: |
    import pika
    import json
    import time

    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host='rabbitmq', credentials=pika.PlainCredentials('guest', 'guest'))
    )
    channel = connection.channel()
    channel.queue_declare(queue='orders', durable=True)

    for i in range(20):
        order = {"order_id": f"ORD-{i+1:04d}", "product": f"Product-{i%5}", "qty": (i % 10) + 1}
        channel.basic_publish(
            exchange='',
            routing_key='orders',
            body=json.dumps(order),
            properties=pika.BasicProperties(delivery_mode=2)
        )
        print(f"[Producer] Sent: {order}")
        time.sleep(0.5)

    connection.close()
    print("[Producer] Done. 20 messages sent.")
---
# --- Consumer Deployment ---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mq-consumer
  labels:
    poc: message-queue
data:
  consumer.py: |
    import pika
    import json
    import os
    import time

    pod_name = os.getenv("POD_NAME", "unknown")

    def callback(ch, method, properties, body):
        order = json.loads(body)
        print(f"[Consumer {pod_name}] Processing: {order}")
        time.sleep(1)  # 模擬處理時間
        ch.basic_ack(delivery_tag=method.delivery_tag)
        print(f"[Consumer {pod_name}] Done: {order['order_id']}")

    while True:
        try:
            connection = pika.BlockingConnection(
                pika.ConnectionParameters(host='rabbitmq', credentials=pika.PlainCredentials('guest', 'guest'))
            )
            channel = connection.channel()
            channel.queue_declare(queue='orders', durable=True)
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(queue='orders', on_message_callback=callback)
            print(f"[Consumer {pod_name}] Waiting for messages...")
            channel.start_consuming()
        except Exception as e:
            print(f"[Consumer {pod_name}] Connection error: {e}, retrying in 5s...")
            time.sleep(5)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mq-consumer
  labels:
    poc: message-queue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: mq-consumer
  template:
    metadata:
      labels:
        app: mq-consumer
    spec:
      containers:
        - name: consumer
          image: python:3.11-slim
          command: ['sh', '-c', 'pip install pika -q && python /app/consumer.py']
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          volumeMounts:
            - name: code
              mountPath: /app
      volumes:
        - name: code
          configMap:
            name: mq-consumer
EOF

echo ""
echo ">>> 等待 RabbitMQ 就緒..."
kubectl wait --for=condition=ready pod -l app=rabbitmq -n $NAMESPACE --timeout=90s

echo ""
echo "============================================"
echo "  驗證 Message Queue"
echo "============================================"
echo ""
echo "  # 1. 開啟 RabbitMQ Management UI"
echo "  kubectl port-forward svc/rabbitmq -n $NAMESPACE 15672:15672 &"
echo "  # http://localhost:15672 (guest/guest)"
echo ""
echo "  # 2. 執行 Producer 發送訊息"
echo "  kubectl run mq-producer --rm -it --restart=Never -n $NAMESPACE \\"
echo "    --image=python:3.11-slim \\"
echo "    --overrides='{\"spec\":{\"volumes\":[{\"name\":\"code\",\"configMap\":{\"name\":\"mq-producer\"}}],\"containers\":[{\"name\":\"mq-producer\",\"image\":\"python:3.11-slim\",\"command\":[\"sh\",\"-c\",\"pip install pika -q && python /app/producer.py\"],\"volumeMounts\":[{\"name\":\"code\",\"mountPath\":\"/app\"}]}]}}'"
echo ""
echo "  # 3. 觀察 Consumer 日誌"
echo "  kubectl logs -l app=mq-consumer -n $NAMESPACE -f --max-log-requests=5"
echo ""
echo "預期結果: 20 筆訊息由 3 個 Consumer 競爭消費"
