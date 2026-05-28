#!/usr/bin/env bash
kubectx chainguard-kubeadm
helm upgrade --install bjorn2scan oci://ghcr.io/bvboe/b2s-go/bjorn2scan \
    --namespace b2sv2 \
    --create-namespace \
    --set scanServer.service.type=LoadBalancer \
    --set clusterName="Chainguard" \
    --set scanServer.config.otelMetrics.enabled=true \
    --set scanServer.config.otelMetrics.endpoint="192.168.2.49:9090" \
    --set scanServer.config.otelMetrics.protocol="http" \
    --set scanServer.config.otelMetrics.pushInterval="15m" \
    --set scanServer.config.otelMetrics.insecure=true
