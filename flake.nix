{
  description = "Iris (formerly Lite Go), a light and fast browser with shields built in";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Chromium (CEF) is published for x86_64 here
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        # the Chromium Embedded Framework named in packaging/cef/cef.env
        cef = pkgs.fetchurl {
          url = "https://cef-builds.spotifycdn.com/cef_binary_156.0.30%2Bg6028375%2Bchromium-156.0.8078.96_linux64_minimal.tar.bz2";
          hash = "sha1-C0whieO5MDO77xOt0ahvZoScHmI=";
        };

        lite-go-browser = pkgs.buildGoModule {
          pname = "lite-go-browser";
          version = "1.0.17";
          src = self;
          vendorHash = "sha256-DUuIMLR+RLt5e6kRZcxRdGo4Q4i9ZGR7ia629F8Vp2o=";
          subPackages = [ "cmd/litego" ];
          tags = [ "webkit" "cef" "novulkan" ];
          ldflags = [ "-s" "-w" ];
          doCheck = false;
          overrideModAttrs = _: { preBuild = ""; };
          # libcef.so's own libraries are found at run time (autoPatchelf)
          env.CGO_LDFLAGS = "-Wl,--allow-shlib-undefined";
          dontStrip = true; # libcef.so is stripped when it is unpacked
          nativeBuildInputs = with pkgs; [ pkg-config wrapGAppsHook3 autoPatchelfHook ];
          buildInputs = with pkgs; [
            gtk3 libepoxy libGL glib nss nspr alsa-lib libdrm libxkbcommon at-spi2-atk at-spi2-core
            cups dbus expat pango cairo (pkgs.libgbm or pkgs.mesa) systemd
            xorg.libX11 xorg.libxcb xorg.libXcomposite xorg.libXdamage xorg.libXext xorg.libXfixes xorg.libXrandr
          ];
          preBuild = ''
            mkdir -p third_party/cef
            tar -xjf ${cef} -C third_party/cef --strip-components=1
            strip --strip-unneeded third_party/cef/Release/libcef.so
          '';
          postInstall = ''
            lib=$out/lib/lite-go-browser
            mkdir -p $lib/locales
            mv $out/bin/litego $lib/lite-go-browser
            gcc -O2 -fno-stack-protector -Ithird_party/cef -DCEF_API_VERSION=15600 packaging/cef/helper.c \
              -Lthird_party/cef/Release -lcef -Wl,--allow-shlib-undefined -Wl,-rpath,'$ORIGIN' -o $lib/lite-go-helper
            for f in libcef.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json v8_context_snapshot.bin; do
              cp third_party/cef/Release/$f $lib/
            done
            cp third_party/cef/Resources/*.pak third_party/cef/Resources/icudtl.dat $lib/
            cp third_party/cef/Resources/locales/*.pak $lib/locales/
            ln -s $lib/lite-go-browser $out/bin/lite-go
            ln -s $lib/lite-go-browser $out/bin/lite-go-browser
            ln -s $lib/lite-go-browser $out/bin/iris
            install -Dm644 assets/icon.png $out/share/icons/hicolor/256x256/apps/lite-go.png
            install -Dm644 packaging/linux/lite-go.desktop $out/share/applications/lite-go.desktop
          '';
          # Gio loads OpenGL ES at run time, Chromium libudev; the Nix store has
          # no setuid helper, so Chromium uses user namespaces for its sandbox
          preFixup = ''
            gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libGL pkgs.systemd ]})
            # H.264 and H.265 videos play through ffmpeg (Chromium's free build leaves them out)
            gappsWrapperArgs+=(--prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ffmpeg ]})
            wrapGApp $out/lib/lite-go-browser/lite-go-browser
          '';
          dontWrapGApps = true;
          meta = with pkgs.lib; {
            description = "A light, fast browser with shields built in";
            homepage = "https://github.com/Tulip-Labs/Iris-Browser";
            license = licenses.gpl3Only;
            platforms = [ "x86_64-linux" ];
            mainProgram = "lite-go";
          };
        };
        default = lite-go-browser;
      });

      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/lite-go";
        };
      });
    };
}
