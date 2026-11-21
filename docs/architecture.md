# معماری و آموزش — GitLab ایزوله با Ansible

این سند دو کار می‌کند: (۱) معماری چیزی که ساخته شد را نشان می‌دهد، (۲) Ansible را از صفر
در همان بستری که استفاده شده توضیح می‌دهد. برای کسی نوشته شده که تا حالا با Ansible کار نکرده.

---

## ۱. Ansible در ۶ مفهوم (و فایل متناظر در این ریپو)

Ansible یک ابزار «پیکربندی به‌صورت کد» است. روی سرورها **هیچ چیزی نصب نمی‌کند** که دائمی بماند؛
فقط با SSH وصل می‌شود، دستور/فایل می‌فرستد، و می‌رود. مدل ذهنی:

| مفهوم | یعنی چه | در این ریپو |
|---|---|---|
| **کنترل‌نود** | لپ‌تاپ/سروری که `ansible-playbook` را اجرا می‌کند | ماشین خودت (با `.venv`) |
| **Inventory** | فهرست سرورها، دسته‌بندی‌شده در گروه‌ها | `inventories/prod/hosts.yml` |
| **Playbook** | فایل YAML که می‌گوید کدام گروه، چه کاری، به چه ترتیبی | `site.yml` |
| **Role** | یک بستهٔ قابل استفادهٔ مجدد از task/تمپلیت/متغیر برای یک وظیفه | `roles/common`, `roles/gitlab_server`, `roles/gitlab_runner` |
| **Task** | یک قدم مشخص که یک «ماژول» را صدا می‌زند | هر آیتم لیست در `roles/*/tasks/main.yml` |
| **Module** | خودِ کار: `apt`، `template`، `copy`، `service`، `uri`، `command` | `ansible.builtin.*` (هیچ collection خارجی لازم نیست) |

سه چیز اضافه که مدام می‌بینی:

- **Handler**: کاری که *فقط وقتی چیزی عوض شد* اجرا می‌شود (مثل `gitlab-ctl reconfigure`).
- **Variable**: مقدارها، در `group_vars`.
- **Vault**: همان متغیرها، رمزگذاری‌شده، برای رمزها و توکن‌ها.

### چرا Ansible و نه Docker Compose؟

GitLab در حالت production با پکیج Omnibus پشتیبانی می‌شود؛ Compose برای تست است. با Ansible،
آپگرید = عوض‌کردن یک عدد نسخه؛ با Compose = دست‌کاری دستی migration و ترتیب سرویس‌ها.
کانتینر جای خودش را دارد: **اجرای jobهای CI** روی runner.

---

## ۲. دیاگرام معماری

```
                         ┌──────────────────────────────────────────┐
                         │        کنترل‌نود (ماشین تو)              │
                         │  ansible-playbook  +  .venv              │
                         │  inventories/  roles/  offline/dist/     │
                         └───────────────┬──────────────────────────┘
                                         │ SSH (پورت 22) — بدون agent روی هدف
                 ┌───────────────────────┼────────────────────────┐
                 │                       │                        │
   ┌─────────────▼─────────────┐  ┌──────▼─────────────────┐      │
   │  gitlab01  (4vCPU/8GB)    │  │ runner01 (2vCPU/4GB)   │      │
   │  ┌─────────────────────┐  │  │  ┌──────────────────┐  │      │
   │  │ nginx  :80/:443     │  │  │  │ gitlab-runner    │  │      │
   │  │ puma   (وب/API)     │  │  │  │  docker executor │  │      │
   │  │ sidekiq (پس‌زمینه)  │  │  │  │  pull_policy     │  │      │
   │  │ postgresql          │  │  │  │  =if-not-present │  │      │
   │  │ redis               │  │  │  └────────┬─────────┘  │      │
   │  │ gitaly (repoها)     │  │  │           │ docker pull │      │
   │  │ gitlab-shell :22    │  │  │  ┌────────▼─────────┐  │      │
   │  └─────────┬───────────┘  │  │  │ کانتینر jobها    │  │      │
   │            │              │  │  └──────────────────┘  │      │
   │  /etc/gitlab/gitlab.rb    │  │  /etc/gitlab-runner/   │      │
   │  (از تمپلیت Jinja2)       │  │  config.toml (توکن glrt)│      │
   └────────────┬──────────────┘  └───────────┬────────────┘      │
                │                             │                    │
                │  deb گیت‌لب + پکیج‌های اوبونتو │  ایمیج CI          │
        ┌───────▼─────────────────────────────▼─────────────┐      │
        │  زیرساخت داخلی (بدون اینترنت)                     │◄─────┘
        │  • میرور apt داخلی  → پکیج‌های اوبونتو             │
        │  • باندل آفلاین یا میرور گیت‌لب → deb گیت‌لب       │
        │  • رجیستری داکر داخلی → ایمیج‌های CI               │
        │  • DNS داخلی: gitlab.intra.local                  │
        └───────────────────────────────────────────────────┘

   کاربران ──► http(s)://gitlab.intra.local   (مرورگر، ۳ تا ۵ نفر)
           └─► git@gitlab.intra.local:group/repo.git  (SSH، پورت 22)
```

