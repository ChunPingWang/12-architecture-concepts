#!/bin/bash
set -euo pipefail

echo "============================================"
echo "  PoC 7c: Circuit Breaker (Spring Boot 4)"
echo "  元件: Spring Boot 4 + Spring Cloud"
echo "        Circuit Breaker + Resilience4j"
echo "============================================"

NAMESPACE="poc-arch"

# 確保 flaky-service 已部署 (與 7a/7b 共用)
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
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
            if self.path == "/health":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"status":"UP"}')
                return
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

# === Spring Boot 4 + Spring Cloud Circuit Breaker 原始碼 ===
cat <<'OUTER' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: sccb-source
  labels:
    poc: circuit-breaker-spring-cloud
data:
  # --- build.gradle ---
  build.gradle: |
    plugins {
        id 'org.springframework.boot' version '4.0.0-M1'
        id 'io.spring.dependency-management' version '1.1.7'
        id 'java'
    }

    group = 'com.poc'
    version = '1.0.0'

    java {
        toolchain {
            languageVersion = JavaLanguageVersion.of(17)
        }
    }

    repositories {
        mavenCentral()
        maven { url 'https://repo.spring.io/milestone' }
    }

    ext {
        set('springCloudVersion', '2025.0.0-M1')
    }

    dependencyManagement {
        imports {
            mavenBom "org.springframework.cloud:spring-cloud-dependencies:${springCloudVersion}"
        }
    }

    dependencies {
        // Spring Boot 4 starters
        implementation 'org.springframework.boot:spring-boot-starter-web'
        implementation 'org.springframework.boot:spring-boot-starter-actuator'
        implementation 'org.springframework.boot:spring-boot-starter-aop'

        // Spring Cloud Circuit Breaker (抽象層)
        implementation 'org.springframework.cloud:spring-cloud-starter-circuitbreaker-resilience4j'

        // WebClient for reactive HTTP calls
        implementation 'org.springframework.boot:spring-boot-starter-webflux'
    }

  # --- settings.gradle ---
  settings.gradle: |
    rootProject.name = 'spring-cloud-cb-demo'

  # --- application.yml ---
  application.yml: |
    server:
      port: 8080

    spring:
      application:
        name: circuit-breaker-demo
      cloud:
        circuitbreaker:
          resilience4j:
            enabled: true
            # 啟用 reactive 支援
            enableGroupMeterFilter: true

    management:
      endpoints:
        web:
          exposure:
            include: health,circuitbreakers,circuitbreakerevents,metrics
      endpoint:
        health:
          show-details: always
      health:
        circuitbreakers:
          enabled: true

    resilience4j:
      circuitbreaker:
        configs:
          # 共用預設設定
          shared:
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
          # 更嚴格的設定 (用於關鍵服務)
          strict:
            registerHealthIndicator: true
            slidingWindowType: COUNT_BASED
            slidingWindowSize: 3
            minimumNumberOfCalls: 2
            failureRateThreshold: 40
            waitDurationInOpenState: 30s
            permittedNumberOfCallsInHalfOpenState: 1
            automaticTransitionFromOpenToHalfOpenEnabled: true
        instances:
          downstreamService:
            baseConfig: shared
          criticalService:
            baseConfig: strict

      # TimeLimiter 整合 (超時控制)
      timelimiter:
        configs:
          default:
            timeoutDuration: 2s
            cancelRunningFuture: true
        instances:
          downstreamService:
            baseConfig: default

      # Retry 整合
      retry:
        configs:
          default:
            maxAttempts: 2
            waitDuration: 500ms
            retryExceptions:
              - java.io.IOException
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

  # --- Resilience4jCustomizer.java ---
  Resilience4jCustomizer.java: |
    package com.poc.circuitbreaker;

    import io.github.resilience4j.circuitbreaker.CircuitBreaker;
    import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
    import io.github.resilience4j.circuitbreaker.event.CircuitBreakerOnStateTransitionEvent;
    import jakarta.annotation.PostConstruct;
    import org.slf4j.Logger;
    import org.slf4j.LoggerFactory;
    import org.springframework.cloud.client.circuitbreaker.CircuitBreakerFactory;
    import org.springframework.cloud.circuitbreaker.resilience4j.Resilience4JCircuitBreakerFactory;
    import org.springframework.context.annotation.Bean;
    import org.springframework.context.annotation.Configuration;
    import org.springframework.web.client.RestClient;

    @Configuration
    public class Resilience4jCustomizer {

        private static final Logger log = LoggerFactory.getLogger(Resilience4jCustomizer.class);

        private final CircuitBreakerRegistry circuitBreakerRegistry;

        public Resilience4jCustomizer(CircuitBreakerRegistry circuitBreakerRegistry) {
            this.circuitBreakerRegistry = circuitBreakerRegistry;
        }

        /**
         * Spring Boot 4 推薦使用 RestClient (取代 RestTemplate)
         */
        @Bean
        public RestClient restClient() {
            return RestClient.builder()
                    .baseUrl("http://flaky-service")
                    .build();
        }

        /**
         * 註冊狀態轉換事件監聽器
         */
        @PostConstruct
        public void registerEventListeners() {
            circuitBreakerRegistry.getAllCircuitBreakers().forEach(cb -> {
                cb.getEventPublisher()
                    .onStateTransition(this::logStateTransition)
                    .onError(event -> log.error("CB [{}] Error: {}",
                        event.getCircuitBreakerName(), event.getThrowable().getMessage()))
                    .onSuccess(event -> log.info("CB [{}] Success (duration: {}ms)",
                        event.getCircuitBreakerName(), event.getElapsedDuration().toMillis()));
            });
        }

        private void logStateTransition(CircuitBreakerOnStateTransitionEvent event) {
            log.warn("============================================");
            log.warn("  CB [{}] 狀態轉換: {} → {}",
                event.getCircuitBreakerName(),
                event.getStateTransition().getFromState(),
                event.getStateTransition().getToState());
            log.warn("============================================");
        }
    }

  # --- DownstreamService.java (使用 Spring Cloud CircuitBreaker 抽象) ---
  DownstreamService.java: |
    package com.poc.circuitbreaker;

    import org.slf4j.Logger;
    import org.slf4j.LoggerFactory;
    import org.springframework.cloud.client.circuitbreaker.CircuitBreakerFactory;
    import org.springframework.stereotype.Service;
    import org.springframework.web.client.RestClient;

    /**
     * 使用 Spring Cloud Circuit Breaker 抽象層
     * 
     * 與直接用 Resilience4j 註解的差異:
     * - CircuitBreakerFactory 是 Spring Cloud 的統一抽象
     * - 可以在不改程式碼的情況下切換實作 (Resilience4j / Sentinel / Spring Retry)
     * - 適合多雲或需要靈活切換 CB 實作的企業場景
     */
    @Service
    public class DownstreamService {

        private static final Logger log = LoggerFactory.getLogger(DownstreamService.class);

        private final RestClient restClient;
        private final CircuitBreakerFactory<?, ?> circuitBreakerFactory;

        public DownstreamService(RestClient restClient,
                                 CircuitBreakerFactory<?, ?> circuitBreakerFactory) {
            this.restClient = restClient;
            this.circuitBreakerFactory = circuitBreakerFactory;
        }

        /**
         * 方式 1: Spring Cloud CircuitBreaker 抽象 (推薦)
         * 透過 Factory 取得 CB 實例，執行時自動套用斷路邏輯
         */
        public String callWithSpringCloudCB() {
            log.info(">>> [Spring Cloud CB] Calling downstream...");

            org.springframework.cloud.client.circuitbreaker.CircuitBreaker cb =
                circuitBreakerFactory.create("downstreamService");

            return cb.run(
                // 正常呼叫
                () -> {
                    String response = restClient.get()
                        .uri("/")
                        .retrieve()
                        .body(String.class);
                    log.info(">>> [Spring Cloud CB] Success: {}", response);
                    return response;
                },
                // Fallback
                throwable -> {
                    log.warn(">>> [Spring Cloud CB] FALLBACK! Reason: {}", throwable.getMessage());
                    return "{\"source\":\"SPRING_CLOUD_CB_FALLBACK\","
                         + "\"message\":\"Circuit breaker fallback via Spring Cloud abstraction\","
                         + "\"error\":\"" + throwable.getMessage().replace("\"", "'") + "\"}";
                }
            );
        }

        /**
         * 方式 2: 使用嚴格設定的 Circuit Breaker
         */
        public String callCriticalService() {
            log.info(">>> [Critical CB] Calling critical downstream...");

            org.springframework.cloud.client.circuitbreaker.CircuitBreaker cb =
                circuitBreakerFactory.create("criticalService");

            return cb.run(
                () -> {
                    String response = restClient.get()
                        .uri("/")
                        .retrieve()
                        .body(String.class);
                    log.info(">>> [Critical CB] Success: {}", response);
                    return response;
                },
                throwable -> {
                    log.warn(">>> [Critical CB] FALLBACK! Reason: {}", throwable.getMessage());
                    return "{\"source\":\"CRITICAL_CB_FALLBACK\","
                         + "\"message\":\"Strict circuit breaker fallback\","
                         + "\"error\":\"" + throwable.getMessage().replace("\"", "'") + "\"}";
                }
            );
        }
    }

  # --- ApiController.java ---
  ApiController.java: |
    package com.poc.circuitbreaker;

    import io.github.resilience4j.circuitbreaker.CircuitBreaker;
    import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
    import org.springframework.http.ResponseEntity;
    import org.springframework.web.bind.annotation.GetMapping;
    import org.springframework.web.bind.annotation.PathVariable;
    import org.springframework.web.bind.annotation.RequestMapping;
    import org.springframework.web.bind.annotation.RestController;

    import java.util.LinkedHashMap;
    import java.util.Map;
    import java.util.stream.Collectors;

    @RestController
    @RequestMapping("/api")
    public class ApiController {

        private final DownstreamService downstreamService;
        private final CircuitBreakerRegistry circuitBreakerRegistry;

        public ApiController(DownstreamService downstreamService,
                             CircuitBreakerRegistry circuitBreakerRegistry) {
            this.downstreamService = downstreamService;
            this.circuitBreakerRegistry = circuitBreakerRegistry;
        }

        /**
         * 使用 Spring Cloud Circuit Breaker 呼叫 (一般服務)
         */
        @GetMapping("/call")
        public ResponseEntity<Map<String, Object>> call() {
            String result = downstreamService.callWithSpringCloudCB();
            return ResponseEntity.ok(buildResponse("downstreamService", result));
        }

        /**
         * 使用嚴格設定的 Circuit Breaker 呼叫 (關鍵服務)
         */
        @GetMapping("/call-critical")
        public ResponseEntity<Map<String, Object>> callCritical() {
            String result = downstreamService.callCriticalService();
            return ResponseEntity.ok(buildResponse("criticalService", result));
        }

        /**
         * 查看所有 Circuit Breaker 的即時狀態
         */
        @GetMapping("/dashboard")
        public ResponseEntity<Map<String, Object>> dashboard() {
            Map<String, Object> dashboard = new LinkedHashMap<>();

            circuitBreakerRegistry.getAllCircuitBreakers().forEach(cb -> {
                CircuitBreaker.Metrics m = cb.getMetrics();
                Map<String, Object> info = new LinkedHashMap<>();
                info.put("state", cb.getState().name());
                info.put("failure_rate", m.getFailureRate());
                info.put("slow_call_rate", m.getSlowCallRate());
                info.put("buffered_calls", m.getNumberOfBufferedCalls());
                info.put("failed_calls", m.getNumberOfFailedCalls());
                info.put("successful_calls", m.getNumberOfSuccessfulCalls());
                info.put("not_permitted_calls", m.getNumberOfNotPermittedCalls());

                Map<String, Object> config = new LinkedHashMap<>();
                config.put("sliding_window_size", cb.getCircuitBreakerConfig().getSlidingWindowSize());
                config.put("failure_rate_threshold", cb.getCircuitBreakerConfig().getFailureRateThreshold());
                config.put("wait_in_open_state", cb.getCircuitBreakerConfig().getWaitDurationInOpenState().getSeconds() + "s");
                config.put("half_open_calls", cb.getCircuitBreakerConfig().getPermittedNumberOfCallsInHalfOpenState());
                info.put("config", config);

                dashboard.put(cb.getName(), info);
            });

            return ResponseEntity.ok(dashboard);
        }

        /**
         * 查看特定 Circuit Breaker 狀態
         */
        @GetMapping("/status/{name}")
        public ResponseEntity<Map<String, Object>> status(@PathVariable String name) {
            CircuitBreaker cb = circuitBreakerRegistry.circuitBreaker(name);
            return ResponseEntity.ok(buildResponse(name, null));
        }

        /**
         * 重置特定 Circuit Breaker
         */
        @GetMapping("/reset/{name}")
        public ResponseEntity<Map<String, String>> reset(@PathVariable String name) {
            CircuitBreaker cb = circuitBreakerRegistry.circuitBreaker(name);
            String oldState = cb.getState().name();
            cb.reset();
            return ResponseEntity.ok(Map.of(
                "circuit_breaker", name,
                "old_state", oldState,
                "new_state", cb.getState().name(),
                "action", "reset"
            ));
        }

        /**
         * 重置所有 Circuit Breaker
         */
        @GetMapping("/reset-all")
        public ResponseEntity<Map<String, String>> resetAll() {
            Map<String, String> results = circuitBreakerRegistry.getAllCircuitBreakers()
                .stream()
                .collect(Collectors.toMap(
                    CircuitBreaker::getName,
                    cb -> { cb.reset(); return "RESET -> " + cb.getState().name(); }
                ));
            return ResponseEntity.ok(results);
        }

        // --- Helper ---
        private Map<String, Object> buildResponse(String cbName, String result) {
            CircuitBreaker cb = circuitBreakerRegistry.circuitBreaker(cbName);
            CircuitBreaker.Metrics m = cb.getMetrics();

            Map<String, Object> response = new LinkedHashMap<>();
            response.put("circuit_breaker", cbName);
            response.put("state", cb.getState().name());
            response.put("failure_rate", m.getFailureRate());
            response.put("buffered_calls", m.getNumberOfBufferedCalls());
            response.put("failed_calls", m.getNumberOfFailedCalls());
            response.put("successful_calls", m.getNumberOfSuccessfulCalls());
            response.put("not_permitted_calls", m.getNumberOfNotPermittedCalls());
            if (result != null) {
                response.put("response", result);
            }
            return response;
        }
    }
