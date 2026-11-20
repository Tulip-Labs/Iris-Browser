{
  description = "Iris, a light and fast browser with shields built in";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Electron (the engine for heavy pages) and Servo are built for x86_64 here
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
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
          # Servo allocates with jemalloc: nixpkgs' build of it with Rust's
          # symbol prefix (its setup hook points tikv-jemalloc-sys at it)
          buildInputs = with pkgs; [
            rust-jemalloc-sys zstd xz glib sqlite
            fontconfig freetype harfbuzz libunwind libGL libxkbcommon dbus udev openssl zlib
            xorg.libX11 xorg.libxcb xorg.libXcursor xorg.libXrandr xorg.libXi
          ];
          # SpiderMonkey assembles through the C compiler (it passes -D flags);
          # Nix's environment points AS at the bare assembler
          preBuild = ''
            export AS="$CC"
          '';
          # Nix's format hardening adds -Wformat-security without -Wformat,
          # which SpiderMonkey's -Werror turns into an error (nixpkgs'
          # spidermonkey turns it off the same way)
          hardeningDisable = [ "format" ];
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
          version = "1.0.25";
          src = self;
          vendorHash = "sha256-DUuIMLR+RLt5e6kRZcxRdGo4Q4i9ZGR7ia629F8Vp2o=";
          subPackages = [ "cmd/iris" ];
          # the pages: Servo for light ones, in Iris's process; Electron (from
          # nixpkgs, H.264 and AAC included) for the rest, started on demand
          tags = [ "webkit" "electron" "novulkan" "servo" ];
          ldflags = [ "-s" "-w" ];
          doCheck = false;
          overrideModAttrs = _: { preBuild = ""; };
          nativeBuildInputs = with pkgs; [ pkg-config wrapGAppsHook4 makeWrapper ];
          buildInputs = with pkgs; [ gtk4 libepoxy libGL glib fontconfig freetype harfbuzz ];
          preBuild = ''
            mkdir -p webview/servo/lib
            cp ${irisservo}/lib/libirisservo.so webview/servo/lib/
          '';
          postInstall = ''
            lib=$out/lib/iris-browser
            mkdir -p $lib/electron-helper
            mv $out/bin/iris $lib/iris
            cp ${irisservo}/lib/libirisservo.so $lib/
            # Iris's helper app for Electron: one script, no web interface
            # (Chrome extensions need electron-chrome-extensions from npm, which
            # this build leaves out; the shields block ads without them)
            cp webview/electron/helper/main.js webview/electron/helper/preload.js webview/electron/helper/package.json $lib/electron-helper/
            echo $version > $lib/VERSION
            install -Dm644 assets/icon.png $out/share/icons/hicolor/256x256/apps/io.github.tulip_labs.Iris.png
            install -Dm644 packaging/linux/io.github.tulip_labs.Iris.desktop $out/share/applications/io.github.tulip_labs.Iris.desktop
            install -Dm644 packaging/linux/io.github.tulip_labs.Iris.metainfo.xml $out/share/metainfo/io.github.tulip_labs.Iris.metainfo.xml
          '';
          # Gio loads OpenGL ES at run time and Servo the graphics drivers:
          # NixOS keeps those in /run/opengl-driver. Fonts: the system's where
          # there is a fontconfig (NixOS, most distributions), else DejaVu and
          # Noto from the store. Electron is nixpkgs' own.
          preFixup = let
            fonts = pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts noto-fonts noto-fonts-color-emoji ]; };
          in ''
            gappsWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libGL pkgs.libdrm (pkgs.libgbm or pkgs.mesa) pkgs.systemd ]}
              --suffix LD_LIBRARY_PATH : /run/opengl-driver/lib
              --set-default IRIS_ELECTRON ${pkgs.electron}/bin/electron
              --set-default IRIS_ELECTRON_APP $out/lib/iris-browser/electron-helper
            )
            wrapGApp $out/lib/iris-browser/iris
            # the launcher: the store's fonts only where the system has no fontconfig
            mkdir -p $out/bin
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
