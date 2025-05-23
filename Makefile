.SILENT: create-hpa-cluster create-knative-cluster create-monitoring-cluster \
          setup-hpa-environment setup-knative-environment setup-monitoring-environment \
          build-images build-echo build-cpu \
          deploy-echo-hpa deploy-cpu-hpa deploy-echo-knative deploy-cpu-knative \
          teardown

ifndef VERBOSE
  MAKEFLAGS += --no-print-directory
endif

## Monitoring endpoints
PROMETHEUS_URL  ?= http://localhost:9090
JAEGER_URL      ?= http://localhost:16686

## Helpers
define check_other_clusters
  if k3d cluster list | grep -v "$(1)" | grep -q "cluster-"; then \
    echo "❌ Other clusters are active. Please run 'make teardown' first."; \
    exit 1; \
  fi
endef

define ensure_single_cluster
  if k3d cluster list | grep -qw "$(1)"; then \
    echo "✔ $(1) exists — skipping"; \
  else \
    $(call check_other_clusters,$(1)); \
    echo "▶ creating $(1)"; \
    k3d cluster create --config clusters/$(1).yaml; \
  fi
endef

define check_and_build_image
  if [ -z "$$(docker images -q $(1)-service:v1 2>/dev/null)" ]; then \
    echo "▶ Building $(1)-service image (not found)"; \
    docker build -t $(1)-service:v1 --target $(1)-service -f Dockerfile .; \
  else \
    echo "✔ $(1)-service image exists — skipping build"; \
  fi
endef

define check_and_build_registry_image
  if [ -z "$$(docker images -q k3d-registry.localhost:5000/$(1)-service:v1 2>/dev/null)" ]; then \
    echo "▶ Building $(1)-service registry image (not found)"; \
    docker build -t k3d-registry.localhost:5000/$(1)-service:v1 --target $(1)-service -f Dockerfile .; \
    docker push k3d-registry.localhost:5000/$(1)-service:v1; \
  else \
    echo "✔ $(1)-service registry image exists — skipping build"; \
  fi
endef

define install_knative
  @if ! k3d cluster list | grep -qw cluster-$(1); then \
    echo "❌ cluster-$(1) is not running. Please run 'make create-$(1)-cluster' first."; \
    exit 1; \
  fi
  @echo "▶ Installing Knative on cluster-$(1)"
  @if ! kubectl get crd configurations.serving.knative.dev \
       --context k3d-cluster-$(1) >/dev/null 2>&1; then \
    kubectl apply --context k3d-cluster-$(1) \
      -f https://github.com/knative/serving/releases/download/knative-v1.18.0/serving-crds.yaml; \
  fi
  @if ! kubectl get deployment controller \
       -n knative-serving \
       --context k3d-cluster-$(1) >/dev/null 2>&1; then \
    kubectl apply --context k3d-cluster-$(1) \
      -f https://github.com/knative/serving/releases/download/knative-v1.18.0/serving-core.yaml; \
  fi
  @echo "✔ Knative core ready in cluster-$(1)"
  @echo "▶ Installing Kourier on cluster-$(1)"
  @if ! kubectl get ns kourier-system \
       --context k3d-cluster-$(1) >/dev/null 2>&1; then \
    kubectl apply --context k3d-cluster-$(1) \
      -f https://github.com/knative/net-kourier/releases/latest/download/kourier.yaml; \
  fi
  @if kubectl get ns knative-serving \
       --context k3d-cluster-$(1) >/dev/null 2>&1; then \
    cls=$$(kubectl get cm config-network \
                  -n knative-serving \
                  --context k3d-cluster-$(1) \
                  -o jsonpath='{.data.ingress\.class}'); \
    if [ "$$cls" != "kourier.ingress.networking.knative.dev" ]; then \
        kubectl patch cm config-network \
          -n knative-serving \
          --context k3d-cluster-$(1) \
          --type merge \
          --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'; \
    fi; \
  fi
  @echo "✔ Kourier ready in cluster-$(1)"
  @if [ "$(1)" = "knative" ]; then \
    echo "▶ Configuring registry for Knative"; \
    kubectl patch configmap/config-deployment \
      --namespace knative-serving \
      --context k3d-cluster-$(1) \
      --type merge \
      --patch '{"data":{"registriesSkippingTagResolving":"k3d-registry.localhost:5000"}}' 2>/dev/null || true; \
    kubectl apply -f kubernetes/config-domain.yaml --context k3d-cluster-$(1); \
    echo "▶ Waiting for Knative webhook to be ready..."; \
    kubectl wait --for=condition=available deployment/webhook -n knative-serving --context k3d-cluster-$(1) --timeout=120s; \
    echo "✔ Knative registry configured"; \
  fi
