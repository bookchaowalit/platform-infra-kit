# Local k3d pilot values for __APP_NAME__.
# No secrets in Git. No PostgreSQL/Redis in chart.
# Image repository/tag set at deploy time to git-<sha> via helm parameters.

nameOverride: __APP_NAME__
fullnameOverride: __APP_NAME__

app:
  name: __APP_NAME__
  team: __TEAM__
  environment: dev
  region: local
  component: __COMPONENT__
  partOf: solo-empire

mode: __MODE__

image:
  repository: k3d-solo-registry:5000/__IMAGE_NAME__
  tag: "git-pending"
  pullPolicy: Always

__SECURITY_CONTEXT_BLOCK__

replicaCount: 1

service:
  enabled: true
  type: ClusterIP
  port: 80
  targetPort: __TARGET_PORT__

ingress:
  enabled: true
  className: nginx
  annotations: {}
  hosts:
    - host: __INGRESS_HOSTNAME__
      paths:
        - path: /
          pathType: Prefix
  tls: []

configMap:
  enabled: true
  data:
    APP_ENV: dev

externalSecrets:
  enabled: false

envFromSecrets: []
env: []

resources:
  requests:
    cpu: __CPU_REQUEST__
    memory: __MEMORY_REQUEST__
  limits:
    cpu: __CPU_LIMIT__
    memory: __MEMORY_LIMIT__

probes:
  liveness:
    enabled: true
    path: __LIVENESS_PATH__
    port: http
    initialDelaySeconds: 15
    periodSeconds: 20
    timeoutSeconds: 5
    failureThreshold: 3
  readiness:
    enabled: true
    path: __READINESS_PATH__
    port: http
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startup:
    enabled: true
    path: __STARTUP_PATH__
    port: http
    initialDelaySeconds: 0
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 36

autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 2
  targetCPUUtilizationPercentage: 80

podDisruptionBudget:
  enabled: true
  minAvailable: 0

networkPolicy:
  enabled: true
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
        - podSelector: {}
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: __TARGET_PORT__
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.43.0.0/16
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - ports:
        - protocol: TCP
          port: 443

topologySpreadConstraints:
  enabled: false

serviceMonitor:
  enabled: false

volumeMounts:
  - name: tmp
    mountPath: /tmp

volumes:
  - name: tmp
    emptyDir: {}
