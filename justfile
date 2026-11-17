# QShare development and GitHub release tasks.

default:
    @just --list

build:
    ./run.sh build

test:
    ./run.sh test

# Commit pending work, build and test, then tag, push, and publish on GitHub.
# Usage: just release [patch|minor|major] [release message]
[positional-arguments]
release *args:
    #!/usr/bin/env bash
    set -euo pipefail

    bump=patch
    message_parts=()
    for arg in "$@"; do
      case "$arg" in
        patch|minor|major) bump="$arg" ;;
        *) message_parts+=("$arg") ;;
      esac
    done
    message="${message_parts[*]:-}"

    branch=$(git branch --show-current)
    if [ "$branch" != main ]; then
      echo "Releases must run from main (currently on $branch)." >&2
      exit 1
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
      git add -A
      if [ -z "$message" ]; then
        count=$(git diff --cached --name-only | wc -l | tr -d ' ')
        message="release: $count files"
      fi
      git commit -m "$message"
    fi

    ./run.sh test
    ./run.sh build

    latest=$(git tag --list 'v[0-9]*' --sort=-version:refname | head -1)
    version=${latest#v}
    if [ -z "$version" ]; then version=0.0.0; fi
    IFS=. read -r major minor patchnum <<< "$version"
    major=${major:-0}; minor=${minor:-0}; patchnum=${patchnum:-0}
    case "$bump" in
      major) major=$((major + 1)); minor=0; patchnum=0 ;;
      minor) minor=$((minor + 1)); patchnum=0 ;;
      patch) patchnum=$((patchnum + 1)) ;;
    esac
    tag="v$major.$minor.$patchnum"
    git tag -a "$tag" -m "QShare $tag"
    git push origin main --follow-tags
    gh release create "$tag" --title "QShare $tag" --generate-notes