endef

define setup_remote_monitoring
  @if ! k3d cluster list | grep -qw cluster-$(1); then \
    echo "❌ cluster-$(1) is not running. Please run 'make create-$(1)-cluster' first."; \
    exit 1; \
  fi
  @kubectl apply -f kubernetes/service-config.yaml
  @echo "▶ Installing Prometheus agent on cluster-$(1)"
  @kubectl config use-context k3d-cluster-$(1)
  @helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  @helm repo update
  @helm upgrade --install prom-agent prometheus-community/prometheus \
    --namespace monitoring \
    --create-namespace \
    --set server.persistentVolume.enabled=false \
    --set alertmanager.enabled=false \
    --values monitoring/values-remote-write.yaml
  @kubectl -n monitoring rollout status deployment/prom-agent-prometheus-server
  @echo "✔ Prometheus agent installed on cluster-$(1)"
  @kubectl apply -f monitoring/kourier-tracing-config.yaml
  @kubectl apply -f monitoring/knative-tracing-config.yaml
  @kubectl -n kourier-system rollout restart deployment 3scale-kourier-gateway
  @echo "✔ Zipkin traces set up on cluster-$(1)"
endef

define deploy_service
  if ! k3d cluster list | grep -qw "cluster-$(1)"; then \
    echo "❌ cluster-$(1) is not running. Please run 'make setup-$(1)-environment' first."; \
    exit 1; \
  fi; \
  echo "▶ Deploying $(2)-service to cluster-$(1)..."; \
  kubectl config use-context k3d-cluster-$(1); \
  kubectl delete deployments,services,horizontalpodautoscalers -l app!=monitoring --ignore-not-found=true; \
  if [ "$(1)" = "knative" ]; then \
    kubectl delete ksvc --all --ignore-not-found=true; \
    kubectl apply -f kubernetes/knative/$(2)-service.yaml; \
  else \
    kubectl apply -f kubernetes/hpa/$(2)-service.yaml; \
  fi; \
  echo "✔ $(2)-service deployed on cluster-$(1)"
endef

define get_jaeger_service_name
$(if $(filter echo%, $(1)),echoService,$(if $(filter cpu%, $(1)),cpuService,$(if $(filter io%, $(1)),ioService,$(1))))
endef