OUTER

# === Build & Run ===
cat <<'EOF' | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: sccb-build-script
  labels:
    poc: circuit-breaker-spring-cloud
data:
  build-and-run.sh: |
    #!/bin/bash
    set -e

    echo "============================================"
    echo "  Building Spring Boot 4 +"
    echo "  Spring Cloud Circuit Breaker App"
    echo "============================================"

    APP_DIR=/app/project
    SRC_DIR=$APP_DIR/src/main/java/com/poc/circuitbreaker
    RES_DIR=$APP_DIR/src/main/resources

    mkdir -p $SRC_DIR $RES_DIR

    cp /source/build.gradle $APP_DIR/
    cp /source/settings.gradle $APP_DIR/
    cp /source/application.yml $RES_DIR/
    cp /source/CircuitBreakerDemoApplication.java $SRC_DIR/
    cp /source/Resilience4jCustomizer.java $SRC_DIR/
    cp /source/DownstreamService.java $SRC_DIR/
    cp /source/ApiController.java $SRC_DIR/

    cd $APP_DIR

    echo ">>> Running Gradle build (Spring Boot 4 milestone)..."
    gradle bootJar --no-daemon 2>&1 || {
      echo "Build failed, retrying with stacktrace..."
      gradle bootJar --no-daemon --stacktrace
    }

    echo ">>> Starting Spring Boot 4 application..."
    java -jar build/libs/spring-cloud-cb-demo-1.0.0.jar
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sccb-circuit-breaker
  labels:
    poc: circuit-breaker-spring-cloud
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sccb-circuit-breaker
  template:
    metadata:
      labels:
        app: sccb-circuit-breaker
    spec:
      containers:
        - name: app
          image: gradle:8.12-jdk17
          command: ['bash', '/scripts/build-and-run.sh']
          ports:
            - containerPort: 8080
          resources:
            requests:
              memory: 512Mi
              cpu: 500m
            limits:
              memory: 1Gi
              cpu: "1"
          readinessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 90
            periodSeconds: 5
          volumeMounts:
            - name: source
              mountPath: /source
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: source
          configMap:
            name: sccb-source
        - name: scripts
          configMap:
            name: sccb-build-script
            defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: sccb-circuit-breaker
  labels:
    poc: circuit-breaker-spring-cloud
