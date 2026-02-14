#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 7b: Circuit Breaker (Java)"
echo "  元件: Spring Boot + Resilience4j"
echo "============================================"

NAMESPACE="poc-arch"

# --- 建立 Java 應用的 Docker Build ---
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
# === Flaky Service (沿用 PoC 7 的，若已部署則跳過) ===
apiVersion: v1
kind: ConfigMap
metadata:
  name: flaky-service
  labels:
    poc: circuit-breaker
data:
  app.py: |
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import random, time
    fail_rate = 0.6
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if random.random() < fail_rate:
                time.sleep(3)
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'{"error":"Internal Server Error"}')
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"status":"ok","data":"response from downstream"}')
    HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flaky-service
  labels:
    poc: circuit-breaker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flaky-service
  template:
    metadata:
      labels:
        app: flaky-service
    spec:
      containers:
        - name: app
          image: python:3.11-slim
          command: ['python', '/app/app.py']
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: code
              mountPath: /app
      volumes:
        - name: code
          configMap:
            name: flaky-service
---
apiVersion: v1
kind: Service
metadata:
  name: flaky-service
spec:
  selector:
    app: flaky-service
  ports:
    - port: 80
      targetPort: 8080
EOF

# === Resilience4j Spring Boot App (透過 ConfigMap + Init Container 建置) ===
cat <<'OUTER' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: r4j-source
  labels:
    poc: circuit-breaker-java