نکتهٔ مهم معماری: **کنترل‌نود فقط در زمان deploy وصل می‌شود.** بعد از نصب، مسیر ترافیک
کاربران به گیت‌لب هیچ ربطی به Ansible ندارد.

---

## ۳. جریان اجرای `make deploy`

```
make deploy
└─ ansible-playbook -i inventories/prod/hosts.yml site.yml --ask-vault-pass
   │
   ├─ PLAY 1: Baseline (hosts: all)          roles/common
   │   ├─ assert: Ubuntu ≥ 22.04
   │   ├─ apt update (از میرور داخلی)  ← اگر شکست بخورد فقط هشدار می‌دهد
   │   ├─ نصب ca-certificates, curl, chrony, ufw, ...
   │   ├─ timezone = Asia/Tehran      (فقط اگر عوض شده باشد)
   │   ├─ /etc/hosts ← رکورد gitlab.intra.local
   │   └─ ufw: allow 22, 80, 443
   │
   ├─ PLAY 2: GitLab server (hosts: gitlab)  roles/gitlab_server
   │   ├─ assert: RAM ≥ 7GB، vCPU ≥ 2
   │   ├─ منبع پکیج → include_tasks: repo-bundle.yml | repo-mirror.yml
   │   │    bundle: unarchive → /opt/gitlab-offline → deb [trusted=yes] file:/...
   │   │    mirror: deb ... http://mirror.intra/... + چک وجود نسخه با apt-cache
   │   ├─ apt: gitlab-ce=19.6.1-ce.0        ← نسخه pin شده
   │   ├─ template: /etc/gitlab/gitlab.rb   (از gitlab.rb.j2) ─┐
   │   │                                                       │ notify
   │   ├─ meta: flush_handlers  ◄──────────────────────────────┘
   │   │    └─ HANDLER: gitlab-ctl reconfigure   (۲ تا ۵ دقیقه، async)
   │   ├─ uri: GET /users/sign_in → تا ۶۰ بار × ۱۰ ثانیه صبر
   │   ├─ gitlab-rails runner → ست‌کردن رمز root (یک‌بار، با marker file)
   │   └─ cron: gitlab-backup + آرشیو /etc/gitlab
   │
   └─ PLAY 3: Runner (hosts: runners)        roles/gitlab_runner
       ├─ assert: توکن glrt- واقعی است (نه placeholder)
       ├─ منبع پکیج → repo-bundle.yml | repo-mirror.yml
       ├─ apt: gitlab-runner=19.6.0-1 (+ helper-images)
       ├─ apt: docker.io  →  daemon.json (insecure-registries)  →  config.json (auth)
       ├─ template: /etc/gitlab-runner/config.toml ─┐ notify
       ├─ meta: flush_handlers → restart gitlab-runner
       └─ gitlab-runner verify → اگر rc≠0 با پیام روشن fail
```

اگر هر جا `--tags gitlab` بزنی، فقط PLAY 2 اجرا می‌شود. `--check` همه‌چیز را بدون تغییر
شبیه‌سازی می‌کند.

---

## ۴. نقشهٔ فایل‌ها

