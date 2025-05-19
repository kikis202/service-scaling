# scripts/Makefile

.SILENT: create-hpa create-knative create-monitoring \
          install-knative install-monitoring \
          deploy-hpa deploy-knative deploy-monitoring deploy-all teardown

ifndef VERBOSE
  MAKEFLAGS += --no-print-directory
endif

## Helpers
define ensure_cluster
  if k3d cluster list | grep -qw $(1); then \
    echo "✔ $(1) exists — skipping"; \
  else \
    echo "▶ creating $(1)"; \
    k3d cluster create --config clusters/$(1).yaml; \
  fi
endef

## 1. Cluster Creation
create-hpa:
	$(call ensure_cluster,cluster-hpa)

create-knative:
	$(call ensure_cluster,cluster-knative)

create-monitoring:
	$(call ensure_cluster,cluster-monitoring)


## 2. Knative Serving and Kourier on knative + hpa
install-knative:
	@for ctx in hpa knative; do \
	  if k3d cluster list | grep -qw cluster-$$ctx; then \
	    echo "▶ Knative on cluster-$$ctx"; \
	    if ! kubectl get crd configurations.serving.knative.dev \
	         --context k3d-cluster-$$ctx >/dev/null 2>&1; then \
	      kubectl apply --context k3d-cluster-$$ctx \
	        -f https://github.com/knative/serving/releases/download/knative-v1.18.0/serving-crds.yaml; \
	    fi; \
	    if ! kubectl get deployment controller \
	         -n knative-serving \
	         --context k3d-cluster-$$ctx >/dev/null 2>&1; then \
	      kubectl apply --context k3d-cluster-$$ctx \
	        -f https://github.com/knative/serving/releases/download/knative-v1.18.0/serving-core.yaml; \
	    fi; \
	    echo "✔ Knative ready in cluster-$$ctx"; \
	    echo "▶ Kourier on cluster-$$ctx"; \
	    if ! kubectl get ns kourier-system \
	         --context k3d-cluster-$$ctx >/dev/null 2>&1; then \
	      kubectl apply --context k3d-cluster-$$ctx \
	        -f https://github.com/knative/net-kourier/releases/latest/download/kourier.yaml; \
	    fi; \
	    if kubectl get ns knative-serving \
	         --context k3d-cluster-$$ctx >/dev/null 2>&1; then \
	      cls=$$(kubectl get cm config-network \
	                    -n knative-serving \
	                    --context k3d-cluster-$$ctx \
	                    -o jsonpath='{.data.ingress\.class}'); \
	      if [ "$$cls" != "kourier.ingress.networking.knative.dev" ]; then \
	          kubectl patch cm config-network \
	            -n knative-serving \
	            --context k3d-cluster-$$ctx \
	            --type merge \
	            --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'; \
	      fi; \
	    fi; \
	    echo "✔ Kourier ready in cluster-$$ctx"; \
	  fi; \
	done

install-hpa:
	@echo "▶ hpa deployments"
	@docker build -t echo-service:v1 -f Dockerfile .
	@k3d image import echo-service:v1 --cluster cluster-hpa
	@kubectl config use-context k3d-cluster-hpa
	@kubectl apply -f kubernetes/hpa/echo-service.yaml

install-knative-deployments:
	@echo "▶ Deploying echo-service on Knative"
	@kubectl patch configmap/config-deployment \
	  --namespace knative-serving \
	  --type merge \
	  --patch '{"data":{"registriesSkippingTagResolving":"k3d-registry.localhost:5000"}}'
	@kubectl apply -f kubernetes/config-domain.yaml
	@echo "▶ Waiting for Knative webhook to be ready..."
	@kubectl wait --for=condition=available deployment/webhook -n knative-serving --timeout=120s
	@docker build -t k3d-registry.localhost:5000/echo-service:v1 .
	@docker push k3d-registry.localhost:5000/echo-service:v1
	@kubectl config use-context k3d-cluster-knative
	@kubectl create secret docker-registry k3d-registry-credentials \
	  --docker-server=registry.localhost:5000 \
	  --docker-username=k3d \
	  --docker-password=registry
	@kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "k3d-registry-credentials"}]}'
	@kubectl apply -f kubernetes/knative/echo-service.yaml
	@echo "✔ echo-service deployed on Knative"

install-monitoring:
	@echo "▶ monitoring stack on cluster-monitoring"
	@kubectl create namespace monitoring --dry-run=client -o yaml \
	  | kubectl apply -f -

	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	@helm repo update
	@helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
	  --version 72.3.1 \
	  --values monitoring/helm-values/prom-values.yaml  \
	  --namespace monitoring \
	  --create-namespace || echo "✔ Prometheus stack already installed"

	@helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
	@helm repo update
	@helm upgrade --install jaeger jaegertracing/jaeger \
	  --namespace monitoring \
	  --values monitoring/helm-values/jaeger-values.yaml || echo "✔ Jaeger already installed"
	@echo "✔ monitoring ready"

install-remote-monitoring:
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	@helm repo update
	@helm upgrade --install prom-agent prometheus-community/prometheus \
	  --namespace monitoring \
	  --create-namespace \
	  --set server.persistentVolume.enabled=false \
	  --set alertmanager.enabled=false \
	  --values monitoring/values-remote-write.yaml
	@kubectl -n monitoring rollout status deployment/prom-agent-prometheus-server
	@echo "✅ Prometheus agent installed with remote write configured"

apply-dashboards:
	@echo "▶ Applying Grafana dashboards"
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f monitoring/dashboards/
	@echo "✔ Dashboards applied"

## 5. Enforce exclusive testing clusters, then deploy
deploy-hpa:
	@if k3d cluster list | grep -E 'cluster-knative' >/dev/null; then \
	  echo "✖ Another testing cluster is active — please teardown first"; exit 1; \
	fi
	$(MAKE) create-hpa
	$(MAKE) install-knative
	$(MAKE) install-hpa
	$(MAKE) install-remote-monitoring
	@echo "✔ deploy-hpa complete — cluster-hpa is ready"

deploy-knative:
	@if k3d cluster list | grep -E 'cluster-hpa' >/dev/null; then \
	  echo "✖ Another testing cluster is active — please teardown first"; exit 1; \
	fi
	$(MAKE) create-knative
	$(MAKE) install-knative
	$(MAKE) install-knative-deployments
	$(MAKE) install-remote-monitoring
	@echo "✔ deploy-knative complete — cluster-knative is ready"

deploy-monitoring:
	$(MAKE) create-monitoring
	$(MAKE) install-monitoring
	$(MAKE) apply-dashboards
	@echo "✔ deploy-monitoring complete — cluster-monitoring is ready"

## 6. Tear everything down
teardown:
	-k3d cluster delete --all && echo "✔ all clusters deleted"

teardown-hpa:
	-k3d cluster delete --all && echo "✔ all clusters deleted"
