#!/bin/sh
# Makes the apt and dnf repositories served from GitHub Pages:
#   update-repo.sh <folder with the .deb and .rpm> <output folder> <flat folder>
# The packages themselves stay on the GitHub release (they carry Chromium,
# and Pages keeps no file over 100 MB):
#   dnf: the repository's index on Pages points at the release's files
#        (xml:base, the release tag in TAG); the .rpm is signed in place in
#        <folder with the .rpm>, so the release gets the signed one.
#   apt: a flat repository made of release files (Packages, Release,
#        InRelease), written to <flat folder> and uploaded with the release;
#        sources point at releases/latest/download. The old apt address on
#        Pages stays valid and empty, and the package moves its users over.
# With the secret REPO_GPG_KEY (an armored private key, no passphrase) the
# repositories and packages are signed and the key is published beside them;
# without it the repositories are unsigned (the files still come over HTTPS).
set -eu
in=$1
out=$2
flat=$3
URL=${PAGES_URL:-https://tulip-labs.github.io/Iris-Browser}
REL=${RELEASE_URL:-https://github.com/Tulip-Labs/Iris-Browser/releases}
: "${TAG:?TAG is the release tag}"
rm -rf "$out" "$flat"
mkdir -p "$out/deb/pool/main" "$out/rpm" "$flat"
cp "$in"/*.deb "$flat/"

signed=0
if [ -n "${REPO_GPG_KEY:-}" ]; then
	export GNUPGHOME
	GNUPGHOME=$(mktemp -d)
	printf '%s\n' "$REPO_GPG_KEY" | gpg --batch --import
	KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/ {print $5; exit}')
	gpg --armor --export "$KEYID" > "$out/lite-go-browser.asc"
	gpg --export "$KEYID" > "$out/lite-go-browser.gpg"
	signed=1
fi

# apt (old address): one suite, one component, no packages
(
	cd "$out/deb"
	for arch in amd64 arm64; do
		mkdir -p "dists/stable/main/binary-$arch"
		: > "dists/stable/main/binary-$arch/Packages"
		gzip -9kf "dists/stable/main/binary-$arch/Packages"
	done
	apt-ftparchive -o APT::FTPArchive::Release::Origin="Tulip Labs" -o APT::FTPArchive::Release::Label="Lite Go" \
		-o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
		-o APT::FTPArchive::Release::Architectures="amd64 arm64" -o APT::FTPArchive::Release::Components=main \
		release dists/stable > dists/stable/Release
	if [ $signed = 1 ]; then
		gpg --batch --yes --default-key "$KEYID" --clearsign -o dists/stable/InRelease dists/stable/Release
		gpg --batch --yes --default-key "$KEYID" -abs -o dists/stable/Release.gpg dists/stable/Release
	fi
)

# apt: the flat repository, from the release's files
(
	cd "$flat"
	# sources: deb <releases>/latest download/  (so download/<file> is a release file)
	dpkg-scanpackages --multiversion . | sed 's#^Filename: \./#Filename: download/#' > Packages
	rm -f ./*.deb
	gzip -9kf Packages
	apt-ftparchive -o APT::FTPArchive::Release::Origin="Tulip Labs" -o APT::FTPArchive::Release::Label="Lite Go" \
		release . > Release
	if [ $signed = 1 ]; then
		gpg --batch --yes --default-key "$KEYID" --clearsign -o InRelease Release
		gpg --batch --yes --default-key "$KEYID" -abs -o Release.gpg Release
	fi
)

# dnf / zypper
if [ $signed = 1 ]; then
	echo "%_gpg_name $KEYID" > ~/.rpmmacros
	rpm --addsign "$in"/*.rpm
fi
cp "$in"/*.rpm "$out/rpm/"
createrepo_c -q --baseurl "$REL/download/$TAG/" "$out/rpm"
rm -f "$out"/rpm/*.rpm
if [ $signed = 1 ]; then
	gpg --batch --yes --default-key "$KEYID" --detach-sign --armor "$out/rpm/repodata/repomd.xml"
	check="gpgcheck=1
repo_gpgcheck=1
gpgkey=$URL/lite-go-browser.asc"
	apt_line="deb [signed-by=/usr/share/keyrings/lite-go-browser.gpg] $REL/latest download/"
	apt_setup="curl -fsSL $URL/lite-go-browser.gpg | sudo tee /usr/share/keyrings/lite-go-browser.gpg >/dev/null
echo \"$apt_line\" | sudo tee /etc/apt/sources.list.d/lite-go-browser.list"
else
	check="gpgcheck=0
repo_gpgcheck=0"
	apt_line="deb [trusted=yes] $REL/latest download/"
	apt_setup="echo \"$apt_line\" | sudo tee /etc/apt/sources.list.d/lite-go-browser.list"
fi
cat > "$out/rpm/lite-go-browser.repo" <<REPO
[lite-go-browser]
name=Lite Go
baseurl=$URL/rpm
enabled=1
metadata_expire=1h
$check
REPO
cp "$out/rpm/lite-go-browser.repo" "$out/lite-go-browser.repo"

cat > "$out/index.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lite Go packages</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;color:#241f4e;background:#fdfaf3}
pre{background:#f1ecfb;padding:.8rem 1rem;border-radius:10px;overflow-x:auto}h1{font-size:1.6rem}</style></head><body>
<h1>Lite Go for Linux</h1>
<p>Packages for Lite Go, the light browser by Tulip Labs. Downloads and source:
<a href="https://github.com/Tulip-Labs/Iris-Browser/releases">GitHub releases</a>.</p>
<h2>Debian, Ubuntu, Linux Mint</h2>
<pre>$apt_setup
sudo apt update && sudo apt install lite-go-browser</pre>
<h2>Fedora</h2>
<pre>sudo dnf config-manager addrepo --from-repofile=$URL/lite-go-browser.repo
sudo dnf install lite-go-browser</pre>
<h2>openSUSE</h2>
<pre>sudo zypper addrepo $URL/lite-go-browser.repo
sudo zypper install lite-go-browser</pre>
<h2>Fedora Atomic (Silverblue, Kinoite)</h2>
<pre>sudo curl -fsSLo /etc/yum.repos.d/lite-go-browser.repo $URL/lite-go-browser.repo
rpm-ostree install lite-go-browser</pre>
</body></html>
HTML
touch "$out/.nojekyll"
find "$out" -maxdepth 3 | sort