data:
  # --- build.gradle ---
  build.gradle: |
    plugins {
        id 'org.springframework.boot' version '3.2.5'
        id 'io.spring.dependency-management' version '1.1.4'
        id 'java'
    }
    group = 'com.poc'
    version = '1.0.0'
    java { sourceCompatibility = '17' }

    repositories { mavenCentral() }

    dependencies {
        implementation 'org.springframework.boot:spring-boot-starter-web'
        implementation 'org.springframework.boot:spring-boot-starter-actuator'
        implementation 'org.springframework.boot:spring-boot-starter-aop'
        implementation 'io.github.resilience4j:resilience4j-spring-boot3:2.2.0'
        implementation 'io.github.resilience4j:resilience4j-reactor:2.2.0'
    }

  # --- application.yml ---
  application.yml: |
    server:
      port: 8080

    management:
      endpoints:
        web:
          exposure:
            include: health,circuitbreakers,circuitbreakerevents
      endpoint:
        health:
          show-details: always
      health:
        circuitbreakers:
          enabled: true

    resilience4j:
      circuitbreaker:
        configs:
          default:
            registerHealthIndicator: true
            slidingWindowType: COUNT_BASED
            slidingWindowSize: 5
            minimumNumberOfCalls: 3
            failureRateThreshold: 50
            waitDurationInOpenState: 15s
            permittedNumberOfCallsInHalfOpenState: 2
            automaticTransitionFromOpenToHalfOpenEnabled: true
            recordExceptions:
              - java.lang.Exception
        instances:
          downstreamService:
            baseConfig: default

  # --- CircuitBreakerDemoApplication.java ---
  CircuitBreakerDemoApplication.java: |
    package com.poc.circuitbreaker;

    import org.springframework.boot.SpringApplication;
    import org.springframework.boot.autoconfigure.SpringBootApplication;

    @SpringBootApplication
    public class CircuitBreakerDemoApplication {
        public static void main(String[] args) {
            SpringApplication.run(CircuitBreakerDemoApplication.class, args);
        }
    }

  # --- DownstreamService.java ---
  DownstreamService.java: |
    package com.poc.circuitbreaker;

    import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
    import org.slf4j.Logger;
    import org.slf4j.LoggerFactory;
    import org.springframework.stereotype.Service;
    import org.springframework.web.client.RestTemplate;

    @Service
    public class DownstreamService {

        private static final Logger log = LoggerFactory.getLogger(DownstreamService.class);
        private final RestTemplate restTemplate = new RestTemplate();

        @CircuitBreaker(name = "downstreamService", fallbackMethod = "fallback")
        public String callDownstream() {
            log.info(">>> Calling downstream service...");
            String response = restTemplate.getForObject(
                "http://flaky-service/", String.class
            );
            log.info(">>> Downstream responded: {}", response);
            return response;
        }

        /**
         * Fallback: 當 Circuit Breaker 為 OPEN 或呼叫失敗時觸發
         */
        public String fallback(Exception ex) {
            log.warn(">>> FALLBACK triggered! Reason: {}", ex.getMessage());
            return "{\"source\":\"FALLBACK\",\"message\":\"Circuit breaker activated, returning cached/default response\",\"error\":\"" + ex.getMessage() + "\"}";
        }
    }

  # --- ApiController.java ---
  ApiController.java: |
    package com.poc.circuitbreaker;

    import io.github.resilience4j.circuitbreaker.CircuitBreaker;
    import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
    import org.springframework.http.ResponseEntity;
    import org.springframework.web.bind.annotation.GetMapping;
    import org.springframework.web.bind.annotation.RestController;

    import java.util.LinkedHashMap;
    import java.util.Map;

    @RestController
    public class ApiController {

        private final DownstreamService downstreamService;
        private final CircuitBreakerRegistry circuitBreakerRegistry;

        public ApiController(DownstreamService downstreamService,
                             CircuitBreakerRegistry circuitBreakerRegistry) {
            this.downstreamService = downstreamService;
            this.circuitBreakerRegistry = circuitBreakerRegistry;
        }

        @GetMapping("/api/call")
        public ResponseEntity<Map<String, Object>> call() {
            CircuitBreaker cb = circuitBreakerRegistry.circuitBreaker("downstreamService");

            String result = downstreamService.callDownstream();

            Map<String, Object> response = new LinkedHashMap<>();
            response.put("circuit_state", cb.getState().name());
            response.put("failure_rate", cb.getMetrics().getFailureRate());
            response.put("buffered_calls", cb.getMetrics().getNumberOfBufferedCalls());
            response.put("failed_calls", cb.getMetrics().getNumberOfFailedCalls());
            response.put("successful_calls", cb.getMetrics().getNumberOfSuccessfulCalls());
            response.put("not_permitted_calls", cb.getMetrics().getNumberOfNotPermittedCalls());
            response.put("response", result);

            return ResponseEntity.ok(response);
        }

        /**
         * 查看 Circuit Breaker 即時狀態
         */
        @GetMapping("/api/status")
        public ResponseEntity<Map<String, Object>> status() {
            CircuitBreaker cb = circuitBreakerRegistry.circuitBreaker("downstreamService");
            CircuitBreaker.Metrics metrics = cb.getMetrics();

            Map<String, Object> status = new LinkedHashMap<>();
            status.put("state", cb.getState().name());
            status.put("failure_rate_percent", metrics.getFailureRate());
            status.put("slow_call_rate_percent", metrics.getSlowCallRate());
            status.put("buffered_calls", metrics.getNumberOfBufferedCalls());
            status.put("failed_calls", metrics.getNumberOfFailedCalls());
            status.put("successful_calls", metrics.getNumberOfSuccessfulCalls());
            status.put("not_permitted_calls", metrics.getNumberOfNotPermittedCalls());

            Map<String, Object> config = new LinkedHashMap<>();
            config.put("sliding_window_size", cb.getCircuitBreakerConfig().getSlidingWindowSize());
            config.put("failure_rate_threshold", cb.getCircuitBreakerConfig().getFailureRateThreshold());
            config.put("wait_duration_in_open_state", cb.getCircuitBreakerConfig().getWaitDurationInOpenState().getSeconds() + "s");
            config.put("permitted_calls_in_half_open", cb.getCircuitBreakerConfig().getPermittedNumberOfCallsInHalfOpenState());

            status.put("config", config);
            return ResponseEntity.ok(status);
        }

        /**
         * 手動重置 Circuit Breaker
         */
        @GetMapping("/api/reset")
        public ResponseEntity<Map<String, String>> reset() {
            CircuitBreaker cb = circuitBreakerRegistry.circuitBreaker("downstreamService");
            cb.reset();
            return ResponseEntity.ok(Map.of(
                "action", "reset",
                "new_state", cb.getState().name()
            ));
        }
    }

  # --- settings.gradle ---
  settings.gradle: |
    rootProject.name = 'circuit-breaker-demo'
OUTER

# === Build Job: 用 Gradle 建置 Spring Boot JAR ===
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: r4j-build-script
  labels:
    poc: circuit-breaker-java
