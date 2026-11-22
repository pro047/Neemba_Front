#!/usr/bin/env bash
# Builds the release APK from main and publishes it as a GitHub Release, which
# Obtainium on the device picks up as an update.
#
# Every check runs before anything is built or published. The ones that matter
# most are the ones a person forgets: Android refuses an update whose
# versionCode is not higher than the installed one, and a release built from
# anything but the pushed main would publish code nobody can find in history.
#
#   scripts/release.sh           checks, build, confirm, publish
#   scripts/release.sh --check   checks only (nothing is built or published)

set -euo pipefail

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
say() { printf 'release: %s\n' "$*" >&2; }

CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  *) die "unknown option: $1 (usage: scripts/release.sh [--check])" ;;
esac

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Reads "<name>+<code>" from the `version:` line of a pubspec on stdin.
pubspec_version() {
  sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' | head -n 1
}

# 1. Branch: releases are cut from main only, and only once main is pushed.
branch="$(git symbolic-ref -q --short HEAD || true)"
[ "$branch" = "main" ] || die "run this on main (current: ${branch:-detached HEAD})"

# 2. Clean tree: an uncommitted change would ship without being in history.
[ -z "$(git status --porcelain)" ] || die "working tree has uncommitted changes — commit or stash them first"

git fetch --quiet --tags origin main
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse origin/main)"
[ "$local_head" = "$remote_head" ] \
  || die "local main ($(git rev-parse --short HEAD)) differs from origin/main ($(git rev-parse --short origin/main)) — push or pull first"

# 3. Version from pubspec.yaml.
version="$(pubspec_version < pubspec.yaml)"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' \
  || die "pubspec.yaml version must look like 1.0.1+2 (got: '${version}')"
name="${version%+*}"
code="${version#*+}"
tag="v${name}"

# 4. Against earlier releases.
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
   || [ -n "$(git ls-remote --tags origin "refs/tags/${tag}")" ]; then
  die "tag ${tag} already exists — bump the version in pubspec.yaml"
fi

prev_tag="$(git tag -l 'v*' --sort=-v:refname | head -n 1)"
if [ -n "$prev_tag" ]; then
  prev_version="$(git show "${prev_tag}:pubspec.yaml" | pubspec_version)"
  prev_code="${prev_version#*+}"
  printf '%s' "$prev_code" | grep -Eq '^[0-9]+$' \
    || die "cannot read versionCode from ${prev_tag}:pubspec.yaml (got: '${prev_version}')"
  [ "$code" -gt "$prev_code" ] \
    || die "versionCode ${code} is not higher than ${prev_tag} (${prev_code}) — the device would refuse the update"
  say "previous release ${prev_tag} (versionCode ${prev_code}) → ${tag} (versionCode ${code})"
else
  say "no previous release tag — ${tag} (versionCode ${code}) is the first"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  say "checks passed (--check: nothing built or published)"
  exit 0
fi

# 5. Build. android/app/build.gradle.kts fails here if the release key is missing.
flutter build apk --release

# 6. One APK per release, named after the tag.
apk_dir="build/app/outputs/flutter-apk"
apk="${apk_dir}/neemba-${tag}.apk"
cp "${apk_dir}/app-release.apk" "$apk"
say "built ${apk} ($(du -h "$apk" | cut -f1))"

# 7. Publish. The repository is public, so this makes the APK downloadable by anyone.
printf 'release: publish %s as a PUBLIC GitHub Release? (y/N) ' "$tag" >&2
read -r answer < /dev/tty || answer=n
[ "$answer" = "y" ] || die "not published (answer was not y)"

gh release create "$tag" "$apk" \
  --target "$local_head" \
  --title "$tag" \
  --notes "versionCode ${code}"
say "published ${tag}"
