.SILENT: create-hpa-cluster create-knative-cluster create-monitoring-cluster \
          setup-hpa-environment setup-knative-environment setup-monitoring-environment \
          build-images build-echo build-cpu \
          deploy-echo-hpa deploy-cpu-hpa deploy-echo-knative deploy-cpu-knative \
          teardown

ifndef VERBOSE
  MAKEFLAGS += --no-print-directory
endif

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

## 7. Cleanup
teardown:
	-k3d cluster delete --all && echo "✔ All clusters deleted"
