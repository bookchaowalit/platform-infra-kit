  - name: __APP_NAME__
    namespace: apps-__APP_NAME__
    team: __TEAM__
    component: __COMPONENT__
    mode: __MODE__
    image:
      repository: k3d-solo-registry:5000/__IMAGE_NAME__
      tag: "git-pending"
    replicas: 1
    resources:
      requests:
        cpu: __CPU_REQUEST__
        memory: __MEMORY_REQUEST__
      limits:
        cpu: __CPU_LIMIT__
        memory: __MEMORY_LIMIT__
    ingress:
      hostname: __INGRESS_HOSTNAME__
    secrets: []
    autoscaling:
      enabled: true
      minReplicas: 1
      maxReplicas: 2
      targetCPUUtilizationPercentage: 80