```
gitlab-infra/
├─ ansible.cfg                    تنظیمات ansible (inventory پیش‌فرض، roles_path، pipelining)
├─ requirements.txt               وابستگی کنترل‌نود: ansible-core + jinja2 (pin شده)
├─ requirements-dev.txt           + ansible-lint
├─ requirements.yml               وابستگی galaxy — عمداً خالی (فقط ansible.builtin)
├─ site.yml                       سه PLAY، به ترتیب common → gitlab → runner
├─ Makefile                       دستورهای کوتاه: syntax, lint, render, deploy, gitlab, runner, bundle
├─ .ansible-lint                  قواعد نادیده‌گرفته‌شده + دلیلشان
│
├─ inventories/prod/
│  ├─ hosts.yml                   دو گروه (gitlab, runners) و آدرس IP هر سرور
│  └─ group_vars/
│     ├─ all/main.yml             متغیرهای مشترک: FQDN، نسخه‌ها، منبع پکیج، مسیر باندل
│     ├─ all/vault.yml            ⚠️ رمزها: رمز root، توکن glrt. (vault-encrypt کن)
│     ├─ gitlab.yml               منابع و تنظیمات گیت‌لب: puma، postgres، SMTP، LDAP، بکاپ
│     └─ runners.yml              تنظیمات runner: concurrent، ایمیج، pull_policy، رجیستری
│
├─ roles/common/                  پایهٔ هر سرور: زمان، NTP، پکیج‌ها، hosts، فایروال
├─ roles/gitlab_server/
│  ├─ defaults/main.yml           پیش‌فرض‌های نقش (حداقل RAM، مسیر apt، TLS)
│  ├─ tasks/main.yml              ترتیب اصلی نصب و پیکربندی
│  ├─ tasks/repo-bundle.yml       نصب از باندل آفلاین
│  ├─ tasks/repo-mirror.yml       نصب از مخزن apt داخلی
│  ├─ handlers/main.yml           reconfigure با async
│  └─ templates/gitlab.rb.j2      قلب کانفیگ گیت‌لب
├─ roles/gitlab_runner/
│  ├─ tasks/main.yml              نصب + داکر + کانفیگ + verify
│  ├─ tasks/repo-{bundle,mirror}.yml
│  ├─ tasks/docker-registry.yml   daemon.json + اعتبارنامه رجیستری
│  ├─ handlers/main.yml           restart docker / gitlab-runner
│  └─ templates/{config.toml,daemon.json}.j2
│
├─ offline/
│  ├─ build-bundle.sh             روی ماشین با اینترنت: دانلود + sha256 + ساخت tarball
│  ├─ mkindex.py                  ساخت Packages/Packages.gz/Release با stdlib
│  └─ dist/                       خروجی (git-ignore)
│
├─ tests/render.yml               رندر تمپلیت‌ها با connection: local (بدون تماس با سرور)
└─ docs/architecture.md           همین فایل
```

---

## ۵. مسیر یک متغیر: از `group_vars` تا داخل فایل روی سرور

```
group_vars/all/main.yml        gitlab_fqdn: gitlab.intra.local
        │                              ▲
        │                     precedence: نقش defaults < group_vars < host_vars < -e
        ▼
roles/gitlab_server/templates/gitlab.rb.j2      external_url '{{ gitlab_external_url }}'
        │
        │  task: template → /etc/gitlab/gitlab.rb (mode 0600)
        ▼
handler: gitlab-ctl reconfigure  →  سرویس‌ها با کانفیگ جدید بالا می‌آیند
```

قاعدهٔ عملی: **مقدارها را در `group_vars` بگذار، منطق را در `roles`.** برای یک تغییر،
هیچ‌وقت به taskها دست نزن.

اولویت (از ضعیف به قوی) — این را حفظ کن، ۹۰٪ سردرگمی‌های Ansible از همین است:

```
role defaults  <  inventory group_vars/all  <  group_vars/<group>  <  host_vars
               <  play vars  <  task vars  <  -e (extra vars)   ← قوی‌ترین
```

> نکته‌ای که یک‌بار هزینه داد: `ansible_become: true` که در `group_vars/all` تعریف شده،
> از `become: false` در سطح play قوی‌تر است. برای خنثی‌کردنش باید `-e ansible_become=false` داد.

---