define export_prometheus_metrics
  @echo "▶ Exporting Prometheus metrics for $(1) test..."
  @mkdir -p $(RESULT_DIR)/prometheus
  @if [ -z "$(2)" ]; then \
    echo "❌ Duration not specified"; \
    exit 1; \
  fi; \
  echo "▶ Calculating timestamps for $(2) minutes ago..."; \
  test_start_epoch=$$(date -d "$(2) minutes ago" +%s 2>/dev/null || date -v-$(2)M +%s); \
  test_end_epoch=$$(date +%s); \
  echo "▶ Epochs: start=$${test_start_epoch}, end=$${test_end_epoch}"; \
  test_start=$$(date -u -d "@$${test_start_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $${test_start_epoch} +%Y-%m-%dT%H:%M:%SZ); \
  test_end=$$(date -u -d "@$${test_end_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $${test_end_epoch} +%Y-%m-%dT%H:%M:%SZ); \
  timestamp=$$(date +%Y%m%d_%H%M%S); \
  echo "▶ Querying metrics from $${test_start} to $${test_end}"; \
  if [ -z "$${test_start}" ] || [ -z "$${test_end}" ]; then \
    echo "❌ Timestamp calculation failed"; \
    exit 1; \
  fi; \
  \
  echo "▶ Fetching HTTP request rate..."; \
  curl -s -G "$(PROMETHEUS_URL)/api/v1/query_range" \
    --data-urlencode "query=rate(http_requests_total[1m])" \
    --data-urlencode "start=$${test_start}" \
    --data-urlencode "end=$${test_end}" \
    --data-urlencode "step=15s" \
    | jq '.' > $(RESULT_DIR)/prometheus/$(1)_http_requests_$${timestamp}.json 2>/dev/null || echo "⚠ HTTP requests query failed"; \
  \
  echo "▶ Fetching response time P95..."; \
  curl -s -G "$(PROMETHEUS_URL)/api/v1/query_range" \
    --data-urlencode "query=histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[1m]))" \
    --data-urlencode "start=$${test_start}" \
    --data-urlencode "end=$${test_end}" \
    --data-urlencode "step=15s" \
    | jq '.' > $(RESULT_DIR)/prometheus/$(1)_response_time_p95_$${timestamp}.json 2>/dev/null || echo "⚠ Response time query failed"; \
  \
  echo "▶ Fetching CPU usage..."; \
  curl -s -G "$(PROMETHEUS_URL)/api/v1/query_range" \
    --data-urlencode "query=rate(container_cpu_usage_seconds_total[1m])" \
    --data-urlencode "start=$${test_start}" \
    --data-urlencode "end=$${test_end}" \
    --data-urlencode "step=15s" \
    | jq '.' > $(RESULT_DIR)/prometheus/$(1)_cpu_usage_$${timestamp}.json 2>/dev/null || echo "⚠ CPU usage query failed"; \
  \
  echo "▶ Fetching memory usage..."; \
  curl -s -G "$(PROMETHEUS_URL)/api/v1/query_range" \
    --data-urlencode "query=container_memory_working_set_bytes" \
    --data-urlencode "start=$${test_start}" \
    --data-urlencode "end=$${test_end}" \
    --data-urlencode "step=15s" \
    | jq '.' > $(RESULT_DIR)/prometheus/$(1)_memory_usage_$${timestamp}.json 2>/dev/null || echo "⚠ Memory usage query failed"; \
  \
  echo "▶ Fetching pod count..."; \
  curl -s -G "$(PROMETHEUS_URL)/api/v1/query_range" \
    --data-urlencode "query=kube_pod_info" \
    --data-urlencode "start=$${test_start}" \
    --data-urlencode "end=$${test_end}" \
    --data-urlencode "step=15s" \
    | jq '.' > $(RESULT_DIR)/prometheus/$(1)_pod_count_$${timestamp}.json 2>/dev/null || echo "⚠ Pod count query failed"; \
  \
  echo "✔ Prometheus metrics exported to $(RESULT_DIR)/prometheus/"
endef

define export_jaeger_traces
  @echo "▶ Exporting Jaeger traces for $(1) test..."
  @mkdir -p $(RESULT_DIR)/jaeger
  @if [ -z "$(2)" ]; then \
    echo "❌ Duration not specified"; \
    exit 1; \
  fi; \
  echo "▶ Calculating timestamps for $(2) minutes ago..."; \
  test_start_epoch=$$(date -d "$(2) minutes ago" +%s 2>/dev/null || date -v-$(2)M +%s); \
  test_end_epoch=$$(date +%s); \
  echo "▶ Epochs: start=$${test_start_epoch}, end=$${test_end_epoch}"; \
  test_start_us=$$(echo "$${test_start_epoch} * 1000000" | bc 2>/dev/null || echo "$${test_start_epoch}000000"); \
  test_end_us=$$(echo "$${test_end_epoch} * 1000000" | bc 2>/dev/null || echo "$${test_end_epoch}000000"); \
  timestamp=$$(date +%Y%m%d_%H%M%S); \
  echo "▶ Querying traces from $$(date -d "@$${test_start_epoch}" 2>/dev/null || date -r $${test_start_epoch}) to $$(date -d "@$${test_end_epoch}" 2>/dev/null || date -r $${test_end_epoch})"; \
  \
  jaeger_service_name="$$(echo "$(call get_jaeger_service_name,$(1))")"; \
  echo "▶ Using Jaeger service name: $${jaeger_service_name}"; \
  \
  echo "▶ First checking if service exists..."; \
  available_services=$$(curl -s "$(JAEGER_URL)/api/services" | jq -r '.data[]'); \
  echo "Available services: $${available_services}"; \
  \
  if echo "$${available_services}" | grep -q "$${jaeger_service_name}"; then \
    echo "✓ Service $${jaeger_service_name} found"; \
    service_to_use="$${jaeger_service_name}"; \
  else \
    echo "❌ Service $${jaeger_service_name} not found, trying alternatives..."; \
    service_to_use=$$(echo "$${available_services}" | grep -i "$(1)" | head -1); \
    if [ -n "$${service_to_use}" ]; then \
      echo "✓ Using alternative service: $${service_to_use}"; \
    else \
      echo "❌ No matching service found for $(1)"; \
      echo "Available services:"; \
      echo "$${available_services}" | head -5; \
      echo "Skipping trace export..."; \
      return 0; \
    fi; \
  fi; \
  \
  echo "▶ Fetching traces for service: $${service_to_use}"; \
  curl -s "$(JAEGER_URL)/api/traces?service=$${service_to_use}&start=$${test_start_us}&end=$${test_end_us}&limit=10" \
    | jq '.' > $(RESULT_DIR)/jaeger/$(1)_traces_$${timestamp}.json 2>/dev/null || echo "⚠ Traces query failed"; \
  \
  echo "▶ Fetching operations for service: $${service_to_use}"; \
  curl -s "$(JAEGER_URL)/api/services/$${service_to_use}/operations" \
    | jq '.' > $(RESULT_DIR)/jaeger/$(1)_operations_$${timestamp}.json 2>/dev/null || echo "⚠ Operations query failed"; \
  \
  echo "✔ Jaeger traces exported to $(RESULT_DIR)/jaeger/"
endef

define export_monitoring_data
  echo "▶ Exporting monitoring data for $(1) test..."
  @$(MAKE) export-prometheus SERVICE=$(1) DURATION=$(2)
  @$(MAKE) export-jaeger SERVICE=$(1) DURATION=$(2)
  @echo "✔ All monitoring data exported for $(1)"
endef

define run_test_with_export
  @echo "▶ Starting $(1) test with monitoring export..."; \
  start_time=$$(date +%s); \
  echo "▶ Running test: $(2)"; \
  $(MAKE) $(2) $(3); \
  end_time=$$(date +%s); \
  duration_minutes=$$((($${end_time} - $${start_time}) / 60 + 1)); \
  echo "▶ Test completed in $${duration_minutes} minutes, exporting monitoring data..."; \
  $(MAKE) export-all-monitoring SERVICE=$(4) DURATION=$${duration_minutes}
endef

## 1. Individual Cluster Creation (enforcing single cluster)
create-hpa-cluster:
	$(call ensure_single_cluster,cluster-hpa)

create-knative-cluster:
	$(call ensure_single_cluster,cluster-knative)

create-monitoring-cluster:
	$(call ensure_single_cluster,cluster-monitoring)

## 2. Environment Setup
setup-hpa-environment: 
	$(call check_other_clusters,cluster-hpa)
	$(call ensure_single_cluster,cluster-hpa)
	$(call install_knative,hpa)
	$(call setup_remote_monitoring,hpa)
	@echo "✔ HPA test environment is ready"

setup-knative-environment:
	$(call check_other_clusters,cluster-knative)
	$(call ensure_single_cluster,cluster-knative)
	$(call install_knative,knative)
	$(call setup_remote_monitoring,knative)
	@echo "✔ Knative test environment is ready"

setup-monitoring-environment:
	$(call check_other_clusters,cluster-monitoring)
	$(call ensure_single_cluster,cluster-monitoring)
	@echo "▶ Installing monitoring stack on cluster-monitoring"
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	@helm repo update
	@helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
	  --version 72.3.1 \
	  --values monitoring/helm-values/prom-values.yaml  \
	  --namespace monitoring \
	  --create-namespace || echo "✔ Prometheus stack already installed"
	@helm repo add jaegertracing https://jaegertracing.github.io/helm-charts 2>/dev/null || true
	@helm repo update
	@helm upgrade --install jaeger jaegertracing/jaeger \
	  --namespace monitoring \
	  --values monitoring/helm-values/jaeger-values.yaml || echo "✔ Jaeger already installed"
	@kubectl apply -f monitoring/dashboards/
	@echo "✔ Monitoring environment ready"

## 3. Image Building
build-images: build-echo build-cpu build-io

build-echo:
	docker build -t echo-service:v1 --target echo-service -f Dockerfile .
	docker build -t k3d-registry.localhost:5000/echo-service:v1 --target echo-service -f Dockerfile .
	@echo "✔ echo-service images built"

build-cpu:
	docker build -t cpu-service:v1 --target cpu-service -f Dockerfile .
	docker build -t k3d-registry.localhost:5000/cpu-service:v1 --target cpu-service -f Dockerfile .
	@echo "✔ cpu-service images built"

build-io:
	docker build -t io-service:v1 --target io-service -f Dockerfile .
	docker build -t k3d-registry.localhost:5000/io-service:v1 --target io-service -f Dockerfile .
	@echo "✔ io-service images built"

## 4. Service Deployments
deploy-echo-hpa:
	$(call check_and_build_image,echo)
	@k3d image import echo-service:v1 --cluster cluster-hpa 2>/dev/null || true
	$(call deploy_service,hpa,echo)

deploy-cpu-hpa:
	$(call check_and_build_image,cpu)
	@k3d image import cpu-service:v1 --cluster cluster-hpa 2>/dev/null || true
	$(call deploy_service,hpa,cpu)

deploy-io-hpa:
	$(call check_and_build_image,io)
	@k3d image import io-service:v1 --cluster cluster-hpa 2>/dev/null || true
	$(call deploy_service,hpa,io)

deploy-echo-knative:
	$(call check_and_build_registry_image,echo)
	@if ! k3d cluster list | grep -qw cluster-knative; then \
	  echo "❌ cluster-knative is not running. Please run 'make setup-knative-environment' first."; \
	  exit 1; \
	fi
	@docker push k3d-registry.localhost:5000/echo-service:v1
	@kubectl config use-context k3d-cluster-knative
	@kubectl create secret docker-registry k3d-registry-credentials \
	  --docker-server=registry.localhost:5000 \
	  --docker-username=k3d \
	  --docker-password=registry \
	  --dry-run=client -o yaml | kubectl apply -f -
	@kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "k3d-registry-credentials"}]}'
	$(call deploy_service,knative,echo)

