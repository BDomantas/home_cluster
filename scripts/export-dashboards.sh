#!/bin/bash
set -e

# Configuration
GRAFANA_URL="http://localhost:3000"
USER="admin"
PASSWORD="admin" # As defined in values.yaml
OUTPUT_DIR="platform/monitoring/grafana_dashboards"
POD_NAME=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")

# Helper for JSON parsing using Python (to avoid jq dependency)
json_extract() {
    python3 -c "import sys, json; print(json.load(sys.stdin) $1)"
}

echo "1. Port-forwarding Grafana..."
kubectl port-forward -n monitoring "$POD_NAME" 3000:3000 > /dev/null 2>&1 &
PID=$!

# Cleanup trap
cleanup() {
  echo "Stopping port-forward (PID: $PID)..."
  kill $PID || true
}
trap cleanup EXIT

echo "Waiting for Grafana to be reachable..."
sleep 3

echo "2. Fetching dashboard list..."
# Get list of dashboards (UIDs and Titles) using Python
DASH_LIST=$(curl -s -u "$USER:$PASSWORD" "$GRAFANA_URL/api/search?query=&" | \
    python3 -c "import sys, json; [print(f'{d[\"uid\"]}|{d[\"title\"]}') for d in json.load(sys.stdin)]")

mkdir -p "$OUTPUT_DIR"

# Loop through each dashboard
echo "$DASH_LIST" | while IFS="|" read -r DASH_UID TITLE; do
  if [ -z "$DASH_UID" ]; then continue; fi
  
  # Slugify title for filename
  FILENAME=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__/_/g')
  
  echo "Exporting: $TITLE ($DASH_UID) -> $OUTPUT_DIR/$FILENAME.json"
  
  curl -s -u "$USER:$PASSWORD" "$GRAFANA_URL/api/dashboards/uid/$DASH_UID" | \
    python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin)['dashboard'], indent=2))" > "$OUTPUT_DIR/$FILENAME.json"
done

echo "Done! Dashboards saved to $OUTPUT_DIR"
