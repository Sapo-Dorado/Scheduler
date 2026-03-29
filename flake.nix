{
  description = "SkillRunner — cron for Claude Code skills";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "skillrunner";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = [ pkgs.bash pkgs.jq pkgs.coreutils pkgs.gawk pkgs.findutils pkgs.openssl pkgs.curl pkgs.git ];

            installPhase = ''
              mkdir -p $out/bin $out/lib $out/share/skillrunner

              # Install library files
              cp lib/*.sh $out/lib/

              # Install and wrap bin scripts
              for script in bin/*; do
                install -m755 "$script" "$out/bin/$(basename $script)"
                wrapProgram "$out/bin/$(basename $script)" \
                  --set SKILLRUNNER_LIB "$out/lib" \
                  --prefix PATH : "${pkgs.lib.makeBinPath [
                    pkgs.bash pkgs.jq pkgs.coreutils pkgs.gawk pkgs.findutils pkgs.openssl pkgs.curl pkgs.git
                  ]}"
              done

              # Install skill definitions
              cp SKILL.md $out/share/skillrunner/
              cp SETUP_SKILL.md $out/share/skillrunner/

              # Install service templates
              mkdir -p $out/share/skillrunner/templates
              cp templates/* $out/share/skillrunner/templates/
            '';
          };
        });

      # Home-Manager module for declarative installation
      homeManagerModules.default = import ./module/home-manager.nix self;
    };
}