## ۶. Idempotency و Handler — چرا reconfigure هر بار اجرا نمی‌شود

هدف Ansible این است که اجرای دوباره، سرور را عوض نکند. مثال واقعی از `gitlab_server`:

```yaml
- name: پیکربندی | gitlab.rb
  ansible.builtin.template:
    src: gitlab.rb.j2
    dest: /etc/gitlab/gitlab.rb
  notify: reconfigure gitlab        # ← فقط وقتی این فایل عوض شد
```

- اگر `gitlab.rb` همان قبلی باشد → task `ok` می‌شود، handler اجرا **نمی‌شود**.
- اگر یک متغیر عوض کرده باشی → task `changed` می‌شود و handler در انتهای play یک‌بار صدا زده می‌شود.
- `meta: flush_handlers` باعث می‌شود handler همان‌جا اجرا شود، چون قدم بعدی (چک سلامت) به
  سرویسِ به‌روزشده نیاز دارد.

همین الگو در جاهای دیگر هم هست:

| کار | چرا idempotent است |
|---|---|
| `apt: name=gitlab-ce={{ نسخه }}` | اگر همان نسخه نصب است، کاری نمی‌کند |
| unarchive با `creates:` | اگر `Packages.gz` هست، دیگر ۱.۶GB را کپی نمی‌کند |
| رمز root با marker file | یک‌بار ست می‌شود، بعد از آن دست نمی‌زند |
| `timedatectl` با چک قبلی | فقط اگر timezone فرق کند |
| `ufw allow` با `changed_when` | قانون تکراری اضافه نمی‌کند |

برای دستورهای خام (`command`/`shell`) خودت باید `changed_when` و `when` بدهی، وگرنه Ansible
همیشه می‌گوید «تغییر کرد».

---

## ۷. دو حالت نصب: باندل یا میرور

```
gitlab_pkg_source: bundle                    gitlab_pkg_source: mirror
─────────────────────────────                ─────────────────────────────
tarball ۱.۶GB در offline/dist/                gitlab_apt_mirror_line در group_vars
        │                                            │
        ▼                                            ▼
/opt/gitlab-offline  (deb + Packages)         http://mirror.intra/gitlab  jammy main
        │                                            │
        └────────► deb [trusted=yes] file:…/  ◄──────┘
                         │
                  apt-cache policy → نسخه pin شده
                         │
                  apt install gitlab-ce=19.6.1
```

- **bundle** برای وقتی است که هیچ راهی به مخزن گیت‌لب نداری. sha256 هر سه deb در
  `build-bundle.sh` هاردکد است و قبل از ساخت بررسی می‌شود.
- **mirror** برای وقتی است که میرور داخلی مخزن گیت‌لب را دارد. سریع‌تر، بدون انتقال ۱.۶GB.
- در هر دو حالت، **پکیج‌های اوبونتو** (`openssh-server`, `perl`, `docker.io`, …) از میرور apt
  داخلی می‌آیند — باندل فقط debهای گیت‌لب را دارد.

تشخیص اینکه کدام را لازم داری، روی سرور هدف:

```bash
apt-cache policy gitlab-ce gitlab-runner     # Candidate واقعی = میرور دارد
```

---

## ۸. Runner و CI

Runner یک سرویس مستقل است که jobها را اجرا می‌کند. سه چیز را باید بدانی:

1. **توکن**: از GitLab 17 به بعد `registration_token` حذف شده. runner را در UI می‌سازی
   (`Admin Area > CI/CD > Runners > New instance runner`) و توکن `glrt-…` می‌گیری.
   همین توکن در `config.toml` می‌نشیند؛ دیگر `gitlab-runner register` لازم نیست.
2. **ترتیب**: اول گیت‌لب بالا بیاید، بعد runner ساخته شود، بعد نقش runner اجرا شود.
   اگر برعکس کنی، توکن وجود ندارد و assert می‌گیرد.
3. **ایمیج در محیط بسته**: `pull_policy = if-not-present` یعنی runner هیچ‌وقت از اینترنت
   نمی‌کشد. ایمیج‌ها یا باید از رجیستری داخلی بیایند (تنظیم `insecure-registries` و
   اعتبارنامه) یا از قبل با `docker load` روی runner باشند.

