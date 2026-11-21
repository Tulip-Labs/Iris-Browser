{
  description = "Iris, a light and fast browser with shields built in";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        iris-browser = pkgs.buildGoModule {
          pname = "iris-browser";
          version = "1.0.26";
          src = self;
          vendorHash = "sha256-DUuIMLR+RLt5e6kRZcxRdGo4Q4i9ZGR7ia629F8Vp2o=";
          subPackages = [ "cmd/iris" ];
          # the pages: WebKitGTK
          tags = [ "webkit" "novulkan" ];
          ldflags = [ "-s" "-w" ];
          doCheck = false;
          overrideModAttrs = _: { preBuild = ""; };
          nativeBuildInputs = with pkgs; [ pkg-config wrapGAppsHook4 makeWrapper ];
          # WebKit's media through GStreamer (H.264 and AAC with libav), and
          # TLS through glib-networking (wrapGAppsHook sets their paths)
          buildInputs = with pkgs; [
            gtk4 libepoxy libGL glib fontconfig freetype harfbuzz webkitgtk_6_0 libsoup_3 glib-networking
            gst_all_1.gstreamer gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good gst_all_1.gst-plugins-bad gst_all_1.gst-libav
          ];
          postInstall = ''
            lib=$out/lib/iris-browser
            mkdir -p $lib
            mv $out/bin/iris $lib/iris
            echo $version > $lib/VERSION
            install -Dm644 assets/icon.png $out/share/icons/hicolor/256x256/apps/io.github.tulip_labs.Iris.png
            install -Dm644 packaging/linux/io.github.tulip_labs.Iris.desktop $out/share/applications/io.github.tulip_labs.Iris.desktop
            install -Dm644 packaging/linux/io.github.tulip_labs.Iris.metainfo.xml $out/share/metainfo/io.github.tulip_labs.Iris.metainfo.xml
          '';
          # Gio and WebKit load OpenGL ES and the graphics drivers at run time:
          # NixOS keeps those in /run/opengl-driver. Fonts: the system's where
          # there is a fontconfig (NixOS, most distributions), else DejaVu and
          # Noto from the store.
          preFixup = let
            fonts = pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts noto-fonts noto-fonts-color-emoji ]; };
          in ''
            gappsWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libGL pkgs.libdrm (pkgs.libgbm or pkgs.mesa) pkgs.systemd ]}
              --suffix LD_LIBRARY_PATH : /run/opengl-driver/lib
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
            platforms = [ "x86_64-linux" "aarch64-linux" ];
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
