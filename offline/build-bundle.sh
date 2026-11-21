#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ساخت باندل نصب آفلاین GitLab CE + GitLab Runner (+ helper images)
# این اسکریپت را روی ماشینی با اینترنت اجرا کن، خروجی را به محیط ایزوله ببر.
#
#   ./build-bundle.sh                 # نسخه‌های پیش‌فرض (jammy)
#   CODENAME=noble ./build-bundle.sh  # برای Ubuntu 24.04
#   ./build-bundle.sh --no-helper-images
# ---------------------------------------------------------------------------
set -euo pipefail

GITLAB_VERSION="${GITLAB_VERSION:-19.6.1-ce.0}"
RUNNER_VERSION="${RUNNER_VERSION:-19.6.0-1}"
HELPER_VERSION="${HELPER_VERSION:-19.6.0-1}"
CODENAME="${CODENAME:-jammy}"
ARCH="${ARCH:-amd64}"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dist}"
WITH_HELPER=1

for arg in "$@"; do
  case "$arg" in
    --no-helper-images) WITH_HELPER=0 ;;
    -h|--help) sed -n '1,12p' "$0"; exit 0 ;;
    *) echo "آرگومان ناشناخته: $arg" >&2; exit 2 ;;
  esac
done

GL_BASE="https://packages.gitlab.com"
CE_URL="$GL_BASE/gitlab/gitlab-ce/ubuntu/pool/main/g/gitlab-ce/gitlab-ce_${GITLAB_VERSION}_${ARCH}.deb"
RUNNER_URL="$GL_BASE/runner/gitlab-runner/ubuntu/pool/main/g/gitlab-runner/gitlab-runner_${RUNNER_VERSION}_${ARCH}.deb"
HELPER_URL="$GL_BASE/runner/gitlab-runner/ubuntu/pool/main/g/gitlab-runner-helper-images/gitlab-runner-helper-images_${HELPER_VERSION}_all.deb"

# sha256 برای تشخیص فایل خراب/دستکاری‌شده (از Packages رسمی گرفته شده)
CE_SHA="9fb1940b703267ba5a28f9f0d01d91b3166cd1fea94f6da4c39d0b26ed3f83a0"
RUNNER_SHA="5ed39786c0ae70a7c5d4084eb05388172cab1abbfdf64738f39438debe74d619"
HELPER_SHA="48229b7942746be6d6b7104de309d50722802dd4e5067ba482380ebe96ed5c09"

mkdir -p "$OUT_DIR/pool/main/g/gitlab-ce" \
         "$OUT_DIR/pool/main/g/gitlab-runner" \
         "$OUT_DIR/pool/main/g/gitlab-runner-helper-images"

preflight_url() {
  local url="$1" name="$2" code
  code="$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' --max-time 60 "$url" || echo 000)"
  case "$code" in
    200|206|302) return 0 ;;
  esac
  cat >&2 <<EOM
❌ نمی‌توانم $name را دانلود کنم (HTTP $code).
   دلایل رایج:
   • packages.gitlab.com فایل‌های deb را از storage.googleapis.com سرو می‌کند و
     برای بعضی کشورها geo-block است (پاسخ S3: AccessDenied / not available in your location).
     → این اسکریپت را روی ماشینی با خروجی مجاز اجرا کن، یا از تونل/پروکسی استفاده کن:
       HTTPS_PROXY=http://proxy:port ./build-bundle.sh
   • نسخهٔ درخواستی در مخزن نیست: GITLAB_VERSION/RUNNER_VERSION را چک کن.
EOM
  exit 1
}

fetch() {
  local url="$1" dest="$2" expected="$3"
  if [[ -f "$dest" ]]; then
    echo "⏭  موجود است: $(basename "$dest")"
  else
    echo "⬇  $(basename "$dest")"
    curl -fL --retry 3 --retry-delay 2 -C - -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  local actual
  actual="$(sha256sum "$dest" | awk '{print $1}')"
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "❌ sha256 نامطابق برای $(basename "$dest"): $actual" >&2
    rm -f "$dest"
    exit 1
  fi
  echo "✅ sha256 تأیید شد: $(basename "$dest")"
}

preflight_url "$CE_URL" "gitlab-ce"
preflight_url "$RUNNER_URL" "gitlab-runner"
preflight_url "$HELPER_URL" "gitlab-runner-helper-images"

fetch "$CE_URL"      "$OUT_DIR/pool/main/g/gitlab-ce/gitlab-ce_${GITLAB_VERSION}_${ARCH}.deb" "$CE_SHA"
fetch "$RUNNER_URL"  "$OUT_DIR/pool/main/g/gitlab-runner/gitlab-runner_${RUNNER_VERSION}_${ARCH}.deb" "$RUNNER_SHA"
if [[ "$WITH_HELPER" == "1" ]]; then
  fetch "$HELPER_URL" "$OUT_DIR/pool/main/g/gitlab-runner-helper-images/gitlab-runner-helper-images_${HELPER_VERSION}_all.deb" "$HELPER_SHA"
fi

# وابستگی‌های سیستمی (openssh-server, perl, git, curl, tar, ca-certificates)
# اگر می‌خواهی داخل باندل باشند و این ماشین Ubuntu هم‌کدنام است:
if [[ "${DOWNLOAD_UBUNTU_DEPS:-0}" == "1" ]]; then
  echo "⬇  دانلود وابستگی‌های سیستمی اوبونتو"
  ( cd "$OUT_DIR/pool/main" && apt-get download openssh-server perl git curl tar ca-certificates ) || \
    echo "⚠️  apt-get download ناموفق بود (توزیع باید Ubuntu $CODENAME باشد)"
else
  echo "ℹ️  وابستگی‌های سیستمی از آینهٔ apt داخلی نصب می‌شوند (DOWNLOAD_UBUNTU_DEPS=1 برای دانلودشان)."
fi

python3 "$(dirname "${BASH_SOURCE[0]}")/mkindex.py" "$OUT_DIR"

TARBALL="$OUT_DIR/gitlab-offline-${CODENAME}.tar.gz"
echo "📦 ساخت tarball: $TARBALL"
tar -czf "$TARBALL" -C "$OUT_DIR" --exclude='*.tar.gz' pool Packages Packages.gz Release
sha256sum "$TARBALL" | tee "$TARBALL.sha256"

cat <<EOF

✅ آماده انتقال:
   فایل:   $TARBALL
   حجم:    $(du -h "$TARBALL" | cut -f1)
   مسیر هدف در playbook: offline/dist/$(basename "$TARBALL")

بعد از انتقال به ماشین کنترل (بدون اینترنت):
   make syntax      # بررسی
   make deploy      # اجرای playbook
EOF
