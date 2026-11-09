#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

detect_system() {
    [[ $EUID -ne 0 ]] && red "注意：请在root用户下运行脚本" && exit 1

    CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

    for i in "${CMD[@]}"; do
        SYS="$i"
        if [[ -n $SYS ]]; then
            break
        fi
    done

    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
        fi
    done

    [[ -z $SYSTEM ]] && red "不支持当前VPS系统, 请使用主流的操作系统" && exit 1
}

check_ip(){
    ipv4=$(curl -s4m8 https://ip.sb | sed -n 1p)
    ipv6=$(curl -s6m8 https://ip.sb | sed -n 1p)
}

inst_acme(){
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl dnsutils

    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} cronie
        systemctl start crond
        systemctl enable crond
    else
        ${PACKAGE_INSTALL[int]} cron
        systemctl start cron
        systemctl enable cron
    fi

    read -rp "请输入注册邮箱 (例: admin@gmail.com, 或留空自动生成一个gmail邮箱): " email
    if [[ -z $email ]]; then
        automail=$(date +%s%N | md5sum | cut -c 1-16)
        email=$automail@gmail.com
        yellow "已取消设置邮箱, 使用自动生成的gmail邮箱: $email"
    fi

    curl https://get.acme.sh | sh -s email=$email
    source ~/.bashrc
    bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    
    switch_provider

    if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        green "Acme.sh 证书一键申请脚本安装成功!"
    else
        red "抱歉, Acme.sh 证书一键申请脚本安装失败"
        green "建议如下："
        yellow "1. 检查 VPS 的网络环境"
        yellow "2. 脚本可能跟不上时代, 建议截图发布到 GitHub Issues 询问"
    fi
}

unst_acme() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装Acme.sh, 卸载程序无法执行!" && exit 1
    ~/.acme.sh/acme.sh --uninstall
    rm -rf ~/.acme.sh
    green "Acme.sh 证书一键申请脚本已彻底卸载!"
}