deploy-cpu-knative:
	$(call check_and_build_registry_image,cpu)
	@if ! k3d cluster list | grep -qw cluster-knative; then \
	  echo "❌ cluster-knative is not running. Please run 'make setup-knative-environment' first."; \
	  exit 1; \
	fi
	@docker push k3d-registry.localhost:5000/cpu-service:v1
	@kubectl config use-context k3d-cluster-knative
	@kubectl create secret docker-registry k3d-registry-credentials \
	  --docker-server=registry.localhost:5000 \
	  --docker-username=k3d \
	  --docker-password=registry \
	  --dry-run=client -o yaml | kubectl apply -f -
	@kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "k3d-registry-credentials"}]}'
	$(call deploy_service,knative,cpu)

deploy-io-knative:
	$(call check_and_build_registry_image,io)
	@if ! k3d cluster list | grep -qw cluster-knative; then \
	  echo "❌ cluster-knative is not running. Please run 'make setup-knative-environment' first."; \
	  exit 1; \
	fi
	@docker push k3d-registry.localhost:5000/io-service:v1
	@kubectl config use-context k3d-cluster-knative
	@kubectl create secret docker-registry k3d-registry-credentials \
	  --docker-server=registry.localhost:5000 \
	  --docker-username=k3d \
	  --docker-password=registry \
	  --dry-run=client -o yaml | kubectl apply -f -
	@kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "k3d-registry-credentials"}]}'
	$(call deploy_service,knative,io)