spec:
  selector:
    app: sccb-circuit-breaker
  ports:
    - port: 80
      targetPort: 8080
EOF

echo ""
echo ">>> Spring Cloud CB App 部署中 (首次 Gradle 建置約 3-5 分鐘)..."
echo ">>> 監控建置進度:"
echo "    kubectl logs -l app=sccb-circuit-breaker -n $NAMESPACE -f"
echo ""
echo "============================================"
echo "  驗證 Circuit Breaker"
echo "  (Spring Boot 4 + Spring Cloud CB)"
echo "============================================"
echo ""
echo "  kubectl port-forward svc/sccb-circuit-breaker -n $NAMESPACE 8087:80 &"
echo ""
echo "  # =============================="
echo "  # API 端點"
echo "  # =============================="
echo ""
echo "  # 1. 一般服務呼叫 (downstreamService CB)"
echo "  curl -s http://localhost:8087/api/call | jq ."
echo ""
echo "  # 2. 關鍵服務呼叫 (criticalService CB, 更嚴格設定)"
echo "  curl -s http://localhost:8087/api/call-critical | jq ."
echo ""
echo "  # 3. Dashboard: 所有 Circuit Breaker 狀態"
echo "  curl -s http://localhost:8087/api/dashboard | jq ."
echo ""
echo "  # 4. 單一 CB 狀態"
echo "  curl -s http://localhost:8087/api/status/downstreamService | jq ."
echo ""
echo "  # 5. 重置"
echo "  curl -s http://localhost:8087/api/reset/downstreamService | jq ."
echo "  curl -s http://localhost:8087/api/reset-all | jq ."
echo ""
echo "  # 6. Actuator 端點"
echo "  curl -s http://localhost:8087/actuator/circuitbreakers | jq ."
echo "  curl -s http://localhost:8087/actuator/circuitbreakerevents | jq ."
echo "  curl -s http://localhost:8087/actuator/health | jq ."
echo ""
echo "  # =============================="
echo "  # 壓測: 同時觀察兩個 CB"
echo "  # =============================="
echo ""
echo "  echo '--- 一般 CB (window=5, threshold=50%) ---'"
echo "  for i in \$(seq 1 15); do"
echo "    echo \"Request \$i:\""
echo "    curl -s http://localhost:8087/api/call | jq '{state, failure_rate, response: .response[:60]}'"
echo "    sleep 1"
echo "  done"
echo ""
echo "  echo '--- 嚴格 CB (window=3, threshold=40%) ---'"
echo "  for i in \$(seq 1 15); do"
echo "    echo \"Request \$i:\""
echo "    curl -s http://localhost:8087/api/call-critical | jq '{state, failure_rate, response: .response[:60]}'"
echo "    sleep 1"
echo "  done"
echo ""
echo "  # =============================="
echo "  # 三版比較"
echo "  # =============================="
echo "  #"
echo "  #  7a Python     : 自製狀態機，學習原理"
echo "  #  7b Resilience4j: @CircuitBreaker 註解驅動"
echo "  #  7c Spring Cloud: CircuitBreakerFactory 抽象層"
echo "  #"
echo "  #  7b vs 7c 關鍵差異:"
echo "  #  ┌─────────────────────┬──────────────────────┬──────────────────────────┐"
echo "  #  │                     │ 7b (Resilience4j)    │ 7c (Spring Cloud CB)     │"
echo "  #  ├─────────────────────┼──────────────────────┼──────────────────────────┤"
echo "  #  │ 呼叫方式            │ @CircuitBreaker 註解 │ CircuitBreakerFactory    │"
echo "  #  │ 耦合度              │ 綁定 Resilience4j    │ 可切換實作               │"
echo "  #  │ Fallback            │ fallbackMethod       │ Lambda 函式              │"
echo "  #  │ 多 CB 設定          │ YAML instances       │ YAML + Factory create()  │"
echo "  #  │ HTTP Client         │ RestTemplate         │ RestClient (Boot 4 推薦) │"
echo "  #  │ TimeLimiter/Retry   │ 另外加註解           │ 整合在 Factory 流程      │"
echo "  #  │ 適用場景            │ 單一 CB 實作確定     │ 多雲/需切換 CB 實作      │"
echo "  #  └─────────────────────┴──────────────────────┴──────────────────────────┘"
