#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_PATH="$ROOT_DIR/acme.sh"
TMP_DIR=$(mktemp -d)
MOCK_LOG="$TMP_DIR/acme-calls.log"
MOCK_DOMAIN_CONF="$TMP_DIR/example.com.conf"

trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local content="$1"
    local expected="$2"
    grep -Fq -- "$expected" <<< "$content" || fail "missing: $expected"
}

assert_not_contains() {
    local content="$1"
    local unexpected="$2"
    if grep -Fq -- "$unexpected" <<< "$content"; then
        fail "unexpected content: $unexpected"
    fi
}

assert_log_contains() {
    grep -Fq -- "$1" "$MOCK_LOG" || fail "log missing: $1"
}

assert_log_line() {
    grep -Fxq -- "$1" "$MOCK_LOG" || fail "exact log line missing: $1"
}

assert_log_not_contains() {
    if grep -Fq -- "$1" "$MOCK_LOG"; then
        fail "log contains: $1"
    fi
}

assert_log_variable_empty() {
    local name="$1"
    if grep -Eq "^${name}=.+$" "$MOCK_LOG"; then
        fail "$name was not empty"
    fi
}

# Loading the script must not run root/platform checks or open the menu.
source "$SCRIPT_PATH"

HOME="$TMP_DIR/home"
mkdir -p "$HOME/.acme.sh"
touch "$HOME/.acme.sh/acme.sh"
printf "Le_Domain='example.com'\n" > "$MOCK_DOMAIN_CONF"

printf "OTHER_SETTING='kept'\nHTTPS_INSECURE='1'\n" > "$HOME/.acme.sh/account.conf"
clear_acme_insecure
grep -Fq "OTHER_SETTING='kept'" "$HOME/.acme.sh/account.conf" || fail "unrelated account setting removed"
if grep -Fq 'HTTPS_INSECURE=' "$HOME/.acme.sh/account.conf"; then
    fail "HTTPS_INSECURE was not removed"
fi

inst_acme() {
    return 0
}

check_ip() {
    ipv4="${MOCK_IPV4-203.0.113.10}"
    ipv6="${MOCK_IPV6-}"
}

checktls() {
    return 0
}

clear_acme_insecure() {
    return 0
}

curl() {
    [[ ${1-} == "--disable" ]] || fail "Cloudflare verification did not disable .curlrc"
    cat >/dev/null
    if [[ ${MOCK_CF_API_FAIL:-0} -eq 1 ]]; then
        return 22
    fi
    printf '{"success":true,"result":{"id":"%s","name":"%s"}}\n' \
        "$CF_Zone_ID" "${MOCK_CF_ZONE_NAME-example.com}"
}

bash() {
    local target="$1"
    shift

    if [[ $target != "$HOME/.acme.sh/acme.sh" ]]; then
        command bash "$target" "$@"
        return $?
    fi

    if [[ ${1-} == "--info" ]]; then
        printf 'DOMAIN_CONF=%s\n' "$MOCK_DOMAIN_CONF"
        return 0
    fi

    {
        printf 'CALL\n'
        printf 'TOKEN=%s\n' "${CF_Token-}"
        printf 'ZONE=%s\n' "${CF_Zone_ID-}"
        printf 'KEY=%s\n' "${CF_Key-}"
        printf 'EMAIL=%s\n' "${CF_Email-}"
        printf 'ARG=%s\n' "$@"
    } >> "$MOCK_LOG"

    if [[ ${MOCK_PROVIDER_WRITES_CONF:-0} -eq 1 && ${1-} == "--issue" && -n ${CF_Token-} ]]; then
        printf "Le_Domain='example.com'\nCF_Token='provider-token'\nCF_Zone_ID='%s'\n" \
            "$CF_Zone_ID" > "$MOCK_DOMAIN_CONF"
    fi

    if [[ ${MOCK_ISSUE_STATUS:-0} -ne 0 && ${1-} == "--issue" ]]; then
        return "$MOCK_ISSUE_STATUS"
    fi
    return 0
}

