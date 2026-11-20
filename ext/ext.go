// Package ext installs browser extensions from the Chrome Web Store: it
// downloads an extension's package (a CRX file), checks that it is signed by
// the extension's own key (the same check Chrome makes), and unpacks it into
// a folder the web engine loads it from.
//
// Only engines that run extensions use it (WebView2 on Windows, Electron on
// Linux). On Linux the Electron engine runs them; WebKit's pages never do
// (a page an extension must see goes to Electron).
package ext

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// Limits on what one extension may be.
const (
	MaxPackage  = 256 << 20 // the CRX download
	MaxUnpacked = 512 << 20 // all files unpacked
	MaxFiles    = 20000
)

var idRE = regexp.MustCompile(`^[a-p]{32}$`)

// ValidID says whether id is an extension id (32 letters a to p).
func ValidID(id string) bool { return idRE.MatchString(id) }

// StoreID returns the extension id of a Chrome Web Store page address
// (chromewebstore.google.com/detail/<name>/<id>, or the old
// chrome.google.com/webstore/detail/...), or "".
func StoreID(page string) string {
	u, err := url.Parse(page)
	if err != nil || u.Scheme != "https" {
		return ""
	}
	h := strings.ToLower(u.Hostname())
	if h != "chromewebstore.google.com" && h != "chrome.google.com" {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	for i, p := range parts {
		if p == "detail" {
			for _, q := range parts[i+1:] {
				if ValidID(q) {
					return q
				}
			}
		}
	}
	return ""
}

// IDOf is the extension id a public key gives (Chrome's rule: the first 16
// bytes of the key's SHA-256, each half-byte written as a letter from a).
func IDOf(publicKey []byte) string {
	h := sha256.Sum256(publicKey)
	var b strings.Builder
	for _, c := range h[:16] {
		b.WriteByte('a' + c>>4)
		b.WriteByte('a' + c&15)
	}
	return b.String()
}

// DownloadURL is where Google serves an extension's current package.
func DownloadURL(id, chromeVersion string) string {
	q := url.Values{}
	q.Set("response", "redirect")
	q.Set("prodversion", chromeVersion)
	q.Set("acceptformat", "crx3")
	q.Set("x", "id="+id+"&uc")
	return "https://clients2.google.com/service/update2/crx?" + q.Encode()
}

// Fetch downloads extension id from the Chrome Web Store and returns its
// verified contents (a zip archive).
func Fetch(ctx context.Context, c *http.Client, id, chromeVersion string) ([]byte, error) {
	if !ValidID(id) {
		return nil, errors.New("not an extension id")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, DownloadURL(id, chromeVersion), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/"+chromeVersion+" Safari/537.36")
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the Chrome Web Store answered %s", resp.Status)
	}
	if fu := resp.Request.URL; fu.Scheme != "https" {
		return nil, errors.New("the package did not come over a secure connection")
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, MaxPackage+1))
	if err != nil {
		return nil, err
	}
	if len(b) > MaxPackage {
		return nil, errors.New("the extension is too large")
	}
	return Verify(b, id)
}

// Verify checks a CRX3 package: it must carry a signature, by a key whose
// id is id, over its contents, and every signature it carries must hold.
// It returns the contents (a zip archive).
func Verify(crx []byte, id string) ([]byte, error) {
	if len(crx) < 12 || string(crx[:4]) != "Cr24" {
		return nil, errors.New("not an extension package")
	}
	if v := binary.LittleEndian.Uint32(crx[4:8]); v != 3 {
		return nil, fmt.Errorf("extension package version %d is not supported", v)
	}
	hl := binary.LittleEndian.Uint32(crx[8:12])
	if uint64(hl) > uint64(len(crx)-12) {
		return nil, errors.New("the extension package is cut short")
	}
	header, archive := crx[12:12+hl], crx[12+hl:]
	h, err := parseHeader(header)
	if err != nil {
		return nil, err
	}
	if h.crxID != nil && IDOf2(h.crxID) != id {
		return nil, errors.New("the package is for another extension")
	}
	// what is signed: a fixed text, the signed header data, the archive
	msg := new(bytes.Buffer)
	msg.WriteString("CRX3 SignedData\x00")
	binary.Write(msg, binary.LittleEndian, uint32(len(h.signedData)))
	msg.Write(h.signedData)
	msg.Write(archive)
	digest := sha256.Sum256(msg.Bytes())
	own := false
	for _, p := range h.proofs {
		key, err := x509.ParsePKIXPublicKey(p.key)
		if err != nil {
			return nil, errors.New("the package carries a key that cannot be read")
		}
		ok := false
		switch k := key.(type) {
		case *rsa.PublicKey:
			ok = !p.ecdsa && rsa.VerifyPKCS1v15(k, crypto.SHA256, digest[:], p.sig) == nil
		case *ecdsa.PublicKey:
			ok = p.ecdsa && ecdsa.VerifyASN1(k, digest[:], p.sig)
		}
		if !ok {
			return nil, errors.New("the package's signature does not hold")
		}
		if IDOf(p.key) == id {
			own = true
		}
	}
	if !own {
		return nil, errors.New("the package is not signed by the extension's own key")
	}
	return archive, nil
}

// IDOf2 writes a 16-byte crx id as letters (as IDOf does for a key's hash).
func IDOf2(raw []byte) string {
	var b strings.Builder
	for _, c := range raw {
		b.WriteByte('a' + c>>4)
		b.WriteByte('a' + c&15)
	}
	return b.String()
}

type proof struct {
	key, sig []byte
	ecdsa    bool
}

type crxHeader struct {
	proofs     []proof
	signedData []byte
	crxID      []byte
}

