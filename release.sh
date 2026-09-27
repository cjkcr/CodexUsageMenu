#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit your changes before creating a release.' >&2
  exit 1
fi
if [[ "$(git branch --show-current)" != main ]]; then
  echo 'Create releases from the main branch.' >&2
  exit 1
fi

git fetch origin main --tags
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo 'Update main from origin before creating a release.' >&2
  exit 1
fi

current="$(tr -d '\r\n' < VERSION)"
if [[ ! "$current" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]]; then
  echo "Invalid VERSION: $current" >&2
  exit 1
fi
parts=("${(@s:.:)current}")
major="${parts[1]}"
minor="${parts[2]}"
patch="${parts[3]}"

if ! git rev-parse -q --verify "refs/tags/v$current" >/dev/null; then
  echo "The current version v$current has not been released yet." >&2
  exit 1
fi

next="$major.$minor.$((patch + 1))"
tag="v$next"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

print -r -- "$next" > VERSION
git add VERSION
git commit -m "Release $tag"
git tag -a "$tag" -m "Release $tag"
git push --atomic origin main "$tag"
echo "GitHub Actions will build and publish $tag."
