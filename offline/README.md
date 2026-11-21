# باندل آفلاین

```bash
./build-bundle.sh                 # jammy (Ubuntu 22.04)
CODENAME=noble ./build-bundle.sh  # noble (Ubuntu 24.04)
./build-bundle.sh --no-helper-images
```

پکیج‌ها (نسخه‌ها pin شده، sha256 بررسی می‌شود):

| پکیج | حجم | کاربرد |
|---|---|---|
| gitlab-ce_19.6.1-ce.0_amd64.deb | ~990MB | سرور GitLab |
| gitlab-runner_19.6.0-1_amd64.deb | ~20MB | سرویس runner |
| gitlab-runner-helper-images_19.6.0-1_all.deb | ~550MB | ایمیج helper برای docker executor (وابستگی اجباری runner) |

خروجی `dist/gitlab-offline-<codename>.tar.gz` است که ریشه‌اش `pool/`, `Packages`, `Packages.gz`, `Release` می‌باشد؛
role آن را در `/opt/gitlab-offline` باز می‌کند و به‌عنوان `file:` repo به apt معرفی می‌کند.

`mkindex.py` ایندکس را با stdlib می‌سازد (بدون نیاز به `dpkg-scanpackages`) و خروجی‌اش بایت‌به‌بایت
با `dpkg-scanpackages` یکسان است (تست شده).

> ⚠️ **geo-block:** فایل‌های deb از `storage.googleapis.com` سرو می‌شوند و از بعضی کشورها
> (از جمله ایران) پاسخ `AccessDenied: not available in your location` می‌گیرند. اسکریپت قبل از
> دانلود یک preflight روی هر سه URL می‌زند. راه‌حل: اجرا روی ماشینی با خروجی مجاز، یا
> `HTTPS_PROXY=http://proxy:port ./build-bundle.sh`.

## وابستگی‌های سیستمی
`openssh-server`, `perl`, `git`, `curl`, `tar`, `ca-certificates` و `docker.io` از آینهٔ apt داخلی
نصب می‌شوند. اگر آینه نداری و می‌خواهی داخل باندل باشند و این ماشین هم Ubuntu است:

```bash
DOWNLOAD_UBUNTU_DEPS=1 CODENAME=jammy ./build-bundle.sh
```
