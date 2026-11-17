#!/bin/bash
# Project entry point for common tasks.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage: ./run.sh <command> [args]

  build [--install] [--run]   Build Release QShare.app (see Scripts/build.sh)
  test                        Run QuickShareKit tests
  protos                      Regenerate Swift from Protos/
  help                        Show this help
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  build)
    exec ./Scripts/build.sh "$@"
    ;;
  test)
    exec swift test "$@"
    ;;
  protos|generate-protos)
    exec ./Scripts/generate-protos.sh "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
