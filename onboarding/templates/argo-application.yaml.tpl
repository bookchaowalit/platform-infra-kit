# Template rendered by deploy-app.sh / render-application.sh
# Placeholders: __APP_NAME__ __ARGOCD_REPO_URL__ __ARGOCD_TARGET_REVISION__ __IMAGE_REPOSITORY__ __IMAGE_TAG__
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: __APP_NAME__-dev
  namespace: argocd
  labels:
    app.kubernetes.io/name: __APP_NAME__
    solo.empire/environment: dev
    solo.empire/region: local
    solo.empire/team: __TEAM__
    solo.empire/pilot: "true"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: solo-empire-apps
  source:
    # Configurable Git source (never file://). Set via pilot.env / deploy-app.sh.
    repoURL: __ARGOCD_REPO_URL__
    targetRevision: __ARGOCD_TARGET_REVISION__
    path: infra/platform/helm/solo-app
    helm:
      releaseName: __APP_NAME__
      valueFiles:
        - pilot/dev-common.yaml
        - pilot/__APP_NAME__-dev.yaml
      # Immutable image override from deploy pipeline (git SHA tag)
      parameters:
        - name: image.repository
          value: __IMAGE_REPOSITORY__
        - name: image.tag
          value: __IMAGE_TAG__
        - name: image.pullPolicy
          value: Always
  destination:
    server: https://kubernetes.default.svc
    namespace: apps-__APP_NAME__-dev
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
