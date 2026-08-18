#!/usr/bin/env bash
kubectx chainguard-kubeadm
helm upgrade --install bjorn2scan oci://ghcr.io/bvboe/bjorn2scan/bjorn2scan \
    --namespace bjorn2scan \
    --create-namespace \
    --set scanServer.service.type=LoadBalancer \
    --set clusterName="Chainguard-Kubeadm" \
    --set updateController.schedule="@hourly" \
    --set scanServer.config.otelMetrics.enabled=true \
    --set scanServer.config.otelMetrics.endpoint="192.168.2.49:9090" \
    --set scanServer.config.otelMetrics.protocol="http" \
    --set scanServer.config.otelMetrics.pushInterval="15m" \
    --set scanServer.config.otelMetrics.insecure=true
