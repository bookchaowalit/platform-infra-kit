# Template rendered by render-application.sh (APP_SLUG=booknbook)
# Placeholders: __ARGOCD_REPO_URL__ __ARGOCD_TARGET_REVISION__ __IMAGE_REPOSITORY__ __IMAGE_TAG__
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: booknbook-dev
  namespace: argocd
  labels:
    app.kubernetes.io/name: booknbook
    solo.empire/environment: dev
    solo.empire/region: local
    solo.empire/team: product
    solo.empire/pilot: "true"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: solo-empire-apps
  source:
    repoURL: __ARGOCD_REPO_URL__
    targetRevision: __ARGOCD_TARGET_REVISION__
    path: infra/platform/helm/solo-app
    helm:
      releaseName: booknbook
      valueFiles:
        - pilot/dev-common.yaml
        - pilot/booknbook-dev.yaml
      parameters:
        - name: image.repository
          value: __IMAGE_REPOSITORY__
        - name: image.tag
          value: __IMAGE_TAG__
        - name: image.pullPolicy
          value: Always
  destination:
    server: https://kubernetes.default.svc
    namespace: apps-booknbook-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 1m
