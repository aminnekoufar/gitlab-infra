# چیت‌شیت عملیات روزمره — GitLab ایزوله

دو محل اجرا دارد و مهم است که قاطی نشوند:

| کجا | چه چیزی |
|---|---|
| **کنترل‌نود** (لپ‌تاپ/ماشین تو، داخل `gitlab-infra/`) | `make …`، `ansible-playbook …` |
| **سرور** (با SSH و `sudo`) | `gitlab-ctl`، `gitlab-backup`، `gitlab-rails`، `gitlab-runner` |

---

## ۱. روزمره: وضعیت و سلامت

```bash
# روی سرور گیت‌لب
sudo gitlab-ctl status                 # وضعیت همهٔ سرویس‌ها (run: / down:)
sudo gitlab-ctl tail                   # tail همهٔ لاگ‌ها، Ctrl-C برای خروج
sudo gitlab-ctl tail nginx             # فقط یک سرویس
sudo gitlab-ctl tail puma

# سلامت از بیرون
curl -s -o /dev/null -w '%{http_code}\n' http://gitlab.intra.local/-/health
curl -s http://gitlab.intra.local/-/readiness?all=1 | python3 -m json.tool

# منابع
free -m
df -h /var/opt/gitlab
sudo du -sh /var/opt/gitlab/* | sort -h | tail -5

# بررسی سلامت داخلی (کند، ولی جامع)
sudo gitlab-rake gitlab:check SANITIZE=true
```

از کنترل‌نود:

```bash
make health                       # کد HTTP رابط وب
make ping                         # آیا SSH همهٔ هاست‌ها جواب می‌دهد
.venv/bin/ansible -i inventories/prod/hosts.yml all -m setup -a 'filter=ansible_memtotal_mb'
```

---

## ۲. کاربران

> راه معمول: UI → `Admin Area > Users > New user`. دستورهای زیر برای وقتی است که UI در دسترس نیست
> یا می‌خواهی گروهی/تکرارپذیر انجام شود.

```bash
# فهرست کاربران
sudo gitlab-rails runner "User.all.each { |u| puts [u.id, u.username, u.email, u.admin?, u.state].join(' | ') }"

# ساخت کاربر (skip_confirmation لازم است، وگرنه ایمیل تأیید لازم می‌شود و SMTP نداری)
sudo gitlab-rails runner "u = User.new(username: 'ali', email: 'ali@intra.local', name: 'Ali Rezaei', password: 'S3cure-Pass1', password_confirmation: 'S3cure-Pass1', skip_confirmation: true); u.save!; puts \"id=#{u.id}\""

# رمز را عوض کن / ریست کن
sudo gitlab-rails runner "u = User.find_by_username('ali'); u.password = 'NewPass123!'; u.password_confirmation = 'NewPass123!'; u.save!; puts 'ok'"

# ادمین کن / از ادمینی دربیار
sudo gitlab-rails runner "u = User.find_by_username('ali'); u.admin = true;  u.save!; puts u.admin?"
sudo gitlab-rails runner "u = User.find_by_username('ali'); u.admin = false; u.save!; puts u.admin?"

# بلاک / آنبلاک
sudo gitlab-rails runner "u = User.find_by_username('ali'); u.block!;    puts u.state"
sudo gitlab-rails runner "u = User.find_by_username('ali'); u.activate!; puts u.state"

# حذف کامل (برگشت‌ناپذیر)
sudo gitlab-rails runner "u = User.find_by_username('ali'); Users::DestroyService.new(User.find_by_username('root')).execute(u); puts 'deleted'"
```

با API (توکن از `User Settings > Access tokens`، دسترسی `api`):

```bash
TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
API=http://gitlab.intra.local/api/v4

curl -s --header "PRIVATE-TOKEN: $TOKEN" "$API/users?per_page=100" | python3 -m json.tool

# ساخت کاربر
curl -s --request POST --header "PRIVATE-TOKEN: $TOKEN" \
  --data "name=Ali Rezaei&username=ali&email=ali@intra.local&password=S3cure-Pass1&skip_confirmation=true" \
  "$API/users"

# ساختن پروژه
curl -s --request POST --header "PRIVATE-TOKEN: $TOKEN" \
  --data "name=my-app&path=my-app&visibility=private" \
  "$API/projects"

# اضافه‌کردن عضو: 30=Developer، 40=Maintainer، 50=Owner
curl -s --request POST --header "PRIVATE-TOKEN: $TOKEN" \
  --data "user_id=3&access_level=30" \
  "$API/projects/<PROJECT_ID>/members"
```

---

## ۳. کار روزمرهٔ کاربر (git)

```bash
git clone git@gitlab.intra.local:group/my-app.git
git clone http://gitlab.intra.local/group/my-app.git

git remote -v
git push -u origin main
```

کلید SSH را کاربر از `Preferences > SSH Keys` اضافه می‌کند. اگر پورت SSH سرور عوض شد،
در `group_vars/all/main.yml` مقدار `gitlab_ssh_port` را ست کن تا آدرس clone درست تولید شود.

