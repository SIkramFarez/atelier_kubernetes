#!/usr/bin/env bash
# =============================================================================
# Atelier Kubernetes 2026 — tout l'atelier en une commande (GitHub Codespace)
# Usage :  chmod +x setup-atelier.sh && ./setup-atelier.sh
# Ré-exécutable sans risque (idempotent) : utile après un redémarrage du Codespace.
# =============================================================================
set -euo pipefail

CLUSTER=lab
SITE_DIR=k8s/site
BONUS_DIR=k8s/bonus
MARIO_FILE=k8s/mario/mario.yaml
SITE_MSG="${SITE_MSG:-Bienvenue sur mon site Web (déployé avec Kubernetes)}"

c_info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
c_ok()    { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
c_warn()  { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

# Lance (ou relance) proprement un port-forward en arrière-plan
port_forward() {  # $1=namespace $2=service $3=local:remote $4=logfile
  local ns="$1" svc="$2" ports="$3" log="$4"
  pkill -f "port-forward.*svc/${svc} ${ports}" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward -n "$ns" "svc/${svc}" "$ports" >"$log" 2>&1 &
  sleep 2
  if pgrep -f "port-forward.*svc/${svc} ${ports}" >/dev/null; then
    c_ok "port-forward ${svc} → ${ports%%:*}"
  else
    c_warn "port-forward ${svc} a échoué, voir ${log}"
  fi
}

url_for() {  # URL publique Codespaces pour un port
  if [[ -n "${CODESPACE_NAME:-}" ]]; then
    echo "https://${CODESPACE_NAME}-$1.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
  else
    echo "http://localhost:$1/"
  fi
}

# -----------------------------------------------------------------------------
c_info "Exercice 0 : outils"
if ! command -v k3d >/dev/null; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
c_ok "$(k3d version | head -1)"

if ! grep -q "alias k=kubectl" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc <<'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
  c_ok "alias k + autocomplétion ajoutés (ouvrez un nouveau terminal)"
fi

# -----------------------------------------------------------------------------
c_info "Exercice 1 : cluster k3d « ${CLUSTER} » (1 server + 2 agents)"
if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER}\""; then
  k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
  c_ok "cluster existant démarré"
else
  k3d cluster create "$CLUSTER" --servers 1 --agents 2 -p "8081:80@loadbalancer" --wait
fi
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
kubectl get nodes -o wide

# -----------------------------------------------------------------------------
c_info "Exercice 2 : déploiement impératif « web »"
kubectl create deployment web --image=nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl get svc web >/dev/null 2>&1 || kubectl expose deployment web --port=80 >/dev/null
kubectl rollout status deploy/web --timeout=120s
c_info "Auto-réparation : suppression du pod web"
kubectl delete pod -l app=web --wait=false >/dev/null
kubectl rollout status deploy/web --timeout=120s
kubectl get pods -l app=web

# -----------------------------------------------------------------------------
c_info "Exercice 3 : modification en direct (éphémère)"
kubectl exec deploy/web -- sh -c 'echo "<h1>Bienvenue sur mon site Web</h1>" > /usr/share/nginx/html/index.html'
kubectl exec deploy/web -- cat /usr/share/nginx/html/index.html
kubectl delete pod -l app=web >/dev/null
kubectl rollout status deploy/web --timeout=120s
c_ok "après suppression : $(kubectl exec deploy/web -- sh -c 'grep -o "<title>.*</title>" /usr/share/nginx/html/index.html')  (message perdu)"

# -----------------------------------------------------------------------------
c_info "Exercice 4 : manifestes déclaratifs (${SITE_DIR})"
mkdir -p "$SITE_DIR"
for f in configmap deployment service; do
  [[ -f "$SITE_DIR/$f.yaml" && ! -f "$SITE_DIR/$f.yaml.orig" ]] && cp "$SITE_DIR/$f.yaml" "$SITE_DIR/$f.yaml.orig"
done

cat > "$SITE_DIR/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: site-html
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="fr">
    <head><meta charset="utf-8"><title>Mon site Kubernetes</title></head>
    <body style="font-family:sans-serif;text-align:center;margin-top:10vh">
      <h1>${SITE_MSG}</h1>
      <p>Servi par nginx, contenu stocké dans une ConfigMap.</p>
    </body>
    </html>
EOF

cat > "$SITE_DIR/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: site
  labels:
    app: site
spec:
  replicas: 3
  selector:
    matchLabels:
      app: site
  template:
    metadata:
      labels:
        app: site
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
      volumes:
        - name: html
          configMap:
            name: site-html
EOF

cat > "$SITE_DIR/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: site
spec:
  selector:
    app: site
  ports:
    - port: 80
      targetPort: 80
EOF

kubectl apply -f "$SITE_DIR/"
kubectl rollout status deploy/site --timeout=180s
c_info "Persistance : suppression des pods site"
kubectl delete pod -l app=site >/dev/null
kubectl rollout status deploy/site --timeout=180s
c_ok "contenu servi : $(kubectl exec deploy/site -- grep -o '<h1>.*</h1>' /usr/share/nginx/html/index.html)"

# -----------------------------------------------------------------------------
c_info "Exercice 5 : scaling (3 replicas) + rolling update 1.27 → 1.28"
kubectl get pods -l app=site -o wide
sed -i 's#image: nginx:1.27#image: nginx:1.28#' "$SITE_DIR/deployment.yaml"
kubectl apply -f "$SITE_DIR/"
kubectl rollout status deploy/site --timeout=180s
kubectl rollout history deploy/site

c_info "Version cassée (nginx:9.99) puis rollback"
kubectl set image deploy/site nginx=nginx:9.99 >/dev/null
sleep 20
kubectl get pods -l app=site
BAD_POD=$(kubectl get pods -l app=site --no-headers | awk '$3 ~ /Err|BackOff/ {print $1; exit}')
if [[ -n "${BAD_POD}" ]]; then
  c_warn "pod en erreur : ${BAD_POD}"
  kubectl describe pod "$BAD_POD" | grep -iE "Failed|not found|manifest unknown" | head -3 || true
fi
c_ok "pods encore prêts pendant la panne : $(kubectl get deploy site -o jsonpath='{.status.readyReplicas}')/3"
kubectl rollout undo deploy/site >/dev/null
kubectl rollout status deploy/site --timeout=180s
if kubectl diff -f "$SITE_DIR/" >/dev/null 2>&1; then
  c_ok "kubectl diff : cluster et fichiers alignés"
else
  c_warn "écart détecté, réalignement"; kubectl apply -f "$SITE_DIR/" >/dev/null
fi

# -----------------------------------------------------------------------------
c_info "Exercice 6 : Portainer + Mario"
kubectl get ns portainer >/dev/null 2>&1 || kubectl create ns portainer >/dev/null
kubectl apply -n portainer -f https://downloads.portainer.io/ce-lts/portainer.yaml >/dev/null
kubectl rollout status deploy/portainer -n portainer --timeout=300s
# redémarrage pour repartir avec un délai de 5 min frais pour créer l'admin
kubectl rollout restart deploy/portainer -n portainer >/dev/null
kubectl rollout status deploy/portainer -n portainer --timeout=300s

if [[ -f "$MARIO_FILE" ]]; then
  kubectl apply -n default -f "$MARIO_FILE"
  kubectl rollout status deploy/mario --timeout=300s || true
else
  c_warn "$MARIO_FILE introuvable, Mario ignoré"
fi

# -----------------------------------------------------------------------------
c_info "Bonus A : Ingress (Traefik, port 8081)"
mkdir -p "$BONUS_DIR"
[[ -f "$BONUS_DIR/ingress.yaml" && ! -f "$BONUS_DIR/ingress.yaml.orig" ]] && cp "$BONUS_DIR/ingress.yaml" "$BONUS_DIR/ingress.yaml.orig"
cat > "$BONUS_DIR/ingress.yaml" <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: site
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: site
                port:
                  number: 80
EOF
kubectl apply -f "$BONUS_DIR/ingress.yaml"

c_info "Bonus D : namespace prod"
kubectl get ns prod >/dev/null 2>&1 || kubectl create ns prod >/dev/null
kubectl apply -n prod -f "$SITE_DIR/" >/dev/null
c_ok "copie du site déployée dans « prod »"

# -----------------------------------------------------------------------------
c_info "Tunnels"
pkill -f "port-forward svc/web" 2>/dev/null || true
port_forward default   site      8080:80   /tmp/site.log
port_forward portainer portainer 9000:9000 /tmp/portainer.log
kubectl get svc mario >/dev/null 2>&1 && port_forward default mario 8585:85 /tmp/mario.log

if [[ -n "${CODESPACE_NAME:-}" ]] && command -v gh >/dev/null; then
  gh codespace ports visibility 8585:public -c "$CODESPACE_NAME" >/dev/null 2>&1 \
    && c_ok "port 8585 rendu public" \
    || c_warn "rendez 8585 public à la main : onglet PORTS > clic droit > Port Visibility > Public"
fi

# -----------------------------------------------------------------------------
c_info "Score"
[[ -x scripts/check.sh ]] && ./scripts/check.sh || c_warn "scripts/check.sh absent ou non exécutable"

cat <<EOF

=============================================================================
 Terminé.
   Site (port-forward) : $(url_for 8080)
   Site (Ingress)      : $(url_for 8081)
   Portainer           : $(url_for 9000)   <- créez l'admin dans les 5 minutes !
   Mario (public)      : $(url_for 8585)   <- à coller dans RENDU.md (Q12)

 Reste à faire à la main :
   - créer le compte admin Portainer (12 caractères min.)
   - répondre aux questions dans RENDU.md
   - git add k8s/ RENDU.md && git commit -m "Rendu atelier Kubernetes" && git push
   - arrêter le Codespace
=============================================================================
EOF
