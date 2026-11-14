{
  description = "Lite Go, a light and fast browser with shields built in";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        lite-go-browser = pkgs.buildGoModule {
          pname = "lite-go-browser";
          version = "1.0.7";
          src = self;
          vendorHash = "sha256-DUuIMLR+RLt5e6kRZcxRdGo4Q4i9ZGR7ia629F8Vp2o=";
          subPackages = [ "cmd/litego" ];
          tags = [ "webkit" "novulkan" ];
          ldflags = [ "-s" "-w" ];
          doCheck = false;
          nativeBuildInputs = with pkgs; [ pkg-config wrapGAppsHook3 ];
          buildInputs = with pkgs; [ gtk3 webkitgtk_4_1 libepoxy libGL glib-networking gsettings-desktop-schemas ];
          # Gio loads OpenGL ES at run time
          preFixup = ''
            gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libGL ]})
          '';
          postInstall = ''
            mv $out/bin/litego $out/bin/lite-go
            ln -s lite-go $out/bin/lite-go-browser
            install -Dm644 assets/icon.png $out/share/icons/hicolor/256x256/apps/lite-go.png
            install -Dm644 packaging/linux/lite-go.desktop $out/share/applications/lite-go.desktop
          '';
          meta = with pkgs.lib; {
            description = "A light, fast browser with shields built in";
            homepage = "https://github.com/Tulip-Labs/Lite-Go-Browser";
            license = licenses.gpl3Only;
            platforms = platforms.linux;
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
