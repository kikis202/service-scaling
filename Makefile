# scripts/Makefile

.SILENT: create-hpa create-knative create-hybrid create-monitoring \
          install-knative install-kourier install-monitoring \
          deploy-hpa deploy-knative deploy-hybrid deploy-monitoring deploy-all teardown

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

create-hybrid:
	$(call ensure_cluster,cluster-hybrid)

create-monitoring:
	$(call ensure_cluster,cluster-monitoring)

## 2. Knative Serving on knative + hybrid
install-knative:
	@for ctx in knative hybrid; do \
	  if k3d cluster list | grep -qw cluster-$${ctx}; then \
	    echo "▶ Knative on cluster-$${ctx}"; \
	    if ! kubectl get crd configurations.serving.knative.dev \
	           --context k3d-cluster-$${ctx} >/dev/null 2>&1; then \
	      kubectl apply --context k3d-cluster-$${ctx} \
	        -f https://github.com/knative/serving/releases/download/knative-v1.18.0/serving-crds.yaml; \
	    fi; \
	    if ! kubectl get deployment controller \
	           -n knative-serving \
	           --context k3d-cluster-$${ctx} >/dev/null 2>&1; then \
	      kubectl apply --context k3d-cluster-$${ctx} \
	        -f https://github.com/knative/serving/releases/download/knative-v1.18.0/serving-core.yaml; \
	    fi; \
	    echo "✔ Knative ready in cluster-$${ctx}"; \
	  fi; \
	done

## 3. Kourier ingress on all testing clusters
install-kourier:
	@for ctx in hpa knative hybrid; do \
	  if k3d cluster list | grep -qw cluster-$${ctx}; then \
	    echo "▶ Kourier on cluster-$${ctx}"; \
	    if ! kubectl get ns kourier-system --context k3d-cluster-$${ctx} >/dev/null 2>&1; then \
	      kubectl apply --context k3d-cluster-$${ctx} \
	        -f https://github.com/knative/net-kourier/releases/latest/download/kourier.yaml; \
	    fi; \
	    if kubectl get ns knative-serving --context k3d-cluster-$${ctx} >/dev/null 2>&1; then \
	      cls=$$(kubectl get cm config-network -n knative-serving \
	                --context k3d-cluster-$${ctx} \
	                -o jsonpath='{.data.ingress\.class}'); \
	      if [ "$$cls" != "kourier.ingress.networking.knative.dev" ]; then \
	        kubectl patch cm config-network -n knative-serving \
	          --context k3d-cluster-$${ctx} \
	          --type merge \
	          --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'; \
	      fi; \
	    fi; \
	    echo "✔ Kourier ready in cluster-$${ctx}"; \
	  fi; \
	done

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

## 5. Enforce exclusive testing clusters, then deploy
deploy-hpa:
	@if k3d cluster list | grep -E 'cluster-(knative|hybrid)' >/dev/null; then \
	  echo "✖ Another testing cluster is active — please teardown first"; exit 1; \
	fi
	$(MAKE) create-hpa
	$(MAKE) install-kourier
	@echo "✔ deploy-hpa complete — cluster-hpa is ready"

deploy-knative:
	@if k3d cluster list | grep -E 'cluster-(hpa|hybrid)' >/dev/null; then \
	  echo "✖ Another testing cluster is active — please teardown first"; exit 1; \
	fi
	$(MAKE) create-knative
	$(MAKE) install-knative
	$(MAKE) install-kourier
	@echo "✔ deploy-knative complete — cluster-knative is ready"

deploy-hybrid:
	@if k3d cluster list | grep -E 'cluster-(hpa|knative)' >/dev/null; then \
	  echo "✖ Another testing cluster is active — please teardown first"; exit 1; \
	fi
	$(MAKE) create-hybrid
	$(MAKE) install-knative
	$(MAKE) install-kourier
	@echo "✔ deploy-hybrid complete — cluster-hybrid is ready"

deploy-monitoring:
	$(MAKE) create-monitoring
	$(MAKE) install-monitoring
	@echo "✔ deploy-monitoring complete — cluster-monitoring is ready"

## 6. Tear everything down
teardown:
	-k3d cluster delete --all && echo "✔ all clusters deleted"