```
pipeline در .gitlab-ci.yml
   │
   ├─ gitlab (gitlab01) job را صف می‌کند
   ▼
runner01 ──► docker executor ──► image از رجیستری داخلی
   │
   └─ نتیجه به gitlab برمی‌گردد
```

---

## ۹. چیت‌شیت عملیات روزمره

```bash
# ── اجرا ────────────────────────────────────────────────
make syntax                  # فقط بررسی سینتکس YAML
make lint                    # ansible-lint
make render                  # رندر تمپلیت‌ها بدون تماس با سرور (تست سریع تغییرات)
make check                   # dry-run کامل با --diff
make deploy                  # اجرای همه
make gitlab                  # فقط نقش گیت‌لب
make runner                  # فقط نقش runner

# ── تغییر یک تنظیم ──────────────────────────────────────
vi inventories/prod/group_vars/gitlab.yml     # مثلاً puma_workers یا SMTP
make check && make deploy                     # فقط همان بخش changed می‌شود

# ── تغییر یک سرور ──────────────────────────────────────
vi inventories/prod/hosts.yml                 # IP یا نام هاست
make ping

# ── رازها ───────────────────────────────────────────────
make vault-edit                               # ویرایش رمزشده
make vault-encrypt                            # اگر فایل را از نو ساختی

# ── آپگرید ──────────────────────────────────────────────
# ۱) نسخه‌های جدید را در build-bundle.sh بگذار و باندل بساز (یا میرور را sync کن)
# ۲) gitlab_ce_version و gitlab_runner_version را در group_vars/all/main.yml عوض کن
# ۳) بکاپ بگیر، بعد:
make deploy

# ── عیب‌یابی روی سرور ───────────────────────────────────
gitlab-ctl status
gitlab-ctl tail
journalctl -u gitlab-runner -n 50
free -m ; df -h /var/opt/gitlab
```

---

## ۱۰. چه چیزی را کجا تغییر بدهم

| می‌خواهم… | فایل |
|---|---|
| آدرس/DNS گیت‌لب را عوض کنم | `group_vars/all/main.yml → gitlab_fqdn` |
| HTTPS با CA داخلی | `gitlab_scheme: https` + `gitlab_tls_cert/key` در `group_vars/gitlab.yml` |
| منابع را کم/زیاد کنم | `gitlab_puma_workers`, `gitlab_postgres_shared_buffers`, `gitlab_sidekiq_concurrency` |
| ایمیل (رله داخلی) | `gitlab_smtp_*` |
| کاربران از AD بیایند | `gitlab_ldap_enable: true` + `ldap_*` + رمز در vault |
| بکاپ روزانه/نگهداری | `gitlab_backup_hour/min/keep_time` |
| منبع پکیج (باندل ↔ میرور) | `gitlab_pkg_source` + `gitlab_apt_mirror_line` |
| ایمیج پیش‌فرض CI | `group_vars/runners.yml → gitlab_runner_default_image` |
| jobها بتوانند docker بسازند | `gitlab_runner_privileged: true` |
| رجیستری داخلی HTTP | `gitlab_runner_docker_insecure_registries` |
| سرور جدید اضافه کنم | `inventories/prod/hosts.yml` |

---

## ۱۱. واژه‌نامهٔ سریع

| واژه | معنی در یک خط |
|---|---|
| **Idempotent** | اجرای دوباره، وضعیت را خراب نمی‌کند |
| **Play** | یک بخش از playbook که روی یک گروه هاست اجرا می‌شود |
| **Fact** | اطلاعاتی که Ansible از سرور می‌خواند (`ansible_memtotal_mb`, `ansible_distribution`) |
| **Template** | فایل با جای‌خالی‌های Jinja2 که موقع اجرا پر می‌شود |
| **Handler** | task معوق که فقط روی تغییر اجرا می‌شود |
| **Tag** | برچسب برای اجرای بخشی از playbook (`--tags gitlab`) |
| **Vault** | رمزگذاری فایل متغیرها با یک رمز اصلی |
| **Omnibus** | پکیج همه‌چیز-در-یک گیت‌لب (nginx, postgres, redis, gitaly داخلش) |
| **glrt-** | فرمت توکن runner در GitLab 17+ |
