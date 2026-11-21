# GitLab CE + Runner — نصب ایزوله با Ansible

نصب تکرارپذیر GitLab CE و GitLab Runner برای محیط بدون اینترنت (۳ تا ۵ کاربر).

## معماری

| نقش | هاست نمونه | منابع | سرویس |
|---|---|---|---|
| GitLab CE (Omnibus) | `gitlab01` | 4 vCPU / 8GB / 100GB SSD | `gitlab-ctl` |
| GitLab Runner | `runner01` | 2 vCPU / 4GB / 60GB | `gitlab-runner` + Docker |

اگر فقط یک سرور داری، `gitlab01` را در هر دو گروه `gitlab` و `runners` بگذار (roleها ترتیب دارند).

پیش‌نیازها:
- Ubuntu 22.04 (jammy) یا 24.04 (noble)
- یک کاربر با `sudo` بدون رمز (پیش‌فرض: `ansible`)
- رکورد DNS داخلی برای `gitlab.intra.local` → IP سرور
- آینهٔ apt داخلی برای پکیج‌های اوبونتو (`openssh-server`, `perl`, `git`, `curl`, `tar`, `docker.io`)

## آیا باندل لازم است؟ (میرور داخلی داری)

`gitlab-ce` و `gitlab-runner` در مخزن اوبونتو **نیستند**؛ از `packages.gitlab.com` می‌آیند.
پس اول این را چک کن که میرور داخلی‌ات کدام است:

```bash
# روی سرور هدف (بعد از اینکه میرور در sources.list تنظیم است)
apt-cache policy gitlab-ce gitlab-runner
```

| وضعیت میرور | باندل لازم است؟ | تنظیم |
|---|---|---|
| فقط آرشیو اوبونتو (jammy/noble) | ✅ بله — گیت‌لب در آرشیو اوبونتو نیست | `gitlab_pkg_source: bundle` |
| مخزن گیت‌لب هم mirror شده (aptly/Nexus/Artifactory) | ❌ نه | `gitlab_pkg_source: mirror` |
| Nexus/Artifactory با proxy به `packages.gitlab.com` | ❌ نه* | `gitlab_pkg_source: mirror` |

\* اگر خودِ میرور هم از ایران به `storage.googleapis.com` می‌زند، همان geo-block را می‌خورد؛
در آن حالت باندل (که بیرون ساخته شده) مطمئن‌تر است.

میرور پکیج‌های اوبونتو (پیش‌نیازهای `openssh-server`, `perl`, `docker.io`, …) در هر دو حالت
باید کار کند — آن‌ها هیچ ربطی به باندل گیت‌لب ندارند.

**رجیستری داکر داخلی** روی نیاز به باندل اثری ندارد (باندل دربارهٔ deb گیت‌لب است)، ولی مرحلهٔ
`docker load` را حذف می‌کند: runner مستقیم از رجیستری می‌کشد. جزئیات در بخش ۵.

## ۱) ساخت باندل آفلاین (فقط اگر `gitlab_pkg_source: bundle`)

روی ماشینی که اینترنت دارد:

```bash
make bundle                     # gitlab-ce 19.6.1 + runner 19.6.0 + helper images
CODENAME=noble make bundle      # برای Ubuntu 24.04
```

خروجی: `offline/dist/gitlab-offline-jammy.tar.gz` (~۱.۶GB) + فایل `.sha256`.

این tarball سه پکیج را دارد و یک مخزن apt محلی (`Packages`, `Packages.gz`, `Release`) می‌سازد.
sha256 هر سه پکیج در اسکریپت هاردکد شده و قبل از ساخت باندل بررسی می‌شود.

> ⚠️ فایل‌های deb از `storage.googleapis.com` سرو می‌شوند و از IP ایران geo-block هستند
> (`AccessDenied: not available in your location`). اسکریپت اول یک preflight می‌زند و پیام
> واضح می‌دهد. باندل را روی ماشینی با خروجی مجاز بساز، یا:
> `HTTPS_PROXY=http://proxy:port ./offline/build-bundle.sh`

### حالت mirror (بدون باندل)

```yaml
# inventories/prod/group_vars/all/main.yml
gitlab_pkg_source: mirror
gitlab_apt_mirror_line: "deb [trusted=yes] http://mirror.intra.local/gitlab jammy main"
# اگر مخزن کلید امضا دارد:
# gitlab_apt_mirror_key_url: "http://mirror.intra.local/keys/gitlab.asc"
```

