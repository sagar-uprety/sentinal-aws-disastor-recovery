apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.${namespace}:9090
    isDefault: true
    editable: false
