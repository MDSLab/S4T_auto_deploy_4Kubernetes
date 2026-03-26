.PHONY: help setup setup-skip-k3s setup-skip-helm setup-skip-all clean logs status

help:
	@echo "Stack4Things Automated Deployment"
	@echo "===================================="
	@echo ""
	@echo "Available targets:"
	@echo ""
	@echo "  make setup              - Complete setup (installs k3s, Helm, and Stack4Things)"
	@echo "  make setup-skip-k3s     - Setup with existing k3s"
	@echo "  make setup-skip-helm    - Setup with existing Helm"
	@echo "  make setup-skip-all     - Setup with existing k3s and Helm"
	@echo ""
	@echo "  make status             - Show deployment status"
	@echo "  make logs               - Follow logs from key services"
	@echo "  make clean              - Delete Stack4Things deployment (keep k3s)"
	@echo "  make clean-all          - Uninstall k3s completely"
	@echo ""
	@echo "  make help               - Show this help message"
	@echo ""

setup:
	@echo "Starting complete Stack4Things setup..."
	@bash ./setup-all.sh

setup-skip-k3s:
	@echo "Starting setup with existing k3s..."
	@bash ./setup-all.sh --skip-k3s

setup-skip-helm:
	@echo "Starting setup with existing Helm..."
	@bash ./setup-all.sh --skip-helm

setup-skip-all:
	@echo "Starting setup with existing k3s and Helm..."
	@bash ./setup-all.sh --skip-k3s --skip-helm

status:
	@echo "Stack4Things Deployment Status"
	@echo "==============================="
	@echo ""
	@echo "📊 Stack4Things Pods:"
	@kubectl get pods -n default -L io.kompose.service 2>/dev/null || echo "  k3s not running or KUBECONFIG not set"
	@echo ""
	@echo "📊 Services:"
	@kubectl get svc -n default 2>/dev/null || echo "  Services not available"
	@echo ""
	@echo "📊 LoadBalancer Status:"
	@kubectl get svc -n istio-ingress 2>/dev/null || echo "  Istio ingress not ready"
	@echo ""
	@echo "📊 Node Status:"
	@kubectl get nodes 2>/dev/null || echo "  Nodes not available"
	@echo ""

logs:
	@echo "Following logs from key services..."
	@echo "Press Ctrl+C to stop"
	@kubectl logs -f -n default -l io.kompose.service=iotronic-conductor --tail=50

clean:
	@echo "Deleting Stack4Things deployment..."
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		kubectl delete -f ../stack4things-improved/yaml_file/ 2>/dev/null || true; \
		kubectl delete namespace keycloak keystone 2>/dev/null || true; \
		echo "✓ Stack4Things deployment deleted"; \
		echo "Note: k3s and Kubernetes cluster are still running"; \
	fi

clean-all: clean
	@echo ""
	@echo "Uninstalling k3s..."
	@read -p "Are you sure? This will remove the entire Kubernetes cluster. [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		if [ -f /usr/local/bin/k3s-uninstall.sh ]; then \
			sudo /usr/local/bin/k3s-uninstall.sh; \
		elif [ -f /usr/local/bin/k3s-uninstall-rootless.sh ]; then \
			/usr/local/bin/k3s-uninstall-rootless.sh; \
		else \
			echo "k3s uninstall script not found"; \
		fi; \
		echo "✓ k3s removed"; \
	fi