---

## ۴. Ansible: تغییر تنظیم و deploy

```bash
cd ~/project/novatech/gitlab-infra

# ۱) چه چیزی عوض می‌شود؟ (بدون اعمال)
make check

# ۲) فقط یک تنظیم را عوض کن — همیشه در group_vars، نه در roles
vi inventories/prod/group_vars/gitlab.yml     # مثلاً gitlab_smtp_enable یا puma workers

# ۳) اعمال
make deploy

# فقط یک هاست / یک نقش
.venv/bin/ansible-playbook -i inventories/prod/hosts.yml site.yml --tags gitlab --limit gitlab01 --diff
.venv/bin/ansible-playbook -i inventories/prod/hosts.yml site.yml --tags runner --limit runner01

# عیب‌یابی اجرای Ansible
.venv/bin/ansible-playbook -i inventories/prod/hosts.yml site.yml --tags gitlab -vvv
.venv/bin/ansible-playbook -i inventories/prod/hosts.yml site.yml --start-at-task "پیکربندی | gitlab.rb"

# تست تمپلیت‌ها بدون تماس با سرور (سریع، برای قبل از deploy)
make render
```

بعد از هر `make deploy` انتظار داری **بار دوم** `changed=0` بدهد. اگر نداد، یعنی چیزی
idempotent نیست.

---

## ۵. Runner

```bash
# روی runner01
sudo gitlab-runner status
sudo gitlab-runner list
sudo gitlab-runner verify                 # آیا توکن‌ها معتبرند
sudo gitlab-runner verify --delete        # حذف runnerهای مرده (اول از config.toml بکاپ بگیر)
sudo journalctl -u gitlab-runner -n 50 --no-pager

sudo systemctl restart gitlab-runner
sudo systemctl status docker
sudo docker images                        # ایمیج‌های موجود برای CI
sudo docker pull registry.intra.local:5000/ci/node:20
```

**چرخش توکن** (اگر لو رفت یا منقضی شد):

1. UI → `Admin Area > CI/CD > Runners` → runner → **Rotate** → توکن جدید `glrt-…`
2. در `inventories/prod/group_vars/all/vault.yml` مقدار `vault_gitlab_runner_token` را عوض کن
3. `make vault-edit` (یا فایل را دوباره رمز کن) و بعد `make runner`

**job گیر کرده یا ایمیج پیدا نمی‌شود:**

```bash
sudo docker images | grep <اسم ایمیج>
sudo docker pull <آدرس کامل ایمیج>
# اگر رجیستری HTTP است، در group_vars/runners.yml:
#   gitlab_runner_docker_insecure_registries: ["registry.intra.local:5000"]
```

---

## ۶. بکاپ

خودکار: هر شب ۰۲:۳۰ (از `group_vars/gitlab.yml`)، دو فایل ساخته می‌شود.

```bash
# دستی
sudo gitlab-backup create CRON=1
sudo /usr/local/bin/gitlab-config-backup        # آرشیو /etc/gitlab (secretها)

# چه داری؟
ls -lh /var/opt/gitlab/backups/
```

- `<timestamp>_<version>_gitlab_backup.tar` → دیتابیس + repoها + uploads + artifacts
- `etc-gitlab-<timestamp>.tar.gz` → `gitlab.rb` + `gitlab-secrets.json` + کلیدها

**بکاپ بدون این دو با هم بی‌فایده است** — بدون `gitlab-secrets.json` دیتابیس ریستور‌شده
قابل رمزگشایی نیست.

```bash
# انتقال به سرور جداگانه (الزامی)
rsync -av --delete /var/opt/gitlab/backups/ backup-host:/backups/gitlab01/
```

تست واقعی بکاپ: روی یک VM موقت با همان نسخه، مرحلهٔ ریستور پایین را اجرا کن. بکاپی که
ریستور نشده باشد، بکاپ نیست.

---

## ۷. ریستور (فاجعه)

پیش‌نیاز: همان نسخهٔ گیت‌لب و همان CE/EE نصب شده و `gitlab-ctl reconfigure` حداقل یک‌بار اجرا شده.

```bash
# ۱) کانفیگ و secretها
sudo tar -xzf etc-gitlab-YYYYMMDDHHMM.tar.gz -C /
sudo gitlab-ctl reconfigure

# ۲) فایل بکاپ دیتا را سر جایش بگذار و مالکش را git کن
sudo cp <timestamp>_<version>_gitlab_backup.tar /var/opt/gitlab/backups/
sudo chown git:git /var/opt/gitlab/backups/<timestamp>_<version>_gitlab_backup.tar

# ۳) سرویس‌هایی که به دیتابیس وصل‌اند را بخوابان (بقیه بمانند)
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq
sudo gitlab-ctl status

# ۴) ریستور — نام فایل بدون پسوند _gitlab_backup.tar
sudo GITLAB_ASSUME_YES=1 gitlab-backup restore BACKUP=<timestamp>_<version>

# ۵) بالا بیاور و بررسی کن
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
sudo gitlab-rake gitlab:check SANITIZE=true
sudo gitlab-rake gitlab:doctor:secrets          # آیا مقادیر دیتابیس رمزگشایی می‌شوند
sudo gitlab-rake gitlab:artifacts:check
sudo gitlab-rake gitlab:lfs:check
sudo gitlab-rake gitlab:uploads:check
```

