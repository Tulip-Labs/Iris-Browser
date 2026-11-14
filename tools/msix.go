//go:build ignore

// msix packs Lite Go for the Microsoft Store without the Windows SDK:
//
//	go run tools/msix.go -exe "dist/Lite Go/Lite Go.exe" -arch x64 -out dist/LiteGo_x64.msix
//	go run tools/msix.go -bundle dist/LiteGo.msixbundle dist/LiteGo_x64.msix dist/LiteGo_arm64.msix
//
// The packages are unsigned: upload them (or the bundle) to Partner Center and
// the Store signs them with Microsoft's certificate, so they install on any PC
// without warnings. Identity values come from packaging/msix.json.
package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"hash/crc32"
	"image"
	"image/png"
	"io"
	"log"
	"os"
	"path"
	"path/filepath"
	"strings"

	"litego/raster"
	"litego/ui"
)

type identity struct {
	Name, Publisher, PublisherDisplayName, Version string
}

type part struct {
	name string // in the package, with forward slashes, no spaces
	data []byte
}

type counter struct {
	w io.Writer
	n int64
}

func (c *counter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// writePackage writes parts (stored, so every block is its own hash) plus the
// block map and content types. It returns where each part's data starts.
func writePackage(out string, parts []part, types string) map[string]int64 {
	f, err := os.Create(out)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	cw := &counter{w: f}
	zw := zip.NewWriter(cw)
	offsets := map[string]int64{}
	var bm strings.Builder
	bm.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n" + `<BlockMap xmlns="http://schemas.microsoft.com/appx/2010/blockmap" HashMethod="http://www.w3.org/2001/04/xmlenc#sha256">`)
	add := func(p part, inMap bool) {
		h := &zip.FileHeader{Name: p.name, Method: zip.Store, CRC32: crc32.ChecksumIEEE(p.data),
			CompressedSize64: uint64(len(p.data)), UncompressedSize64: uint64(len(p.data))}
		start := cw.n
		w, err := zw.CreateRaw(h)
		if err != nil {
			log.Fatal(err)
		}
		lfh := 30 + len(p.name)
		if _, err := w.Write(p.data); err != nil {
			log.Fatal(err)
		}
		offsets[p.name] = start + int64(lfh)
		if !inMap {
			return
		}
		fmt.Fprintf(&bm, `<File Name="%s" Size="%d" LfhSize="%d">`, strings.ReplaceAll(p.name, "/", `\`), len(p.data), lfh)
		for i := 0; i < len(p.data); i += 65536 {
			sum := sha256.Sum256(p.data[i:min(len(p.data), i+65536)])
			fmt.Fprintf(&bm, `<Block Hash="%s"/>`, base64.StdEncoding.EncodeToString(sum[:]))
		}
		bm.WriteString(`</File>`)
	}
	for _, p := range parts {
		add(p, true)
	}
	bm.WriteString(`</BlockMap>`)
	// the block map and content types are written after the parts they describe;
	// zip.Writer flushes local headers lazily, so offsets above are exact
	add(part{"AppxBlockMap.xml", []byte(bm.String())}, false)
	add(part{"[Content_Types].xml", []byte(types)}, false)
	if err := zw.Close(); err != nil {
		log.Fatal(err)
	}
	return offsets
}

func contentTypes(parts []part, overrides map[string]string) string {
	defaults := map[string]string{}
	var sb strings.Builder
	sb.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n" + `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">`)
	known := map[string]string{"exe": "application/x-msdownload", "png": "image/png", "md": "text/plain", "xml": "application/xml", "msix": "application/vnd.ms-appx"}
	for _, p := range parts {
		if _, ok := overrides["/"+p.name]; ok {
			continue
		}
		ext := strings.TrimPrefix(path.Ext(p.name), ".")
		if ext == "" {
			overrides["/"+p.name] = "application/octet-stream"
			continue
		}
		if _, ok := defaults[ext]; !ok {
			ct := known[strings.ToLower(ext)]
			if ct == "" {
				ct = "application/octet-stream"
			}
			defaults[ext] = ct
			fmt.Fprintf(&sb, `<Default Extension="%s" ContentType="%s"/>`, ext, ct)
		}
	}
	for n, ct := range overrides {
		fmt.Fprintf(&sb, `<Override PartName="%s" ContentType="%s"/>`, n, ct)
	}
	sb.WriteString(`</Types>`)
	return sb.String()
}

func logo(w, h int) []byte {
	s := float32(min(w, h))
	c := raster.New(w, h, 1, raster.NewFonts())
	th := ui.ThemeByID("crocus")
	box := ui.RectAround(float32(w)/2, float32(h)/2, s*0.92, s*0.92)
	ui.FillRoundAccent(c, box, box.W*0.27, th.Primary)
	k := box.W / 24
	ui.Pen(c, ui.NewPath().Arc(box.CX(), box.CY(), 6.6*k, 140, 470, true), 2.1*k, ui.White)
	ui.FillOval(c, ui.RectAround(box.X+17.2*k, box.Y+7.4*k, 4.6*k, 4.6*k), th.Hl)
	ui.FillOval(c, ui.RectAround(box.CX(), box.CY(), 3.2*k, 3.2*k), ui.White)
	var b bytes.Buffer
	png.Encode(&b, image.Image(c.Img))
	return b.Bytes()
}

func readID() identity {
	id := identity{Name: "TulipanLabs.LiteGo", Publisher: "CN=Tulipan Labs", PublisherDisplayName: "Tulipan Labs", Version: "1.0.3.0"}
	if b, err := os.ReadFile("packaging/msix.json"); err == nil {
		var f map[string]string
		if json.Unmarshal(b, &f) == nil {
			for k, v := range map[string]*string{"name": &id.Name, "publisher": &id.Publisher, "publisherDisplayName": &id.PublisherDisplayName, "version": &id.Version} {
				if f[k] != "" {
					*v = f[k]
				}
			}
		}
	}
	return id
}

func xmlEsc(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}

const manifest = `<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap3 rescap">
  <Identity Name="{{name}}" Publisher="{{publisher}}" Version="{{version}}" ProcessorArchitecture="{{arch}}" />
  <Properties>
    <DisplayName>Lite Go</DisplayName>
    <PublisherDisplayName>{{publisherName}}</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
    <Description>A light, fast browser: low memory, a built-in shield, and Google results in its own look.</Description>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application Id="LiteGo" Executable="LiteGo.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="Lite Go" Description="A light, fast browser"
        BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png">
        <uap:DefaultTile Wide310x150Logo="Assets\Wide310x150Logo.png" />
      </uap:VisualElements>
      <Extensions>
        <uap:Extension Category="windows.protocol"><uap:Protocol Name="http"><uap:DisplayName>Lite Go</uap:DisplayName></uap:Protocol></uap:Extension>
        <uap:Extension Category="windows.protocol"><uap:Protocol Name="https"><uap:DisplayName>Lite Go</uap:DisplayName></uap:Protocol></uap:Extension>
        <uap:Extension Category="windows.fileTypeAssociation">
          <uap:FileTypeAssociation Name="html">
            <uap:DisplayName>Web page</uap:DisplayName>
            <uap:SupportedFileTypes><uap:FileType>.htm</uap:FileType><uap:FileType>.html</uap:FileType></uap:SupportedFileTypes>
          </uap:FileTypeAssociation>
        </uap:Extension>
        <uap3:Extension Category="windows.appExecutionAlias" EntryPoint="Windows.FullTrustApplication">
          <uap3:AppExecutionAlias><uap3:ExecutionAlias Alias="litego.exe" /></uap3:AppExecutionAlias>
        </uap3:Extension>
      </Extensions>
    </Application>
  </Applications>
  <Capabilities>
    <Capability Name="internetClient" />
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
`

func pack(exe, arch, out string) {
	id := readID()
	app, err := os.ReadFile(exe)
	if err != nil {
		log.Fatal(err)
	}
	m := strings.NewReplacer("{{name}}", xmlEsc(id.Name), "{{publisher}}", xmlEsc(id.Publisher), "{{version}}", id.Version,
		"{{arch}}", arch, "{{publisherName}}", xmlEsc(id.PublisherDisplayName)).Replace(manifest)
	parts := []part{{"LiteGo.exe", app}}
	for _, n := range []string{"LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"} {
		if b, err := os.ReadFile(n); err == nil {
			parts = append(parts, part{n, b})
		}
	}
	parts = append(parts,
		part{"Assets/StoreLogo.png", logo(50, 50)},
		part{"Assets/Square44x44Logo.png", logo(44, 44)},
		part{"Assets/Square44x44Logo.targetsize-256_altform-unplated.png", logo(256, 256)},
		part{"Assets/Square150x150Logo.png", logo(150, 150)},
		part{"Assets/Wide310x150Logo.png", logo(310, 150)},
		part{"AppxManifest.xml", []byte(m)})
	ct := contentTypes(parts, map[string]string{"/AppxManifest.xml": "application/vnd.ms-appx.manifest+xml", "/AppxBlockMap.xml": "application/vnd.ms-appx.blockmap+xml"})
	writePackage(out, parts, ct)
	fmt.Println("wrote", out)
}

func bundle(out string, pkgs []string) {
	id := readID()
	var parts []part
	type info struct {
		name, arch string
		size       int
	}
	var infos []info
	for _, p := range pkgs {
		b, err := os.ReadFile(p)
		if err != nil {
			log.Fatal(err)
		}
		name := filepath.Base(p)
		arch := "x64"
		for _, a := range []string{"arm64", "x86", "x64"} {
			if strings.Contains(strings.ToLower(name), a) {
				arch = a
				break
			}
		}
		parts = append(parts, part{name, b})
		infos = append(infos, info{name, arch, len(b)})
	}
	// offsets are only known once the packages are placed, so place them,
	// then write the bundle again with the manifest that names them
	tmp := out + ".tmp"
	offs := writePackage(tmp, parts, contentTypes(parts, map[string]string{}))
	os.Remove(tmp)
	var sb strings.Builder
	fmt.Fprintf(&sb, `<?xml version="1.0" encoding="UTF-8"?>
<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle" SchemaVersion="5.0">
  <Identity Name="%s" Publisher="%s" Version="%s" />
  <Packages>
`, xmlEsc(id.Name), xmlEsc(id.Publisher), id.Version)
	for _, in := range infos {
		fmt.Fprintf(&sb, `    <Package Type="application" Version="%s" Architecture="%s" FileName="%s" Offset="%d" Size="%d"><Resources><Resource Language="en-us" /></Resources></Package>
`, id.Version, in.arch, in.name, offs[in.name], in.size)
	}
	sb.WriteString("  </Packages>\n</Bundle>\n")
	all := append(parts, part{"AppxMetadata/AppxBundleManifest.xml", []byte(sb.String())})
	ct := contentTypes(all, map[string]string{"/AppxMetadata/AppxBundleManifest.xml": "application/vnd.ms-appx.bundlemanifest+xml", "/AppxBlockMap.xml": "application/vnd.ms-appx.blockmap+xml"})
	got := writePackage(out, all, ct)
	for _, in := range infos {
		if got[in.name] != offs[in.name] {
			log.Fatalf("package offset moved for %s", in.name)
		}
	}
	fmt.Println("wrote", out)
}

func main() {
	exe := flag.String("exe", "", "the app to pack")
	arch := flag.String("arch", "x64", "x64 or arm64")
	out := flag.String("out", "", "the .msix to write")
	bun := flag.String("bundle", "", "write a .msixbundle of the .msix files given after the flags")
	flag.Parse()
	switch {
	case *bun != "":
		bundle(*bun, flag.Args())
	case *exe != "" && *out != "":
		pack(*exe, *arch, *out)
	default:
		flag.Usage()
		os.Exit(2)
	}
}
