//go:build ignore

// icongen draws Iris's icon with the shared renderer and writes the Windows
// resource objects (icon and version info) that go build links automatically:
//
//	go run tools/icongen.go
//
// It needs github.com/tc-hib/winres; the generated .syso files are committed,
// so normal builds do not.
package main

import (
	"image"
	"image/png"
	"log"
	"os"

	"github.com/tc-hib/winres"
	"github.com/tc-hib/winres/version"

	"iris/raster"
	"iris/ui"
)

func icon(size int) image.Image {
	c := raster.New(24, 24, float32(size)/24, raster.NewFonts())
	ui.IrisIcon(c, ui.Rect{X: 1, Y: 1, W: 22, H: 22})
	return c.Img
}

func main() {
	for _, t := range []struct{ dir, name, desc string }{
		{"cmd/iris", "Iris", "Iris browser"},
		{"cmd/iris-setup", "Iris Setup", "Iris installer"},
	} {
		var imgs []image.Image
		for _, s := range []int{256, 64, 48, 32, 24, 16} {
			imgs = append(imgs, icon(s))
		}
		ic, err := winres.NewIconFromImages(imgs)
		if err != nil {
			log.Fatal(err)
		}
		rs := &winres.ResourceSet{}
		rs.SetIcon(winres.ID(1), ic)
		v := version.Info{}
		v.SetFileVersion("1.0.3.0")
		v.SetProductVersion("1.0.3.0")
		v.Set(0, version.ProductName, "Iris")
		v.Set(0, version.FileDescription, t.desc)
		v.Set(0, version.CompanyName, "Tulipan Labs")
		v.Set(0, version.LegalCopyright, "Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez). GNU GPL 3.0")
		v.Set(0, version.OriginalFilename, t.name+".exe")
		rs.SetVersionInfo(v)
		rs.SetManifest(winres.AppManifest{DPIAwareness: winres.DPIPerMonitorV2, UseCommonControlsV6: true, ExecutionLevel: winres.AsInvoker})
		for _, arch := range []winres.Arch{winres.ArchAMD64, winres.ArchARM64, winres.ArchI386} {
			name := map[winres.Arch]string{winres.ArchAMD64: "amd64", winres.ArchARM64: "arm64", winres.ArchI386: "386"}[arch]
			f, err := os.Create(t.dir + "/rsrc_windows_" + name + ".syso")
			if err != nil {
				log.Fatal(err)
			}
			if err := rs.WriteObject(f, arch); err != nil {
				log.Fatal(err)
			}
			f.Close()
		}
	}
	// a PNG of the icon for the README
	raster256 := icon(256)
	f, _ := os.Create("assets/icon.png")
	defer f.Close()
	if err := png.Encode(f, raster256); err != nil {
		log.Fatal(err)
	}
}