// parseHeader reads the CRX3 header (a protocol buffer):
//
//	CrxFileHeader { repeated AsymmetricKeyProof sha256_with_rsa = 2;
//	                repeated AsymmetricKeyProof sha256_with_ecdsa = 3;
//	                bytes signed_header_data = 10000; }
//	AsymmetricKeyProof { bytes public_key = 1; bytes signature = 2; }
//	SignedData { bytes crx_id = 1; }
func parseHeader(b []byte) (crxHeader, error) {
	var h crxHeader
	err := fields(b, func(num int, v []byte) error {
		switch num {
		case 2, 3:
			var p proof
			p.ecdsa = num == 3
			if err := fields(v, func(n int, w []byte) error {
				switch n {
				case 1:
					p.key = w
				case 2:
					p.sig = w
				}
				return nil
			}); err != nil {
				return err
			}
			h.proofs = append(h.proofs, p)
		case 10000:
			h.signedData = v
			return fields(v, func(n int, w []byte) error {
				if n == 1 {
					h.crxID = w
				}
				return nil
			})
		}
		return nil
	})
	if err != nil {
		return h, errors.New("the extension package's header cannot be read")
	}
	if len(h.proofs) == 0 || h.signedData == nil {
		return h, errors.New("the extension package is not signed")
	}
	return h, nil
}

// fields walks the length-delimited fields of a protocol buffer message
// (the only kind a CRX header has); other wire types are skipped.
func fields(b []byte, f func(num int, v []byte) error) error {
	for len(b) > 0 {
		tag, n := binary.Uvarint(b)
		if n <= 0 {
			return errors.New("bad tag")
		}
		b = b[n:]
		num, wire := int(tag>>3), tag&7
		switch wire {
		case 0:
			_, n = binary.Uvarint(b)
			if n <= 0 {
				return errors.New("bad varint")
			}
			b = b[n:]
		case 1:
			if len(b) < 8 {
				return errors.New("short")
			}
			b = b[8:]
		case 5:
			if len(b) < 4 {
				return errors.New("short")
			}
			b = b[4:]
		case 2:
			l, n := binary.Uvarint(b)
			if n <= 0 || l > uint64(len(b)-n) {
				return errors.New("bad length")
			}
			v := b[n : n+int(l)]
			b = b[n+int(l):]
			if err := f(num, v); err != nil {
				return err
			}
		default:
			return errors.New("bad wire type")
		}
	}
	return nil
}

// Manifest is what Iris reads from an extension's manifest.json.
type Manifest struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	Description string `json:"description"`
	Manifest    int    `json:"manifest_version"`
	DefaultLang string `json:"default_locale"`
}

// Unpack writes the archive into dir (made new; anything there is
// replaced) and returns its manifest. Paths that would leave dir, links,
// and Chrome's own _metadata folder (which an unpacked extension may not
// carry) are left out; the size and the number of files are limited.
func Unpack(archive []byte, dir string) (Manifest, error) {
	var m Manifest
	zr, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		return m, errors.New("the extension's files cannot be read")
	}
	if len(zr.File) > MaxFiles {
		return m, errors.New("the extension has too many files")
	}
	tmp := dir + ".new"
	os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return m, err
	}
	fail := func(err error) (Manifest, error) { os.RemoveAll(tmp); return m, err }
	var total int64
	for _, f := range zr.File {
		name := path.Clean(strings.ReplaceAll(f.Name, "\\", "/"))
		if name == "." || strings.HasPrefix(name, "../") || name == ".." || path.IsAbs(name) || strings.Contains(name, ":") {
			continue
		}
		if name == "_metadata" || strings.HasPrefix(name, "_metadata/") {
			continue
		}
		mode := f.Mode()
		if mode&os.ModeSymlink != 0 || (!mode.IsRegular() && !mode.IsDir()) {
			continue
		}
		dst := filepath.Join(tmp, filepath.FromSlash(name))
		if mode.IsDir() || strings.HasSuffix(f.Name, "/") {
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return fail(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return fail(err)
		}
		r, err := f.Open()
		if err != nil {
			return fail(errors.New("the extension's files cannot be read"))
		}
		w, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			r.Close()
			return fail(err)
		}
		n, err := io.Copy(w, io.LimitReader(r, MaxUnpacked-total+1))
		r.Close()
		if cerr := w.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return fail(err)
		}
		total += n
		if total > MaxUnpacked {
			return fail(errors.New("the extension is too large unpacked"))
		}
	}
	b, err := os.ReadFile(filepath.Join(tmp, "manifest.json"))
	if err != nil {
		return fail(errors.New("the extension has no manifest"))
	}
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf"))
	if err := json.Unmarshal(b, &m); err != nil || m.Manifest < 2 {
		return fail(errors.New("the extension's manifest cannot be read"))
	}
	m.Name = localized(tmp, m.Name, m.DefaultLang)
	m.Description = localized(tmp, m.Description, m.DefaultLang)
	os.RemoveAll(dir)
	if err := os.Rename(tmp, dir); err != nil {
		return fail(err)
	}
	return m, nil
}

// localized resolves a "__MSG_name__" from the extension's default locale.
func localized(dir, s, lang string) string {
	if !strings.HasPrefix(s, "__MSG_") || !strings.HasSuffix(s, "__") || lang == "" || strings.ContainsAny(lang, `/\.`) {
		return s
	}
	key := strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(s, "__MSG_"), "__"))
	b, err := os.ReadFile(filepath.Join(dir, "_locales", lang, "messages.json"))
	if err != nil {
		return s
	}
	var msgs map[string]struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(bytes.TrimPrefix(b, []byte("\xef\xbb\xbf")), &msgs) != nil {
		return s
	}
	for k, v := range msgs {
		if strings.ToLower(k) == key && v.Message != "" {
			return v.Message
		}
	}
	return s
}