assert_rejected_without_acme() {
    local auth_mode="$1"
    local wildcard="$2"
    local input="$3"
    local label="$4"

    : > "$MOCK_LOG"
    if issue_cf_certificate "$auth_mode" "$wildcard" <<< "$input" >/dev/null 2>&1; then
        fail "$label was accepted"
    fi
    [[ ! -s $MOCK_LOG ]] || fail "acme.sh was called for $label"
}

unset CF_Token CF_Zone_ID CF_Key CF_Email CF_Account_ID
: > "$MOCK_LOG"
token_output=$(issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn')
assert_not_contains "$token_output" "token-secret"
assert_log_line 'TOKEN=token-secret'
assert_log_line 'ZONE=0123456789abcdef0123456789abcdef'
assert_log_variable_empty 'KEY'
assert_log_variable_empty 'EMAIL'
assert_log_contains 'ARG=--issue'
assert_log_contains 'ARG=dns_cf'
assert_log_contains 'ARG=example.com'
assert_log_not_contains 'ARG=--insecure'
assert_log_not_contains 'ARG=--force'
grep -Fxq "CF_Token='token-secret'" "$MOCK_DOMAIN_CONF" || fail "API Token was not persisted"
grep -Fxq "CF_Zone_ID='0123456789abcdef0123456789abcdef'" "$MOCK_DOMAIN_CONF" || fail "Zone ID was not persisted"
[[ -z ${CF_Token+x} ]] || fail "token escaped the signing subshell"

: > "$MOCK_LOG"
printf "Le_Domain='example.com'\n" > "$MOCK_DOMAIN_CONF"
global_output=$(issue_cf_certificate "global" 0 <<< $'example.com\nglobal-secret\nadmin@example.com')
assert_not_contains "$global_output" "global-secret"
assert_log_variable_empty 'TOKEN'
assert_log_variable_empty 'ZONE'
assert_log_line 'KEY=global-secret'
assert_log_line 'EMAIL=admin@example.com'

: > "$MOCK_LOG"
issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\ny' >/dev/null
assert_log_contains 'ARG=--force'

: > "$MOCK_LOG"
MOCK_IPV4=""
MOCK_IPV6="2001:db8::10"
issue_cf_certificate "token" 1 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null
assert_log_contains 'ARG=*.example.com'
assert_log_contains 'ARG=example.com'
assert_log_contains 'ARG=--listen-v6'
unset MOCK_IPV4 MOCK_IPV6

assert_rejected_without_acme "token" 0 $'\n' "an empty domain"
assert_rejected_without_acme "token" 0 $'example.com\n\n' "an empty API Token"
assert_rejected_without_acme "token" 0 $'example.com\ninvalid.token\n' "an invalid API Token"
assert_rejected_without_acme "token" 0 $'example.com\ntoken-secret\n\n' "an empty Zone ID"
assert_rejected_without_acme "global" 0 $'example.com\n\n' "an empty Global API Key"
assert_rejected_without_acme "global" 0 $'example.com\nglobal-secret\n\n' "an empty Cloudflare email"
assert_rejected_without_acme "token" 0 $'../../example.com' "a path-like domain"
assert_rejected_without_acme "token" 0 $'example.com;touch-pwned' "a shell-like domain"
assert_rejected_without_acme "global" 0 $'example.com\nbad\047key' "an unsafe Global API Key"
assert_rejected_without_acme "global" 0 $'example.com\nglobal-secret\nbad\047mail@example.com' "an unsafe Cloudflare email"

: > "$MOCK_LOG"
MOCK_CF_API_FAIL=1
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null 2>&1; then
    fail "an unreachable Cloudflare API was accepted"
fi
[[ ! -s $MOCK_LOG ]] || fail "acme.sh was called before Cloudflare Token verification"
unset MOCK_CF_API_FAIL

: > "$MOCK_LOG"
MOCK_CF_ZONE_NAME="other.example"
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null 2>&1; then
    fail "a readable Zone belonging to another domain was accepted"
fi
[[ ! -s $MOCK_LOG ]] || fail "acme.sh was called for a mismatched Zone"
unset MOCK_CF_ZONE_NAME

: > "$MOCK_LOG"
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\ninvalid-zone-id' >/dev/null 2>&1; then
    fail "invalid Zone ID was accepted"
fi
[[ ! -s $MOCK_LOG ]] || fail "acme.sh was called for an invalid Zone ID"

: > "$MOCK_LOG"
if issue_cf_certificate "token" 1 <<< $'*.example.com' >/dev/null 2>&1; then
    fail "wildcard prefix was accepted as a base domain"
fi
[[ ! -s $MOCK_LOG ]] || fail "acme.sh was called for an invalid wildcard input"

: > "$MOCK_LOG"
original_conf_content=$'Le_Domain=\'example.com\'\nCF_Key=\'old-global-key\'\nCUSTOM_SETTING=\'preserved\''
printf '%s\n' "$original_conf_content" > "$MOCK_DOMAIN_CONF"
MOCK_PROVIDER_WRITES_CONF=1
MOCK_ISSUE_STATUS=1
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null 2>&1; then
    fail "failed issuance returned success"
fi
[[ $(grep -c '^CALL$' "$MOCK_LOG") -eq 1 ]] || fail "install-cert ran after failed issuance"
[[ $(<"$MOCK_DOMAIN_CONF") == "$original_conf_content" ]] || fail "failed Token migration did not restore the original certificate config"
unset MOCK_ISSUE_STATUS MOCK_PROVIDER_WRITES_CONF

: > "$MOCK_LOG"
printf '%s\n' "$original_conf_content" > "$MOCK_DOMAIN_CONF"
original_persist_definition=$(declare -f persist_cf_token_credentials)
persist_cf_token_credentials() {
    exit 99
}
MOCK_PROVIDER_WRITES_CONF=1
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null 2>&1; then
    fail "an interrupted Token migration returned success"
fi
[[ $(<"$MOCK_DOMAIN_CONF") == "$original_conf_content" ]] || fail "EXIT cleanup did not restore the original certificate config"
eval "$original_persist_definition"
unset MOCK_PROVIDER_WRITES_CONF original_persist_definition

mv "$MOCK_DOMAIN_CONF" "$MOCK_DOMAIN_CONF.bak"
: > "$MOCK_LOG"
MOCK_PROVIDER_WRITES_CONF=1
MOCK_ISSUE_STATUS=1
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null 2>&1; then
    fail "failed first-time issuance returned success"
fi
if [[ -f $MOCK_DOMAIN_CONF ]]; then
    grep -Eq '^(SAVED_)?CF_(Token|Zone_ID|Account_ID)=' "$MOCK_DOMAIN_CONF" && \
        fail "failed first-time issuance left Token credentials behind"
fi
rm -f -- "$MOCK_DOMAIN_CONF"
mv "$MOCK_DOMAIN_CONF.bak" "$MOCK_DOMAIN_CONF"
unset MOCK_ISSUE_STATUS MOCK_PROVIDER_WRITES_CONF

: > "$MOCK_LOG"
MOCK_ISSUE_STATUS=2
if skip_output=$(issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn'); then
    fail "skipped issuance returned success"
fi
assert_contains "$skip_output" 'API Token 未完成迁移'
[[ $(grep -c '^CALL$' "$MOCK_LOG") -eq 1 ]] || fail "install-cert ran after skipped issuance"
unset MOCK_ISSUE_STATUS

: > "$MOCK_LOG"
MOCK_ISSUE_STATUS=2
global_skip_output=$(issue_cf_certificate "global" 0 <<< $'example.com\nglobal-secret\nadmin@example.com')
assert_contains "$global_skip_output" '从 Acme.sh 缓存重新安装证书'
[[ $(grep -c '^CALL$' "$MOCK_LOG") -eq 2 ]] || fail "cached Global certificate was not installed after renewal skip"
unset MOCK_ISSUE_STATUS

: > "$MOCK_LOG"
printf "OTHER_SETTING='kept'\nSAVED_CF_Token='stale-token'\n" > "$HOME/.acme.sh/account.conf"
if conflict_output=$(issue_cf_certificate "global" 0 <<< $'example.com'); then
    fail "Global API Key mode ignored an account-level Token conflict"
fi
assert_contains "$conflict_output" '账户配置中已有 API Token'
[[ ! -s $MOCK_LOG ]] || fail "acme.sh was called despite an account-level Token conflict"
printf "OTHER_SETTING='kept'\n" > "$HOME/.acme.sh/account.conf"

: > "$MOCK_LOG"
printf "Le_Domain='example.com'\nCF_Token='certificate-token'\n" > "$MOCK_DOMAIN_CONF"
if conflict_output=$(issue_cf_certificate "global" 0 <<< $'example.com'); then
    fail "Global API Key mode ignored a certificate-level Token conflict"
fi
assert_contains "$conflict_output" '对应证书配置中已有 API Token'
[[ ! -s $MOCK_LOG ]] || fail "acme.sh was called despite a certificate-level Token conflict"
printf "Le_Domain='example.com'\n" > "$MOCK_DOMAIN_CONF"

mv "$MOCK_DOMAIN_CONF" "$MOCK_DOMAIN_CONF.bak"
: > "$MOCK_LOG"
if issue_cf_certificate "token" 0 <<< $'example.com\ntoken-secret\n0123456789abcdef0123456789abcdef\nn' >/dev/null 2>&1; then
    fail "Token issuance succeeded without persisting certificate credentials"
fi
[[ $(grep -c '^CALL$' "$MOCK_LOG") -eq 1 ]] || fail "install-cert ran after credential persistence failed"
mv "$MOCK_DOMAIN_CONF.bak" "$MOCK_DOMAIN_CONF"

check_80() {
    return 0
}

curl() {
    printf 'warp=on\n'
}

wg-quick() {
    return 0
}

systemctl() {
    return 0
}

restore_warp() {
    printf 'RESTORE\n' >> "$MOCK_LOG"
}

: > "$MOCK_LOG"
if acme_standalone <<< '' >/dev/null 2>&1; then
    fail "standalone accepted an empty domain"
fi
[[ $(grep -c '^RESTORE$' "$MOCK_LOG") -eq 1 ]] || fail "WARP was not restored exactly once after early exit"

: > "$MOCK_LOG"
if acme_standalone <<< $'example.com\047;touch-pwned' >/dev/null 2>&1; then
    fail "standalone accepted an unsafe domain"
fi
[[ $(grep -c '^RESTORE$' "$MOCK_LOG") -eq 1 ]] || fail "WARP was not restored after rejecting an unsafe domain"

menu_source=$(sed -n '/^menu() {/,/^}/p' "$SCRIPT_PATH")
checktls_source=$(sed -n '/^checktls() {/,/^}/p' "$SCRIPT_PATH")
assert_contains "$menu_source" '4 ) acme_cfapiTLD ;;'
assert_contains "$menu_source" '5 ) acme_cfapiNTLD ;;'
assert_contains "$menu_source" '6 ) acme_cftokenTLD ;;'
assert_contains "$menu_source" '7 ) acme_cftokenNTLD ;;'
assert_contains "$menu_source" '8 ) view_cert ;;'
assert_contains "$menu_source" '9 ) revoke_cert ;;'
assert_contains "$menu_source" '10 ) renew_cert ;;'
assert_contains "$menu_source" '11 ) switch_provider ;;'
assert_contains "$menu_source" 'CF Global API Key'
assert_contains "$menu_source" 'CF API Token'
assert_contains "$menu_source" '请输入选项 [0-11]'
assert_not_contains "$(<"$SCRIPT_PATH")" '--insecure'
assert_not_contains "$checktls_source" '/etc/crontab'
assert_not_contains "$(<"$SCRIPT_PATH")" 'back2menu'

printf 'All Cloudflare flow tests passed.\n'