data:
  build-and-run.sh: |
    #!/bin/bash
    set -e

    echo "============================================"
    echo "  Building Resilience4j Circuit Breaker App"
    echo "============================================"

    APP_DIR=/app/project
    mkdir -p $APP_DIR/src/main/java/com/poc/circuitbreaker
    mkdir -p $APP_DIR/src/main/resources

    # Copy source files
    cp /source/build.gradle $APP_DIR/
    cp /source/settings.gradle $APP_DIR/
    cp /source/application.yml $APP_DIR/src/main/resources/
    cp /source/CircuitBreakerDemoApplication.java $APP_DIR/src/main/java/com/poc/circuitbreaker/
    cp /source/DownstreamService.java $APP_DIR/src/main/java/com/poc/circuitbreaker/
    cp /source/ApiController.java $APP_DIR/src/main/java/com/poc/circuitbreaker/

    cd $APP_DIR

    echo ">>> Running Gradle build..."
    gradle bootJar --no-daemon -q 2>&1 || {
      echo "Gradle build failed, trying with stacktrace..."
      gradle bootJar --no-daemon --stacktrace
    }

    echo ">>> Starting application..."
    java -jar build/libs/circuit-breaker-demo-1.0.0.jar
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: r4j-circuit-breaker
  labels:
    poc: circuit-breaker-java
spec:
  replicas: 1
  selector:
    matchLabels:
      app: r4j-circuit-breaker
  template:
    metadata:
      labels:
        app: r4j-circuit-breaker
    spec:
      containers:
        - name: app
          image: gradle:8.7-jdk17
          command: ['bash', '/scripts/build-and-run.sh']
          ports:
            - containerPort: 8080
          resources:
            requests:
              memory: 512Mi
              cpu: 500m
            limits:
              memory: 768Mi
              cpu: "1"
          readinessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 5
          volumeMounts:
            - name: source
              mountPath: /source
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: source
          configMap:
            name: r4j-source
        - name: scripts
          configMap:
            name: r4j-build-script
            defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: r4j-circuit-breaker
  labels:
    poc: circuit-breaker-java
spec:
  selector:
    app: r4j-circuit-breaker
  ports:
    - port: 80
      targetPort: 8080
EOF

echo ""
echo ">>> Resilience4j App 部署中 (首次啟動需要 Gradle 建置，約 2-3 分鐘)..."
echo ">>> 監控建置進度:"
echo "    kubectl logs -l app=r4j-circuit-breaker -n $NAMESPACE -f"
echo ""
echo "============================================"
echo "  驗證 Circuit Breaker (Java / Resilience4j)"
echo "============================================"
echo ""
echo "  kubectl port-forward svc/r4j-circuit-breaker -n $NAMESPACE 8086:80 &"
echo ""
echo "  # =============================="
echo "  # API 端點"
echo "  # =============================="
echo ""
echo "  # 1. 呼叫下游服務 (觸發 Circuit Breaker)"
echo "  curl -s http://localhost:8086/api/call | jq ."
echo ""
echo "  # 2. 查看 Circuit Breaker 即時狀態與設定"
echo "  curl -s http://localhost:8086/api/status | jq ."
echo ""
echo "  # 3. 手動重置 Circuit Breaker"
echo "  curl -s http://localhost:8086/api/reset | jq ."
echo ""
echo "  # 4. Actuator 端點 (Resilience4j 內建)"
echo "  curl -s http://localhost:8086/actuator/circuitbreakers | jq ."
echo "  curl -s http://localhost:8086/actuator/circuitbreakerevents | jq ."
echo ""
echo "  # =============================="
echo "  # 連續壓測觀察狀態轉換"
echo "  # =============================="
echo ""
echo "  for i in \$(seq 1 25); do"
echo "    echo \"--- Request \$i ---\""
echo "    curl -s http://localhost:8086/api/call | jq '{state: .circuit_state, failure_rate: .failure_rate, response: .response[:80]}'"
echo "    sleep 1"
echo "  done"
echo ""
echo "  # =============================="
echo "  # 預期觀察到的狀態轉換"
echo "  # =============================="
echo "  # "
echo "  #  CLOSED (正常呼叫)"
echo "  #    ↓  失敗率 >= 50% (5 次呼叫窗口中 >= 3 次失敗)"
echo "  #  OPEN (所有請求直接走 Fallback, 15 秒)"
echo "  #    ↓  等待 15 秒後自動轉換"
echo "  #  HALF_OPEN (允許 2 次試探)"
echo "  #    ↓  成功 → CLOSED / 失敗 → OPEN"
echo ""
echo "  # =============================="
echo "  # 與 Python 版比較"
echo "  # =============================="
echo "  # Python (PoC 7a):  自製狀態機，學習原理用"
echo "  # Java (PoC 7b):    Resilience4j，生產等級方案"
echo "  #   - 滑動窗口 (COUNT_BASED / TIME_BASED)"
echo "  #   - Actuator 監控整合"
echo "  #   - 註解驅動 (@CircuitBreaker)"
echo "  #   - 自動 OPEN → HALF_OPEN 轉換"
echo "  #   - 事件發布 (可接 Prometheus/Grafana)"