سپس فقط `make gitlab` / `make runner`. role خودش بررسی می‌کند که نسخهٔ pin‌شده در مخزن
موجود باشد و اگر نبود، با پیام روشن می‌ایستد (`apt-cache policy` را چاپ می‌کند).
باندل، `offline/dist` و اسکریپت build در این حالت اصلاً استفاده نمی‌شوند.

## ۲) انتقال و تنظیم

```bash
# روی ماشین کنترل داخل شبکه ایزوله
tar -xzf gitlab-infra.tar.gz && cd gitlab-infra
make deps          # فقط ansible-core + jinja2 از requirements.txt
make deps-dev      # + ansible-lint (اختیاری)

# ۱. آدرس‌ها
vi inventories/prod/hosts.yml
vi inventories/prod/group_vars/all.yml      # gitlab_fqdn, نسخه‌ها

# ۲. رازها
vi inventories/prod/group_vars/all/vault.yml    # رمز root و (بعداً) توکن runner
make vault-encrypt

# ۳. باندل را کنار playbook بگذار
ls offline/dist/gitlab-offline-jammy.tar.gz

make ping
make syntax
```

## ۳) نصب GitLab

```bash
make gitlab
```

چه اتفاقی می‌افتد:
1. مخزن apt محلی از باندل ساخته می‌شود (`/opt/gitlab-offline`)
2. `gitlab-ce` نسخهٔ pin‌شده نصب می‌شود
3. `/etc/gitlab/gitlab.rb` از تمپلیت ساخته می‌شود (منابع کم، تلمتری خاموش، بکاپ روزانه)
4. `gitlab-ctl reconfigure` فقط اگر کانفیگ/نسخه تغییر کرده باشد اجرا می‌شود
5. تا بالا آمدن `/users/sign_in` صبر می‌کند
6. رمز `root` را از vault ست می‌کند (یک‌بار، با نشانگر `/etc/gitlab/.root_password_managed`)

ورود: `http://gitlab.intra.local` با کاربر `root`.

## ۴) ساخت Runner و توکن

از GitLab 17 به بعد `registration_token` حذف شده است؛ توکن باید از UI گرفته شود:

1. `Admin Area → CI/CD → Runners → New instance runner`
2. پلتفرم: Linux، اجرا: Docker
3. توکن `glrt-…` را کپی کن (فقط یک بار نمایش داده می‌شود)
4. در `vault.yml` بگذار: `vault_gitlab_runner_token: "glrt-…"`
5. `make vault-edit` (یا فایل را دوباره رمز کن)

```bash
make runner
```

Role توکن را مستقیم در `/etc/gitlab-runner/config.toml` می‌نویسد (بدون `gitlab-runner register`)
و در پایان با `gitlab-runner verify` اتصال را چک می‌کند.

## ۵) اجرای CI با رجیستری داخلی

اگر رجیستری داخلی داری، runner از همان می‌کشد و مرحلهٔ `docker load` حذف می‌شود:

```yaml
# group_vars/runners.yml
gitlab_runner_pull_policy: if-not-present          # always اگر تگ‌ها بازنویسی می‌شوند
gitlab_runner_docker_insecure_registries: ["registry.intra.local:5000"]   # اگر HTTP است
# gitlab_runner_docker_registry_mirrors: ["https://mirror.example"]       # برای داکرهاب
```

اگر رجیستری لاگین لازم دارد، محتوای `~/.docker/config.json` را در vault بگذار:

```yaml
# group_vars/all/vault.yml
vault_gitlab_runner_docker_config_json: '{"auths":{"registry.intra.local:5000":{"auth":"base64(user:pass)"}}}'
```

role آن را با مود ۰۶۰۰ در `/root/.docker/config.json` می‌نویسد (سرویس runner با root اجرا می‌شود).
در `.gitlab-ci.yml` هم `image:` را با آدرس رجیستری بگذار:
`image: registry.intra.local:5000/ci/node:20`.

### اگر رجیستری نداری

`pull_policy = "if-not-present"` یعنی runner ایمیج را از اینترنت نمی‌کشد؛ باید از قبل موجود باشد:

```bash
# روی ماشین با اینترنت
docker pull node:20-bullseye && docker save node:20-bullseye | gzip > node.tar.gz
# روی runner
gunzip -c node.tar.gz | docker load
docker image ls
```

