package ext

import (
	"archive/zip"
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// pb encodes one length-delimited protocol buffer field.
func pb(num int, v []byte) []byte {
	b := binary.AppendUvarint(nil, uint64(num)<<3|2)
	b = binary.AppendUvarint(b, uint64(len(v)))
	return append(b, v...)
}

// makeCRX builds a signed CRX3 package of archive with key.
func makeCRX(t *testing.T, key *rsa.PrivateKey, archive []byte) ([]byte, string) {
	pub, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	id := IDOf(pub)
	h := sha256.Sum256(pub)
	signed := pb(1, h[:16])
	msg := new(bytes.Buffer)
	msg.WriteString("CRX3 SignedData\x00")
	binary.Write(msg, binary.LittleEndian, uint32(len(signed)))
	msg.Write(signed)
	msg.Write(archive)
	d := sha256.Sum256(msg.Bytes())
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, d[:])
	if err != nil {
		t.Fatal(err)
	}
	header := append(pb(2, append(pb(1, pub), pb(2, sig)...)), pb(10000, signed)...)
	out := []byte("Cr24")
	out = binary.LittleEndian.AppendUint32(out, 3)
	out = binary.LittleEndian.AppendUint32(out, uint32(len(header)))
	out = append(out, header...)
	return append(out, archive...), id
}

func zipOf(t *testing.T, files map[string]string) []byte {
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for n, c := range files {
		f, _ := w.Create(n)
		f.Write([]byte(c))
	}
	w.Close()
	return buf.Bytes()
}

func TestVerifyAndUnpack(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	archive := zipOf(t, map[string]string{
		"manifest.json":                    `{"manifest_version":3,"name":"__MSG_appName__","version":"1.2.3","default_locale":"en"}`,
		"_locales/en/messages.json":        `{"appName":{"message":"Dark Pages"}}`,
		"js/content.js":                    "console.log(1)",
		"_metadata/verified_contents.json": "{}",
		"../escape.txt":                    "never",
	})
	crx, id := makeCRX(t, key, archive)
	got, err := Verify(crx, id)
	if err != nil || !bytes.Equal(got, archive) {
		t.Fatalf("a good package was refused: %v", err)
	}
	// another id, a changed archive, a cut package: refused
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	_, otherID := makeCRX(t, other, archive)
	if _, err := Verify(crx, otherID); err == nil {
		t.Fatal("a package for another extension was accepted")
	}
	bad := append([]byte{}, crx...)
	bad[len(bad)-30] ^= 1
	if _, err := Verify(bad, id); err == nil {
		t.Fatal("a changed package was accepted")
	}
	if _, err := Verify(crx[:20], id); err == nil {
		t.Fatal("a cut package was accepted")
	}

	base := t.TempDir()
	dir := filepath.Join(base, "ext", id)
	m, err := Unpack(got, dir)
	if err != nil || m.Name != "Dark Pages" || m.Version != "1.2.3" || m.Manifest != 3 {
		t.Fatalf("unpack: %+v %v", m, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "js", "content.js")); err != nil {
		t.Fatal("a file is missing")
	}
	if _, err := os.Stat(filepath.Join(dir, "_metadata")); err == nil {
		t.Fatal("_metadata was kept (an unpacked extension may not carry it)")
	}
	if _, err := os.Stat(filepath.Join(base, "ext", "escape.txt")); err == nil {
		t.Fatal("a path left the extension's folder")
	}
}

func TestStoreID(t *testing.T) {
	const id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
	for _, c := range []struct{ in, want string }{
		{"https://chromewebstore.google.com/detail/ublock-origin/" + id, id},
		{"https://chromewebstore.google.com/detail/" + id + "?hl=en", id},
		{"https://chrome.google.com/webstore/detail/ublock-origin/" + id, id},
		{"http://chromewebstore.google.com/detail/x/" + id, ""},
		{"https://evil.example/detail/x/" + id, ""},
		{"https://chromewebstore.google.com/detail/x/notanid", ""},
	} {
		if got := StoreID(c.in); got != c.want {
			t.Errorf("StoreID(%q) = %q", c.in, got)
		}
	}
	if !ValidID(id) || ValidID("ABC") {
		t.Fatal("ValidID")
	}
}
