#!/bin/sh
# src/shield-domains.txt.gz: the ad, tracker, fingerprinting and mining
# domains built into Iris (the shield until uBlock's and EasyList's lists are
# fetched, and at the ultra level on top of them). Everything comes from
# GitHub over git, so it works where only github.com is reachable:
#   hagezi/dns-blocklists  wildcard/pro.mini-onlydomains.txt   GPL-3.0
#   StevenBlack/hosts      hosts (unified ads + malware)       MIT
#   uBlockOrigin/uAssets   EasyList, EasyPrivacy, uBlock filters, privacy,
#                          badware and resource-abuse: their "||domain^"
#                          rules with no options or only $third-party
#                          GPL-3.0 / CC BY-SA 3.0
#   below: fingerprinting and in-page mining services lists sometimes miss
# Then: lower case, only host characters, never Google's or YouTube's own
# hosts (the shield leaves them to youtube.js and to the lists' own rules),
# never sign-in or messaging hosts, and no subdomain of a domain already in.
#   sh tools/shield-domains.sh            writes src/shield-domains.txt.gz
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sparse() { # repo branch dir paths...
	repo=$1 branch=$2 dir=$3
	shift 3
	git clone -q --depth 1 --filter=blob:none --sparse --branch "$branch" "https://github.com/$repo" "$tmp/$dir"
	git -C "$tmp/$dir" sparse-checkout set --no-cone "$@"
}
sparse hagezi/dns-blocklists main hz /wildcard/pro.mini-onlydomains.txt
sparse StevenBlack/hosts master sb /hosts
sparse uBlockOrigin/uAssets gh-pages ua /thirdparties/easylist.txt /thirdparties/easyprivacy.txt \
	/filters/filters.min.txt /filters/privacy.min.txt /filters/badware.min.txt /filters/resource-abuse.txt

{
	grep -v '^#' "$tmp/hz/wildcard/pro.mini-onlydomains.txt"
	awk '$1 == "0.0.0.0" && NF >= 2 { print $2 }' "$tmp/sb/hosts"
	cat "$tmp/ua/thirdparties/easylist.txt" "$tmp/ua/thirdparties/easyprivacy.txt" "$tmp/ua/filters/"*.txt |
		sed -n 's/^||\([A-Za-z0-9._-]*\)\^\(\$third-party\|\$3p\)\{0,1\}\r\{0,1\}$/\1/p'
	cat <<-'EOF'
	fpjs.io
	fpcdn.io
	fpnpmcdn.net
	fpjscdn.net
	openfpcdn.io
	fingerprintjs.com
	iesnare.com
	iovation.com
	online-metrix.net
	threatmetrix.com
	deviceident.com
	h-cdn.com
	coinhive.com
	coin-hive.com
	authedmine.com
	crypto-loot.com
	cryptoloot.pro
	webminepool.com
	coinimp.com
	minero.cc
	jsecoin.com
	monerominer.rocks
	webmine.cz
	EOF
} | tr 'A-Z' 'a-z' | tr -d '\r' | grep -E '^[a-z0-9_-]+(\.[a-z0-9_-]+)+$' | grep -vE '^[0-9.]+$' |
	grep -vE '(^|\.)(google\.com|gstatic\.com|googleapis\.com|googlevideo\.com|youtube\.com|youtube-nocookie\.com|ytimg\.com|ggpht\.com|googleusercontent\.com|accounts\.google\.[a-z.]+|whatsapp\.(com|net)|microsoftonline\.com|live\.com|apple\.com|cloudflare\.com|hcaptcha\.com|recaptcha\.net|github\.com|githubusercontent\.com|localhost|local)$' |
	# parents before children: sort on the name read backwards, keep a
	# name only when no kept name is a parent of it
	awk -F. '{ r = $NF; for (i = NF - 1; i >= 1; i--) r = r "." $i; print r "\t" $0 }' | LC_ALL=C sort -u -t "	" -k1,1 |
	awk -F'\t' '{ if (keep != "" && index($1, keep ".") == 1) next; keep = $1; print $2 }' |
	LC_ALL=C sort -u | gzip -9n > "$tmp/out.gz"
mv "$tmp/out.gz" "$here/src/shield-domains.txt.gz"
printf '%s domains, %s bytes\n' "$(gzip -dc "$here/src/shield-domains.txt.gz" | wc -l)" "$(wc -c < "$here/src/shield-domains.txt.gz")"