در `.gitlab-ci.yml` هم `image:` را همان ایمیج بارگذاری‌شده بگذار. برای build کردن ایمیج،
`gitlab_runner_privileged: true` لازم است (پیش‌فرض `false`).

## ۶) بکاپ

Cron در `/etc/cron.d/gitlab-backup` هر شب ۰۲:۳۰:

```bash
/opt/gitlab/bin/gitlab-backup create CRON=1                                   # دیتابیس + repoها
tar -czf <backup_path>/etc-gitlab-$(date +%Y%m%d).tar.gz -C / etc/gitlab      # کانفیگ و secretها
```

بکاپ گیت‌لب **شامل** `/etc/gitlab/gitlab.rb` و کلیدهای secret نیست — آرشیو دوم برای همین است.

ریستور (روی نصب تازه با همان نسخه):

```bash
# ۱. کانفیگ و secretها
tar -xzf etc-gitlab-YYYYMMDD.tar.gz -C /
# ۲. reconfigure
gitlab-ctl reconfigure
# ۳. بکاپ دیتا
gitlab-ctl stop puma && gitlab-ctl stop sidekiq
gitlab-backup restore BACKUP=<timestamp>
gitlab-ctl reconfigure && gitlab-ctl restart
gitlab-rake gitlab:check SANITIZE=true
```

بکاپ را روی NFS/سرور جدا کپی کن؛ روی همان دیسک بی‌فایده است.

## ۷) آپگرید

نسخه در یک جا است: `inventories/prod/group_vars/all.yml → gitlab_ce_version`.

```bash
# روی ماشین با اینترنت
GITLAB_VERSION=19.7.0-ce.0 RUNNER_VERSION=19.7.0-1 HELPER_VERSION=19.7.0-1 make bundle
# انتقال باندل، سپس
make gitlab
```

قواعد:
- پرش نسخهٔ major مجاز نیست؛ مسیر آپگرید را از docs گیت‌لب چک کن (مثلاً ۱۸.x → ۱۹.0 → ۱۹.6)
- قبل از هر آپگرید بکاپ بگیر و `gitlab-ctl status` را چک کن
- sha256 پکیج جدید را در `offline/build-bundle.sh` آپدیت کن

## ۸) HTTPS با CA داخلی

```yaml
# group_vars/all.yml
gitlab_scheme: https
# group_vars/gitlab.yml
gitlab_tls_cert: /etc/gitlab/ssl/gitlab.intra.local.crt
gitlab_tls_key:  /etc/gitlab/ssl/gitlab.intra.local.key
```

فایل‌ها را قبل از اجرا روی سرور در `/etc/gitlab/ssl/` بگذار (`chmod 600` روی کلید) و CA داخلی را
روی کلاینت‌ها trust کن. `letsencrypt` عمداً خاموش است.

## ۹) عیب‌یابی

| علامت | علت رایج |
|---|---|
| `apt update` روی سرور fail | آینهٔ داخلی در `sources.list` تنظیم نشده |
| گیت‌لب بالا نمی‌آید | RAM < 8GB یا swap صفر → `free -m`, `gitlab-ctl status` |
| `gitlab-runner verify` خطای اتصال | توکن باطل، DNS، یا فایروال؛ `journalctl -u gitlab-runner -n 50` |
| job با `image not found` می‌خورد | ایمیج با `docker load` بارگذاری نشده (`pull_policy=if-not-present`) |
| `502` در رابط وب | `puma` بالا نیامده → `gitlab-ctl tail puma` |
| ایمیل نمی‌آید | `gitlab_smtp_enable=false` است (پیش‌فرض) → رمز را از پنل ادمین ریست کن |

لاگ‌ها: `/var/log/gitlab/`, `gitlab-ctl tail`, `gitlab-ctl status`.

## ساختار

```
site.yml                     # ترتیب: common → gitlab → runner
inventories/prod/            # hosts + group_vars (vault.yml رمز شود)
roles/common/                # timezone, NTP, apt, /etc/hosts, ufw
roles/gitlab_server/         # مخزن آفلاین، نصب، gitlab.rb، health، بکاپ
roles/gitlab_runner/         # نصب، docker، config.toml، verify
offline/build-bundle.sh      # ساخت باندل + sha256
offline/mkindex.py           # ساخت Packages/Packages.gz/Release بدون ابزار بیرونی
```
