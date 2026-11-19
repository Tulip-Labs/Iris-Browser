{
  description = "Iris, a light and fast browser with shields built in";

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

        # Servo's bridge for the light pages (webview/servo/rust): every crate
        # is pinned by its Cargo.lock, all from crates.io; SpiderMonkey is
        # built from its source (the build has no network to fetch it)
        irisservo = pkgs.rustPlatform.buildRustPackage {
          pname = "irisservo";
          version = "0.1.0";
          src = ./webview/servo/rust;
          cargoLock.lockFile = ./webview/servo/rust/Cargo.lock;
          env.MOZJS_FROM_SOURCE = "1";
          nativeBuildInputs = with pkgs; [
            pkg-config cmake python3 perl m4 gperf yasm which rustPlatform.bindgenHook llvmPackages.bintools
          ];
          buildInputs = with pkgs; [
            fontconfig freetype harfbuzz libunwind libGL libxkbcommon dbus udev openssl zlib
            xorg.libX11 xorg.libxcb xorg.libXcursor xorg.libXrandr xorg.libXi
          ];
          doCheck = false;
          installPhase = ''
            runHook preInstall
            install -Dm755 target/*/release/libirisservo.so $out/lib/libirisservo.so 2>/dev/null \
              || install -Dm755 target/release/libirisservo.so $out/lib/libirisservo.so
            runHook postInstall
          '';
        };

        iris-browser = pkgs.buildGoModule {
          pname = "iris-browser";
          version = "1.0.24";
          src = self;
          vendorHash = "sha256-DUuIMLR+RLt5e6kRZcxRdGo4Q4i9ZGR7ia629F8Vp2o=";
          subPackages = [ "cmd/iris" ];
          tags = [ "webkit" "cef" "novulkan" "servo" ];
          ldflags = [ "-s" "-w" ];
          doCheck = false;
          overrideModAttrs = _: { preBuild = ""; };
          # libcef.so's own libraries are found at run time (autoPatchelf)
          env.CGO_LDFLAGS = "-Wl,--allow-shlib-undefined";
          dontStrip = true; # libcef.so is stripped when it is unpacked
          nativeBuildInputs = with pkgs; [ pkg-config wrapGAppsHook4 autoPatchelfHook ];
          buildInputs = with pkgs; [
            gtk4 libepoxy libGL glib nss nspr alsa-lib libdrm libxkbcommon at-spi2-atk at-spi2-core
            fontconfig freetype harfbuzz libunwind udev
            cups dbus expat pango cairo (pkgs.libgbm or pkgs.mesa) systemd
            xorg.libX11 xorg.libxcb xorg.libXcomposite xorg.libXdamage xorg.libXext xorg.libXfixes xorg.libXrandr
          ];
          preBuild = ''
            mkdir -p webview/servo/lib
            cp ${irisservo}/lib/libirisservo.so webview/servo/lib/
            mkdir -p third_party/cef
            tar -xjf ${cef} -C third_party/cef --strip-components=1
            strip --strip-unneeded third_party/cef/Release/libcef.so
          '';
          postInstall = ''
            lib=$out/lib/iris-browser
            mkdir -p $lib/locales
            mv $out/bin/iris $lib/iris
            gcc -O2 -fno-stack-protector -Ithird_party/cef -DCEF_API_VERSION=15600 packaging/cef/helper.c \
              -Lthird_party/cef/Release -lcef -Wl,--allow-shlib-undefined -Wl,-rpath,'$ORIGIN' -o $lib/iris-helper
            cp ${irisservo}/lib/libirisservo.so $lib/
            for f in libcef.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json v8_context_snapshot.bin; do
              cp third_party/cef/Release/$f $lib/
            done
            cp third_party/cef/Resources/*.pak third_party/cef/Resources/icudtl.dat $lib/
            cp third_party/cef/Resources/locales/*.pak $lib/locales/
            ln -s $lib/iris $out/bin/iris
            install -Dm644 assets/icon.png $out/share/icons/hicolor/256x256/apps/io.github.tulip_labs.Iris.png
            install -Dm644 packaging/linux/io.github.tulip_labs.Iris.desktop $out/share/applications/io.github.tulip_labs.Iris.desktop
            install -Dm644 packaging/linux/io.github.tulip_labs.Iris.metainfo.xml $out/share/metainfo/io.github.tulip_labs.Iris.metainfo.xml
          '';
          # Gio loads OpenGL ES at run time, Chromium libudev and the graphics
          # drivers: NixOS keeps those in /run/opengl-driver. Fonts: the
          # system's where there is a fontconfig (NixOS, most distributions),
          # else DejaVu and Noto from the store. The Nix store has no setuid
          # helper, so Chromium uses user namespaces for its sandbox.
          preFixup = let
            fonts = pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts noto-fonts noto-fonts-color-emoji ]; };
          in ''
            gappsWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libGL pkgs.libdrm (pkgs.libgbm or pkgs.mesa) pkgs.systemd ]}
              --suffix LD_LIBRARY_PATH : /run/opengl-driver/lib
            )
            wrapGApp $out/lib/iris-browser/iris
            # the launcher: the store's fonts only where the system has no fontconfig
            rm $out/bin/iris
            cat > $out/bin/iris <<EOF
            #!${pkgs.runtimeShell}
            if [ -z "\''${FONTCONFIG_FILE:-}" ] && [ ! -e /etc/fonts/fonts.conf ]; then export FONTCONFIG_FILE=${fonts}; fi
            exec $out/lib/iris-browser/iris "\$@"
            EOF
            chmod 755 $out/bin/iris
          '';
          dontWrapGApps = true;
          meta = with pkgs.lib; {
            description = "A light, fast browser with shields built in";
            homepage = "https://github.com/Tulip-Labs/Iris-Browser";
            license = licenses.gpl3Only;
            platforms = [ "x86_64-linux" ];
            mainProgram = "iris";
          };
        };
        default = iris-browser;
      });

      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/iris";
        };
      });
    };
}
