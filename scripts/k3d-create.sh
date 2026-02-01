#!/usr/bin/env bash
set -e

k3d cluster create dev \
  --servers 1 \
  --agents 1 \
  --port "8080:80@loadbalancer" \
  --wait
