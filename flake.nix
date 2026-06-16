{
  description = "object capability-based sudo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-github-actions = {
      url = "github:nix-community/nix-github-actions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      nix-github-actions,
    }:
    let
      inherit (nixpkgs) lib;
      forEachSystem =
        f:
        builtins.listToAttrs (
          map
            (system: {
              name = system;
              value = f {
                inherit system;
                pkgs = nixpkgs.legacyPackages.${system};
              };
            })
            [
              "x86_64-linux"
              "aarch64-linux"
            ]
        );

      treefmtEval = (lib.flip treefmt-nix.lib.evalModule) ./nix/treefmt.nix;
    in
    {
      packages = forEachSystem (
        { pkgs, system }:
        {
          capsudo = pkgs.callPackage ./nix/package.nix { };
          default = self.packages.${system}.capsudo;
        }
      );
      devShells = forEachSystem (
        { pkgs, system }:
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = [
              pkgs.libxcrypt
              pkgs.clang-tools # for clang-format, LSP
              pkgs.bear # generate compile-commands.json
            ];
          };
        }
      );

      formatter = forEachSystem ({ pkgs, ... }: (treefmtEval pkgs).config.build.wrapper);
      checks = forEachSystem (
        { pkgs, system }:
        {
          formatting = (treefmtEval pkgs).config.build.check self;
          # todo: VM test
        }
        // self.packages.${system}
      );
      githubActions = nix-github-actions.lib.mkGithubMatrix {
        checks = { inherit (self.checks) x86_64-linux; };
      };

      overlays.default = final: prev: {
        capsudo = final.callPackage ./nix/package.nix { };
      };

      # todo: nixos module
      # todo: interactive test vm
    };
}