## 6. One-step deployment targets
setup-hpa-echo: setup-hpa-environment
	@$(MAKE) deploy-echo-hpa
	@echo "✔ Echo service HPA test environment ready"

setup-hpa-cpu: setup-hpa-environment
	@$(MAKE) deploy-cpu-hpa
	@echo "✔ CPU service HPA test environment ready"

setup-hpa-io: setup-hpa-environment
	@$(MAKE) deploy-io-hpa
	@echo "✔ IO service HPA test environment ready"

setup-knative-echo: setup-knative-environment
	@$(MAKE) deploy-echo-knative
	@echo "✔ Echo service Knative test environment ready"

setup-knative-cpu: setup-knative-environment
	@$(MAKE) deploy-cpu-knative
	@echo "✔ CPU service Knative test environment ready"

setup-knative-io: setup-knative-environment
	@$(MAKE) deploy-io-knative
	@echo "✔ IO service Knative test environment ready"

## 7. K6 tests
BASE_URL        ?= http://192.168.100.103:8080

RESULT_DIR      ?= monitoring/k6/results
SUMMARY_STATS   ?= "avg,min,med,max,p(50),p(95),p(99),p(99.99)"

ECHO_HOST       ?= echo-service.default.example.com
ECHO_ENDPOINT   ?= $(BASE_URL)/echo
ECHO_BODY       ?= {"message":"hello"}

