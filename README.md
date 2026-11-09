# acme-script

acme.sh 证书一键申请脚本

```shell
wget -N https://raw.githubusercontent.com/KamiyamaShiki-SAMA/acme-script/main/acme.sh && bash acme.sh
```

## Cloudflare API Token（推荐）

菜单 6、7 使用 Cloudflare API Token 申请单域名或泛域名证书。脚本实际调用的是 `acme.sh` 的 `dns_cf` 接口，因此需要填写：

- Cloudflare API Token
- 域名 Overview 页面右侧显示的 Zone ID

创建 API Token 时，请授予以下权限，并将 Zone Resources 限定到证书域名所在的 DNS Zone。例如，证书域名是 `host.example.com` 时，通常应选择 `example.com` 这个 Zone：

- `Zone / Zone / Read`
- `Zone / DNS / Edit`

域名输入仅接受 ASCII DNS 名称；国际化域名请先转换为 Punycode 后再填写。

API Token 和 Zone ID 会由 acme.sh 保存在对应证书的 `/root/.acme.sh/*_ecc/*.conf` 中，以便定时任务自动续期。自动续期使用 acme.sh 安装时创建的调度任务，本脚本不会改写系统 `/etc/crontab`。请勿分享这些配置文件，并确保只有 root 可以读取。

签发前脚本会通过 Cloudflare API 验证 Token 能读取所填 Zone，并确认该 Zone 属于申请域名；`Zone / DNS / Edit` 权限会在 CA 要求新的 DNS challenge 时实际使用。CA 有时会复用尚未过期的授权，因此脚本也会在签发成功后独立确认 Token 和 Zone ID 已写入对应证书配置。若签发或凭据保存失败，脚本会恢复原证书配置，避免一次失败的迁移破坏后续自动续期。

菜单 4、5 仅用于兼容尚未迁移的 Global API Key 旧配置，不推荐继续使用。菜单 6、7 会询问是否强制重新签发：申请新证书时保留默认的 `N`；从 Global API Key 迁移已有证书时输入 `y`，确保跳过本地续期时间检查并保存 API Token。强制签发会消耗 CA 限额，请勿连续重复执行。

同一张证书迁移到 API Token 后，请继续使用菜单 6、7。acme.sh 会优先读取该证书已经保存的 Token；菜单 4、5 检测到证书级 Token 后会拒绝继续，避免表面输入 Global API Key、实际仍使用旧 Token。

如果 `/root/.acme.sh/account.conf` 中存在账户级 `CF_Token`，菜单 4、5 同样会拒绝继续，防止 acme.sh 忽略新输入的 Global API Key。不要直接删除该 Token；它可能仍被其他证书使用。

迁移已有证书后，可以用下面的命令确认对应证书配置已经同时保存 Token 和 Zone ID，并检查配置文件权限。这些命令不会显示 Token 内容；前两条应显示同一个证书配置，最后一条应无输出：

```shell
grep -RIl -E '^(SAVED_)?CF_Token=' /root/.acme.sh/*_ecc/*.conf
grep -RIl -E '^(SAVED_)?CF_Zone_ID=' /root/.acme.sh/*_ecc/*.conf
find /root/.acme.sh -path '*_ecc/*.conf' -perm /077 -print
```

确认所有 Cloudflare 证书均已改用 API Token 后，可以备份配置并删除旧 Global API Key。备份中仍包含敏感凭据，因此必须保持仅 root 可读，并在验证完成后删除：

```shell
install -m 600 /root/.acme.sh/account.conf /root/account.conf.migration.bak
sed -i -e '/^SAVED_CF_Key=/d' -e '/^SAVED_CF_Email=/d' -e '/^CF_Key=/d' -e '/^CF_Email=/d' /root/.acme.sh/account.conf
chmod 600 /root/.acme.sh/account.conf
```

完成续期验证后删除包含旧凭据的临时备份，并在 Cloudflare 控制台重置 Global API Key，使服务器上曾经保存过的旧 Key 正式失效。Global API Key 是账号级凭据，重置前必须确认其他服务器或自动化任务已经完成迁移，否则它们会同时失效：

```shell
rm -f /root/account.conf.migration.bak
```

在确认迁移成功前不要执行清理、删除备份或重置 Key，否则仍依赖 Global API Key 的旧证书可能无法自动续期。

## 赞助

爱发电：https://afdian.net/a/Misaka-blog

![afdian-MisakaNo の 小破站](https://user-images.githubusercontent.com/122191366/211533469-351009fb-9ae8-4601-992a-abbf54665b68.jpg)