اگر خطای `version mismatch` داد، نسخهٔ نصب‌شده با نسخهٔ بکاپ یکی نیست — همان نسخه را نصب کن.

---

## ۸. آپگرید

```bash
# ۰) مسیر آپگرید را چک کن (پرش major مجاز نیست: 18.x → 19.0 → 19.6)
# ۱) بکاپ + snapshot ماشین
# ۲) روی ماشین با اینترنت: باندل جدید (یا میرور را sync کن)
GITLAB_VERSION=19.7.0-ce.0 RUNNER_VERSION=19.7.0-1 HELPER_VERSION=19.7.0-1 make bundle
# ۳) نسخه را عوض کن
vi inventories/prod/group_vars/all/main.yml      # gitlab_ce_version / gitlab_runner_version
# ۴) اعمال
make gitlab && make runner
# ۵) بررسی
sudo gitlab-ctl status
sudo gitlab-rake db:migrate:status | tail -5
sudo gitlab-rake gitlab:check SANITIZE=true
```

`gitlab-backup` بکاپ قبل از آپگرید را جدی بگیر: rollback بدون آن یعنی بازگرداندن snapshot کل VM.

---

## ۹. عیب‌یابی سریع

| نشانه | اول این را بزن | بعد |
|---|---|---|
| صفحهٔ 502 | `sudo gitlab-ctl status` + `sudo gitlab-ctl tail puma` | `free -m`؛ اگر RAM پر است `sudo gitlab-ctl restart` |
| کندی شدید | `free -m`, `df -h`, `sudo gitlab-ctl tail sidekiq` | کاهش `sidekiq concurrency` در `group_vars/gitlab.yml` |
| دیسک پر | `sudo du -sh /var/opt/gitlab/*` | `Admin Area > Settings > CI/CD` → پاک‌سازی artifacts قدیمی |
| ایمیل نمی‌آید | `sudo gitlab-rails runner "Notify.test_email('me@intra.local','test','body').deliver_now"` | `gitlab_smtp_enable` و رلهٔ داخلی |
| ورود با AD کار نمی‌کند | `sudo gitlab-rake gitlab:ldap:check` | `bind_dn` و رمز در vault |
| runner آنلاین نیست | `sudo gitlab-runner verify` | `journalctl -u gitlab-runner -n 50` |
| job: image not found | `sudo docker images` | رجیستری داخلی / `docker load` |
| بعد از ریستور، توکن‌ها خراب | `sudo gitlab-rake gitlab:doctor:secrets` | `gitlab-secrets.json` را از بکاپ برگردان |
| گیت clone با SSH کار نمی‌کند | `ssh -T git@gitlab.intra.local` | کلید کاربر، پورت `gitlab_ssh_port`، فایروال |

مسیر لاگ‌ها:

```
/var/log/gitlab/nginx/          /var/log/gitlab/puma/
/var/log/gitlab/sidekiq/        /var/log/gitlab/postgresql/
/var/log/gitlab/gitaly/         /var/log/gitlab/gitlab-shell/
```

---

## ۱۰. کارهایی که نباید بکنی

- **`/etc/gitlab/gitlab.rb` را دستی ویرایش نکن** — منبع حقیقت `group_vars` است؛ اجرای بعدی
  Ansible رویش می‌نویسد. اگر لازم شد، متغیر را اضافه کن و `make deploy` بزن.
- **`apt upgrade` دستی گیت‌لب** — نسخه در `group_vars/all/main.yml` مدیریت می‌شود.
- **`gitlab-rails runner` برای تغییرات دائمی کانفیگ** — فقط برای عملیات داده‌ای (کاربر، رمز).
- **خاموش‌کردن فایروال برای تست** — پورت لازم را باز کن (`ufw allow`)، نه اینکه ufw را disable کنی.
- **بکاپ روی همان دیسک** — کپی روی هاست دیگر یا NFS.

---

## ۱۱. مرجع سریع

| چیز | مقدار |
|---|---|
| رابط وب | `http://gitlab.intra.local` (یا https اگر `gitlab_scheme: https`) |
| clone SSH | `git@gitlab.intra.local:group/repo.git` پورت `gitlab_ssh_port` |
| کانفیگ | `/etc/gitlab/gitlab.rb` (از تمپلیت) |
| کانفیگ runner | `/etc/gitlab-runner/config.toml` |
| بکاپ | `/var/opt/gitlab/backups/` |
| داده | `/var/opt/gitlab/` (postgres، gitaly، uploads) |
| لاگ‌ها | `/var/log/gitlab/` |
| پورت‌ها | 22 (SSH)، 80/443 (وب) |
| کاربر root گیت‌لب | رمز در `vault.yml` (`vault_gitlab_root_password`) |