CPU_HOST        ?= cpu-service.default.example.com
CPU_ENDPOINT    ?= $(BASE_URL)/fibonacci
CPU_N           ?= 20
CPU_BODY        ?= {"n":$(CPU_N)}

IO_HOST         ?= io-service.default.example.com
IO_ENDPOINT     ?= $(BASE_URL)/simulate-io
IO_BODY         ?= {"operations":5,"pattern":"sequential","variability":0,"failureRate":0}

test-constant:
	@mkdir -p $(RESULT_DIR)
	@echo "→ Running constant load test..."
	ENDPOINT=$(ENDPOINT) BODY='$(BODY)' HOST=$(HOST) RATE=$(RATE) DURATION=$(DURATION) \
	  k6 run \
	  --summary-trend-stats=$(SUMMARY_STATS) \
	  --summary-export=$(RESULT_DIR)/constant_summary.json \
	  ./monitoring/k6/tests/constant-load.js

test-ramp:
	@mkdir -p $(RESULT_DIR)
	@echo "→ Running ramping load test..."
	ENDPOINT=$(ENDPOINT) BODY='$(BODY)' HOST=$(HOST) MAX_RATE=$(MAX_RATE) DURATION=$(RAMP_TIME) \
	  k6 run \
	  --summary-trend-stats=$(SUMMARY_STATS) \
	  --summary-export=$(RESULT_DIR)/ramp_summary.json \
	  ./monitoring/k6/tests/ramping-load.js

test-spike:
	@mkdir -p $(RESULT_DIR)
	@echo "→ Running periodic load test..."
	ENDPOINT=$(ENDPOINT) BODY='$(BODY)' HOST=$(HOST) PEAK_RATE=$(PEAK_RATE) PERIOD=$(PERIOD) \
	  k6 run \
	  --summary-trend-stats=$(SUMMARY_STATS) \
	  --summary-export=$(RESULT_DIR)/spike_summary.json \
	  ./monitoring/k6/tests/periodic-load.js

test-constant-echo:
	$(call run_test_with_export,constant-echo,test-constant,HOST=$(ECHO_HOST) ENDPOINT=$(ECHO_ENDPOINT) BODY='$(ECHO_BODY)',echo)

test-constant-cpu:
	$(call run_test_with_export,constant-cpu,test-constant,HOST=$(CPU_HOST) ENDPOINT=$(CPU_ENDPOINT) BODY='$(CPU_BODY)',cpu)

test-constant-io:
	$(call run_test_with_export,constant-io,test-constant,HOST=$(IO_HOST) ENDPOINT=$(IO_ENDPOINT) BODY='$(IO_BODY)',io)

test-ramp-echo:
	$(call run_test_with_export,ramp-echo,test-ramp,HOST=$(ECHO_HOST) ENDPOINT=$(ECHO_ENDPOINT) BODY='$(ECHO_BODY)',echo)

test-ramp-cpu:
	$(call run_test_with_export,ramp-cpu,test-ramp,HOST=$(CPU_HOST) ENDPOINT=$(CPU_ENDPOINT) BODY='$(CPU_BODY)',cpu)

test-ramp-io:
	$(call run_test_with_export,ramp-io,test-ramp,HOST=$(IO_HOST) ENDPOINT=$(IO_ENDPOINT) BODY='$(IO_BODY)',io)

test-spike-echo:
	$(call run_test_with_export,spike-echo,test-spike,HOST=$(ECHO_HOST) ENDPOINT=$(ECHO_ENDPOINT) BODY='$(ECHO_BODY)',echo)

test-spike-cpu:
	$(call run_test_with_export,spike-cpu,test-spike,HOST=$(CPU_HOST) ENDPOINT=$(CPU_ENDPOINT) BODY='$(CPU_BODY)',cpu)

test-spike-io:
	$(call run_test_with_export,spike-io,test-spike,HOST=$(IO_HOST) ENDPOINT=$(IO_ENDPOINT) BODY='$(IO_BODY)',io)

## Manual export targets
export-prometheus:
	$(call export_prometheus_metrics,$(SERVICE),$(DURATION))

export-jaeger:
	$(call export_jaeger_traces,$(SERVICE),$(DURATION))

export-all-monitoring:
	$(call export_monitoring_data,$(SERVICE),$(DURATION))

## 8. Cleanup
teardown:
	-k3d cluster delete --all && echo "✔ All clusters deleted"