check_80(){
    # 感谢Wulabing前辈提供的检查80端口思路
    # Source: https://github.com/wulabing/Xray_onekey
    
    if [[ -z $(type -P lsof) ]]; then
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        ${PACKAGE_INSTALL[int]} lsof
    fi
    
    yellow "正在检测 80 端口是否占用..."
    sleep 1
    
    if [[  $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        green "检测到目前 80 端口未被占用"
        sleep 1
    else
        red "检测到目前 80 端口被其他程序被占用，以下为占用程序信息"
        lsof -i:"80"
        read -rp "如需结束占用进程请按Y，按其他键则退出 [Y/N]: " yn
        if [[ $yn =~ "Y"|"y" ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

restore_warp() {
    if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
        wg-quick up wgcf >/dev/null 2>&1
    fi
    if [[ -a "/opt/warp-go/warp-go" ]]; then
        systemctl start warp-go
    fi
}

clear_acme_insecure() {
    local account_conf="$HOME/.acme.sh/account.conf"

    unset HTTPS_INSECURE
    if [[ -f $account_conf ]] && grep -q '^HTTPS_INSECURE=' "$account_conf"; then
        if ! sed -i '/^HTTPS_INSECURE=/d' "$account_conf"; then
            red "无法清除 Acme.sh 的不安全 HTTPS 配置，已停止证书申请"
            return 1
        fi
    fi
}

checktls() {
    if [[ -s /root/cert.crt && -s /root/private.key ]]; then
        restore_warp

        echo "$domain" > /root/ca.log

        green "证书申请成功! 脚本申请到的证书 (cert.crt) 和私钥 (private.key) 文件已保存到 /root 文件夹下"
        yellow "证书 crt 文件路径如下: /root/cert.crt"
        yellow "私钥 key 文件路径如下: /root/private.key"
        return 0
    fi

    restore_warp
    red "抱歉，证书申请失败"
    green "建议如下: "
    yellow "1. 自行检测防火墙是否打开, 如使用 80 端口申请模式时, 请关闭防火墙或放行 80 端口"
    yellow "2. 同一域名多次申请可能会触发 Let's Encrypt 官方风控, 请尝试使用脚本菜单的 11 选项更换证书颁发机构, 再重试申请证书, 或更换域名、或等待 7 天后再尝试执行脚本"
    yellow "3. 脚本可能跟不上时代, 建议截图发布到 GitHub Issues、GitLab Issues、论坛或 TG 群询问"
    return 1
}

acme_standalone() (
    local forceIssue=0
    local warp_disabled=0
    local -a issue_args

    trap '[[ $warp_disabled -eq 1 ]] && restore_warp' EXIT

    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    check_80

    WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
    WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
    if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
        warp_disabled=1
    fi
    
    check_ip
    
    echo ""
    yellow "在使用 80 端口申请模式时, 请先将您的域名解析至你的 VPS 的真实 IP 地址, 否则会导致证书申请失败"
    echo ""
    if [[ -n $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真实 IPv4 地址为: ${GREEN}$ipv4${PLAIN}"
        echo -e "VPS 的真实 IPv6 地址为: ${GREEN}$ipv6${PLAIN}"
    elif [[ -n $ipv4 && -z $ipv6 ]]; then
        echo -e "VPS 的真实 IPv4 地址为: ${GREEN}$ipv4${PLAIN}"
    elif [[ -z $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真实 IPv6 地址为: ${GREEN}$ipv6${PLAIN}"
    fi
    echo ""

    read -rp "请输入解析完成的域名: " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
    domain="${domain,,}"
    domain="${domain%.}"
    validate_cf_domain "$domain" || return 1
    green "已输入的域名：$domain" && sleep 1

    domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | sed -n 1p)
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null | sed -n 1p)
    fi
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
        red "未解析出 IP，请检查域名是否输入有误" 
        yellow "是否尝试强行匹配？"
        green "1. 是，将使用强行匹配"
        green "2. 否，退出脚本"
        read -p "请输入选项 [1-2]：" ipChoice
        if [[ $ipChoice == 1 ]]; then
            yellow "将尝试强行匹配以申请域名证书"
            forceIssue=1
        else
            red "将退出脚本"
            exit 1
        fi
    fi

    if [[ -n $(echo $domainIP | grep nginx) ]]; then
        yellow "域名解析失败, 请检查域名是否正确填写或等待解析完成再执行脚本"
        exit 1
    elif [[ -n $(echo $domainIP | grep ":") || -n $(echo $domainIP | grep ".") ]]; then
        if [[ $domainIP != $ipv4 ]] && [[ $domainIP != $ipv6 ]]; then
            green "域名 ${domain} 目前解析的IP: ($domainIP)"
            red "当前域名解析的 IP 与当前 VPS 使用的真实IP不匹配"
            green "建议如下："
            yellow "1. 请确保 CloudFlare 小云朵为关闭状态 (仅限DNS), 其他域名解析或 CDN 网站设置同理"
            yellow "2. 请检查 DNS 解析设置的 IP 是否为 VPS 的真实 IP"
            yellow "3. 脚本可能跟不上时代, 建议截图发布到 GitHub Issues、GitLab Issues、论坛或 TG 群询问"
            exit 1
        fi
    fi

    issue_args=(--issue -d "$domain" --standalone -k ec-256)
    if [[ -n $ipv6 && $domainIP == "$ipv6" ]] || [[ $forceIssue -eq 1 && -z $ipv4 && -n $ipv6 ]]; then
        issue_args+=(--listen-v6)
    elif [[ -n $ipv4 && $domainIP == "$ipv4" ]] || [[ $forceIssue -eq 1 && -n $ipv4 ]]; then
        :
    elif [[ $forceIssue -ne 1 ]]; then
        red "域名解析结果与本机 IP 不匹配，已停止证书申请"
        return 1
    elif [[ $forceIssue -eq 1 && -z $ipv4 && -z $ipv6 ]]; then
        red "未检测到可用的 IPv4 或 IPv6 地址，已停止证书申请"
        return 1
    fi

    if ! clear_acme_insecure; then
        return 1
    fi
    if ! bash ~/.acme.sh/acme.sh "${issue_args[@]}"; then
        red "证书签发失败，已停止安装证书"
        return 1
    fi

    if ! bash ~/.acme.sh/acme.sh --install-cert -d "$domain" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc; then
        red "证书安装失败"
        return 1
    fi
    warp_disabled=0
    checktls
)

is_freenom_domain() {
    local normalized_domain="${1,,}"
    normalized_domain="${normalized_domain%.}"
    [[ $normalized_domain =~ \.(cf|ga|gq|ml|tk)$ ]]
}

validate_cf_domain() {
    local candidate="$1"
    local label
    local -a labels

    if [[ ${#candidate} -gt 253 || $candidate != *.* || $candidate == .* || $candidate == *. || $candidate == *..* || ! $candidate =~ ^[A-Za-z0-9.-]+$ ]]; then
        red "域名格式无效，请输入 ASCII 域名或 Punycode，例如 example.com"
        return 1
    fi

    IFS='.' read -r -a labels <<< "$candidate"
    for label in "${labels[@]}"; do
        if [[ -z $label || ${#label} -gt 63 || $label == -* || $label == *- ]]; then
            red "域名格式无效，请输入 ASCII 域名或 Punycode，例如 example.com"
            return 1
        fi
    done
    return 0
}

read_cf_global_credentials() {
    local cfgak
    local cfemail

    read -rsp "请输入 CloudFlare Global API Key: " cfgak
    echo ""
    [[ -z $cfgak ]] && red "未输入 CloudFlare Global API Key, 无法执行操作!" && return 1
    if [[ ! $cfgak =~ ^[A-Za-z0-9_-]+$ ]]; then
        red "CloudFlare Global API Key 格式无效"
        return 1
    fi

    read -rp "请输入 CloudFlare 的登录邮箱: " cfemail
    [[ -z $cfemail ]] && red "未输入 CloudFlare 的登录邮箱, 无法执行操作!" && return 1
    if [[ ! $cfemail =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; then
        red "CloudFlare 登录邮箱格式无效"
        return 1
    fi

    export CF_Key="$cfgak"
    export CF_Email="$cfemail"
    unset CF_Token CF_Account_ID CF_Zone_ID
}

account_has_cf_token() {
    local account_conf="$HOME/.acme.sh/account.conf"
    local line

    [[ -f $account_conf ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^(SAVED_)?CF_Token[[:space:]]*= ]]; then
            return 0
        fi
    done < "$account_conf"
    return 1
}

certificate_has_cf_token() {
    local cert_domain="$1"
    local domain_conf
    local line

    domain_conf=$(get_certificate_domain_conf "$cert_domain")
    [[ -f $domain_conf ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^(SAVED_)?CF_Token[[:space:]]*= ]]; then
            return 0
        fi
    done < "$domain_conf"
    return 1
}

read_cf_token_credentials() {
    local cftoken
    local cfzoneid

    yellow "API Token 需要 Zone / Zone / Read 和 Zone / DNS / Edit 权限，并限定到目标域名"
    read -rsp "请输入 CloudFlare API Token: " cftoken
    echo ""
    [[ -z $cftoken ]] && red "未输入 CloudFlare API Token, 无法执行操作!" && return 1
    if [[ ! $cftoken =~ ^[A-Za-z0-9_-]+$ ]]; then
        red "CloudFlare API Token 格式无效"
        return 1
    fi

    read -rp "请输入域名对应的 CloudFlare Zone ID: " cfzoneid
    [[ -z $cfzoneid ]] && red "未输入 CloudFlare Zone ID, 无法执行操作!" && return 1
    if [[ ! $cfzoneid =~ ^[[:xdigit:]]{32}$ ]]; then
        red "CloudFlare Zone ID 应为 32 位十六进制字符串"
        return 1
    fi

    export CF_Token="$cftoken"
    export CF_Zone_ID="$cfzoneid"
    unset CF_Key CF_Email CF_Account_ID
}

verify_cf_token_zone_access() {
    local target_domain="${1,,}"
    local compact_response
    local response
    local result_fields
    local zone_name

    target_domain="${target_domain%.}"

    if ! response=$(
        printf 'header = "Authorization: Bearer %s"\n' "$CF_Token" |
            curl --disable --silent --show-error --config - "https://api.cloudflare.com/client/v4/zones/$CF_Zone_ID"
    ); then
        red "无法连接 CloudFlare API 验证 Token"
        return 1
    fi

    compact_response=$(printf '%s' "$response" | tr -d '[:space:]')
    if [[ $compact_response != *'"success":true'* || $compact_response != *"\"id\":\"$CF_Zone_ID\""* ]]; then
        red "CloudFlare API Token 无效、无权读取该 Zone，或 Zone ID 不匹配"
        return 1
    fi

    result_fields=${compact_response#*'"result":{'}
    if [[ $result_fields == "$compact_response" || $result_fields != *'"name":"'* ]]; then
        red "CloudFlare API 返回内容中缺少 Zone 名称，无法验证域名归属"
        return 1
    fi
    zone_name=${result_fields#*'"name":"'}
    zone_name=${zone_name%%'"'*}
    zone_name="${zone_name,,}"
    zone_name="${zone_name%.}"
    if [[ -z $zone_name || ( $target_domain != "$zone_name" && $target_domain != *".$zone_name" ) ]]; then
        red "所填 Zone ID 对应的域名 ($zone_name) 与申请域名 ($target_domain) 不匹配"
        return 1
    fi
}

get_certificate_domain_conf() {
    local cert_domain="$1"

    bash "$HOME/.acme.sh/acme.sh" --info -d "$cert_domain" --ecc 2>/dev/null |
        sed -n 's/^DOMAIN_CONF=//p' | head -n 1
}

remove_cf_token_credentials_from_conf() {
    local domain_conf="$1"
    local line
    local tmp_conf

    [[ -f $domain_conf ]] || return 0
    tmp_conf=$(mktemp "${domain_conf}.rollback.XXXXXX") || return 1
    if ! cp -p -- "$domain_conf" "$tmp_conf"; then
        rm -f -- "$tmp_conf"
        return 1
    fi
    if ! {
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ ^(SAVED_)?CF_(Token|Zone_ID|Account_ID)[[:space:]]*= ]]; then
                continue
            fi
            printf '%s\n' "$line"
        done < "$domain_conf"
    } > "$tmp_conf"; then
        rm -f -- "$tmp_conf"
        return 1
    fi
    if ! mv -f -- "$tmp_conf" "$domain_conf"; then
        rm -f -- "$tmp_conf"
        return 1
    fi
}

rollback_cf_token_credentials() {
    local cert_domain="$1"
    local original_domain_conf="$2"
    local domain_conf_backup="$3"
    local current_domain_conf

    if [[ -n $domain_conf_backup && -f $domain_conf_backup ]]; then
        [[ -n $original_domain_conf ]] || return 1
        mv -f -- "$domain_conf_backup" "$original_domain_conf"
        return $?
    fi

    current_domain_conf=$(get_certificate_domain_conf "$cert_domain")
    if [[ -z $current_domain_conf || ! -f $current_domain_conf ]]; then
        return 0
    fi
    remove_cf_token_credentials_from_conf "$current_domain_conf"
}

restore_active_cf_token_migration() {
    if [[ ${token_migration_active:-0} -ne 1 ]]; then
        return 0
    fi

    if rollback_cf_token_credentials "$install_domain" "$original_domain_conf" "$domain_conf_backup"; then
        token_migration_active=0
        retain_domain_conf_backup=0
        domain_conf_backup=""
        return 0
    fi

    retain_domain_conf_backup=1
    return 1
}

cleanup_cf_token_migration() {
    if ! restore_active_cf_token_migration; then
        red "API Token 迁移被中断且无法自动恢复原证书配置，请勿重置旧凭据"
        [[ -n ${domain_conf_backup:-} && -f $domain_conf_backup ]] && yellow "原证书配置备份保留在: $domain_conf_backup"
    fi
    if [[ ${token_migration_active:-0} -eq 0 && ${retain_domain_conf_backup:-0} -eq 0 && -n ${domain_conf_backup:-} && -f $domain_conf_backup ]]; then
        rm -f -- "$domain_conf_backup"
    fi
    return 0
}

persist_cf_token_credentials() {
    local cert_domain="$1"
    local domain_conf
    local line
    local saved_token=0
    local saved_zone_id=0
    local tmp_conf

    domain_conf=$(get_certificate_domain_conf "$cert_domain")
    if [[ -z $domain_conf || ! -f $domain_conf ]]; then
        red "找不到证书配置文件，API Token 未能保存"
        return 1
    fi

    tmp_conf=$(mktemp "${domain_conf}.tmp.XXXXXX") || {
        red "无法创建证书配置临时文件，API Token 未能保存"
        return 1
    }

    if ! {
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ ^(SAVED_)?CF_(Token|Zone_ID|Account_ID)[[:space:]]*= ]]; then
                continue
            fi
            printf '%s\n' "$line"
        done < "$domain_conf"
        printf "CF_Token='%s'\n" "$CF_Token"
        printf "CF_Zone_ID='%s'\n" "$CF_Zone_ID"
    } > "$tmp_conf"; then
        rm -f -- "$tmp_conf"
        red "无法写入证书配置文件，API Token 未能保存"
        return 1
    fi

    if ! chmod 600 "$tmp_conf" || ! mv -f -- "$tmp_conf" "$domain_conf"; then
        rm -f -- "$tmp_conf"
        red "无法更新证书配置文件，API Token 未能保存"
        return 1
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "CF_Token='$CF_Token'" ]] && saved_token=1
        [[ $line == "CF_Zone_ID='$CF_Zone_ID'" ]] && saved_zone_id=1
    done < "$domain_conf"
    if [[ $saved_token -ne 1 || $saved_zone_id -ne 1 ]]; then
        red "证书配置校验失败，API Token 未完成迁移"
        return 1
    fi
}

issue_cf_certificate() (
    local auth_mode="$1"
    local wildcard="$2"
    local force_cf_issue
    local install_domain
    local issue_status
    local original_domain_conf=""
    local domain_conf_backup=""
    local retain_domain_conf_backup=0
    local token_migration_active=0
    local -a issue_args=(--issue --dns dns_cf)

    # dns_cf saves credentials before the DNS challenge; every uncommitted exit must roll them back.
    trap cleanup_cf_token_migration EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme
    if [[ ! -f $HOME/.acme.sh/acme.sh ]]; then
        red "未找到 Acme.sh, 无法执行操作!"
        return 1
    fi

    check_ip

    if [[ $wildcard -eq 1 ]]; then
        read -rp "请输入需要申请证书的泛域名 (输入格式：example.com): " domain
    else
        read -rp "请输入需要申请证书的域名: " domain
    fi
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && return 1
    domain="${domain,,}"
    domain="${domain%.}"
    validate_cf_domain "$domain" || return 1

    if is_freenom_domain "$domain"; then
        red "检测为 Freenom 免费域名, 由于 CloudFlare API 不支持, 故无法使用本模式申请!"
        return 1
    fi

    if [[ $wildcard -eq 1 ]]; then
        issue_args+=(-d "*.${domain}" -d "$domain")
        install_domain="*.${domain}"
    else
        issue_args+=(-d "$domain")
        install_domain="$domain"
    fi

    if [[ $auth_mode == "token" ]]; then
        read_cf_token_credentials || return 1
        verify_cf_token_zone_access "$domain" || return 1
        read -rp "如需迁移或覆盖已有证书，是否强制重新签发? [y/N]: " force_cf_issue
        [[ $force_cf_issue =~ ^[Yy]$ ]] && issue_args+=(--force)
    else
        if account_has_cf_token; then
            red "检测到 Acme.sh 账户配置中已有 API Token，为避免忽略刚输入的 Global API Key，已停止操作"
            yellow "请继续使用菜单 6/7，或先确认没有其他证书依赖账户级 CF_Token 后再手动清理冲突配置"
            return 1
        elif certificate_has_cf_token "$install_domain"; then
            red "检测到对应证书配置中已有 API Token，为避免忽略刚输入的 Global API Key，已停止操作"
            yellow "该证书已经迁移到 API Token，请继续使用菜单 6/7"
            return 1
        fi
        read_cf_global_credentials || return 1
    fi

    issue_args+=(-k ec-256)
    [[ -z $ipv4 ]] && issue_args+=(--listen-v6)

    clear_acme_insecure || return 1
    if [[ $auth_mode == "token" ]]; then
        original_domain_conf=$(get_certificate_domain_conf "$install_domain")
        if [[ -n $original_domain_conf && -f $original_domain_conf ]]; then
            domain_conf_backup=$(mktemp "${original_domain_conf}.backup.XXXXXX") || {
                red "无法备份现有证书配置，已停止 API Token 迁移"
                return 1
            }
            if ! cp -p -- "$original_domain_conf" "$domain_conf_backup"; then
                red "无法备份现有证书配置，已停止 API Token 迁移"
                return 1
            fi
            retain_domain_conf_backup=1
        fi
    fi

    [[ $auth_mode == "token" ]] && token_migration_active=1
    if bash "$HOME/.acme.sh/acme.sh" "${issue_args[@]}"; then
        issue_status=0
    else
        issue_status=$?
    fi
    if [[ $issue_status -ne 0 ]]; then
        if [[ $auth_mode == "token" ]] && ! restore_active_cf_token_migration; then
            red "签发失败且无法恢复原证书配置，请勿重置旧凭据，并立即检查对应证书配置"
            [[ -n $domain_conf_backup && -f $domain_conf_backup ]] && yellow "原证书配置备份保留在: $domain_conf_backup"
            return 1
        fi
        if [[ $auth_mode == "token" && $issue_status -eq 2 ]]; then
            red "现有证书尚未到续期时间，API Token 未完成迁移；请重新执行并确认强制签发"
            return 1
        elif [[ $auth_mode == "global" && $issue_status -eq 2 ]]; then
            yellow "现有证书尚未到续期时间，将从 Acme.sh 缓存重新安装证书"
        else
            red "CloudFlare DNS 验证或证书签发失败，已停止安装证书"
            return 1
        fi
    fi

    if [[ $auth_mode == "token" ]]; then
        if ! persist_cf_token_credentials "$install_domain"; then
            if ! restore_active_cf_token_migration; then
                red "API Token 保存失败且无法恢复原证书配置，请勿重置旧凭据，并立即检查对应证书配置"
                [[ -n $domain_conf_backup && -f $domain_conf_backup ]] && yellow "原证书配置备份保留在: $domain_conf_backup"
            fi
            return 1
        fi
        token_migration_active=0
        retain_domain_conf_backup=0
        [[ -n $domain_conf_backup && -f $domain_conf_backup ]] && rm -f -- "$domain_conf_backup"
        domain_conf_backup=""
    fi

    if ! bash "$HOME/.acme.sh/acme.sh" --install-cert -d "$install_domain" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc; then
        red "证书安装失败"
        return 1
    fi

    checktls
)

acme_cfapiTLD(){
    issue_cf_certificate "global" 0
}

acme_cfapiNTLD(){
    issue_cf_certificate "global" 1
}

acme_cftokenTLD(){
    issue_cf_certificate "token" 0
}

acme_cftokenNTLD(){
    issue_cf_certificate "token" 1
}

view_cert(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme
    bash ~/.acme.sh/acme.sh --list
}

revoke_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    bash ~/.acme.sh/acme.sh --list
    read -rp "请输入要撤销的域名证书 (复制 Main_Domain 下显示的域名): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作!" && exit 1

    if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $domain) ]]; then
        bash ~/.acme.sh/acme.sh --revoke -d ${domain} --ecc
        bash ~/.acme.sh/acme.sh --remove -d ${domain} --ecc

        rm -rf ~/.acme.sh/${domain}_ecc
        rm -f /root/cert.crt /root/private.key

        green "撤销 ${domain} 的域名证书成功"
    else
        red "未找到 ${domain} 的域名证书, 请检查后重新运行!"
    fi
}

renew_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh, 无法执行操作!" && exit 1
    bash ~/.acme.sh/acme.sh --cron -f
}

switch_provider(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    yellow "请选择证书提供商, 默认通过 Letsencrypt.org 来申请证书 "
    yellow "如果证书申请失败, 例如一天内通过 Letsencrypt.org 申请次数过多, 可选 BuyPass.com 或 ZeroSSL.com 来申请."
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org ${YELLOW}(默认)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com"
    read -rp "请选择证书提供商 [1-3]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && green "切换证书提供商为 BuyPass.com 成功！" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && green "切换证书提供商为 ZeroSSL.com 成功！" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && green "切换证书提供商为 Letsencrypt.org 成功！" ;;
    esac
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                   ${RED}Acme  证书一键申请脚本${PLAIN}                  #"
    echo -e "# ${GREEN}作者${PLAIN}: MisakaNo の 小破站                                  #"
    echo -e "# ${GREEN}博客${PLAIN}: https://blog.misaka.rest                            #"
    echo -e "# ${GREEN}GitHub 项目${PLAIN}: https://github.com/Misaka-blog               #"
    echo -e "# ${GREEN}GitLab 项目${PLAIN}: https://gitlab.com/Misaka-blog               #"
    echo -e "# ${GREEN}Telegram 频道${PLAIN}: https://t.me/misakanocchannel              #"
    echo -e "# ${GREEN}Telegram 群组${PLAIN}: https://t.me/misakanoc                     #"
    echo -e "# ${GREEN}YouTube 频道${PLAIN}: https://www.youtube.com/@misaka-blog        #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 Acme.sh 域名证书申请脚本"
    echo -e " ${GREEN}2.${PLAIN} ${RED}卸载 Acme.sh 域名证书申请脚本${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} 申请单域名证书 ${YELLOW}(80端口申请)${PLAIN}"
    echo -e " ${GREEN}4.${PLAIN} 申请单域名证书 ${YELLOW}(CF Global API Key)${PLAIN} ${GREEN}(无需解析)${PLAIN} ${RED}(不推荐)${PLAIN}"
    echo -e " ${GREEN}5.${PLAIN} 申请泛域名证书 ${YELLOW}(CF Global API Key)${PLAIN} ${GREEN}(无需解析)${PLAIN} ${RED}(不推荐)${PLAIN}"
    echo -e " ${GREEN}6.${PLAIN} 申请单域名证书 ${YELLOW}(CF API Token)${PLAIN} ${GREEN}(无需解析，推荐)${PLAIN}"
    echo -e " ${GREEN}7.${PLAIN} 申请泛域名证书 ${YELLOW}(CF API Token)${PLAIN} ${GREEN}(无需解析，推荐)${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}8.${PLAIN} 查看已申请的证书"
    echo -e " ${GREEN}9.${PLAIN} 撤销并删除已申请的证书"
    echo -e " ${GREEN}10.${PLAIN} 手动续期已申请的证书"
    echo -e " ${GREEN}11.${PLAIN} 切换证书颁发机构"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -rp "请输入选项 [0-11]: " menuInput
    case "$menuInput" in
        1 ) inst_acme ;;
        2 ) unst_acme ;;
        3 ) acme_standalone ;;
        4 ) acme_cfapiTLD ;;
        5 ) acme_cfapiNTLD ;;
        6 ) acme_cftokenTLD ;;
        7 ) acme_cftokenNTLD ;;
        8 ) view_cert ;;
        9 ) revoke_cert ;;
        10 ) renew_cert ;;
        11 ) switch_provider ;;
        * ) exit 1 ;;
    esac
}

main() {
    detect_system
    menu
}

if [[ ${BASH_SOURCE[0]:-} == "$0" || -z ${BASH_SOURCE[0]:-} ]]; then
    main "$@"
fi
