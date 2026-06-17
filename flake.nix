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

      nixosModules.default =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          cfg = config.security.capsudo;
        in
        {
          options.security.capsudo = {
            enable = lib.mkEnableOption "capsudo";
            package = lib.mkPackageOption pkgs "capsudo" { } // {
              default = self.packages.${pkgs.stdenv.system}.default;
            };
            capabilities = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }: {
                    options = {
                      enable = lib.mkEnableOption "the ${name} capability" // {
                        default = true;
                      };
                      socket = {
                        path = lib.mkOption {
                          type = lib.types.pathWith {
                            inStore = false;
                            absolute = true;
                          };
                          default = "/run/capsudo/${name}";
                        };
                        mode = lib.mkOption {
                          type = lib.types.nonEmptyStr;
                          default = "0600";
                          description = "File permission bits for the socket";
                        };
                        user = lib.mkOption {
                          type = lib.types.nullOr lib.types.nonEmptyStr;
                          default = null;
                          description = "User owning the socket";
                        };
                        group = lib.mkOption {
                          type = lib.types.nullOr lib.types.nonEmptyStr;
                          default = null;
                          description = "Group owning the socket";
                        };
                      };
                      ignoreClientArgs = lib.mkOption {
                        type = lib.types.bool;
                        default = true;
                        description = "Ignore any client-provided arguments.";
                      };
                      ignoreClientEnv = lib.mkOption {
                        type = lib.types.bool;
                        default = true;
                        description = "Ignore any client-provided environment variables.";
                      };
                      program = lib.mkOption {
                        type = lib.types.nullOr lib.types.nonEmptyStr;
                        default = null;
                        description = "Program to execute for client requests.  If not specified, the daemon uses its built-in default behavior.";
                      };
                    };
                  }
                )
              );
              default = { };
              description = "The capabilites to install via capsudo";
            };
          };
          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];
            systemd =
              let
                enabledCapabilities = lib.filterAttrs (_: capability: capability.enable) cfg.capabilities;
              in
              {
                sockets = lib.mapAttrs' (
                  name: capability:
                  lib.nameValuePair "capsudo-${name}" {
                    wantedBy = [ "sockets.target" ];
                    before = [ "multi-user.target" ];
                    socketConfig = {
                      Accept = true;
                      ListenStream = capability.socket.path;
                      SocketMode = capability.socket.mode;
                      SocketUser = capability.socket.user;
                      SocketGroup = capability.socket.group;
                    };
                  }
                ) enabledCapabilities;
                services = lib.mapAttrs' (
                  name: capability:
                  lib.nameValuePair "capsudo-${name}@" {
                    serviceConfig = {
                      Type = "exec";
                      StandardInput = "socket";
                      ExecStart =
                        let
                          optionFormat = optionName: {
                            sep = " ";
                            explicitBool = false;
                            option = "-${optionName}";
                          };
                        in
                        lib.toString (
                          [ (lib.getExe' cfg.package "capsudod") ]
                          ++ (lib.cli.toCommandLine optionFormat {
                            f = capability.ignoreClientArgs;
                            E = capability.ignoreClientEnv;
                            k = true; # always keep environment from service manager
                          })
                          ++ lib.optionals (capability.program != null) [
                            capability.program
                          ]
                        );
                    };
                  }
                ) enabledCapabilities;
              };
          };
        };
      nixosConfigurations.capsudo-test-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (
            {
              modulesPath,
              lib,
              pkgs,
              ...
            }:
            {
              imports = [
                "${modulesPath}/virtualisation/qemu-vm.nix"
                self.nixosModules.default
              ];
              system.stateVersion = "26.05";
              virtualisation.graphics = false;
              security.capsudo = {
                enable = true;
                capabilities.default = {
                  socket.mode = "660";
                  socket.group = "wheel";
                  ignoreClientArgs = false;
                  ignoreClientEnv = false;
                };
                capabilities.id = {
                  socket.mode = "666"; # anyone can call
                  program = lib.getExe' pkgs.coreutils "id";
                };
                capabilities."true" = {
                  socket.mode = "666"; # anyone can call
                  program = lib.getExe' pkgs.coreutils "true";
                };
                capabilities.env = {
                  socket.mode = "666"; # anyone can call
                  program = lib.getExe' pkgs.coreutils "env";
                };
              };
              systemd.services."capsudo-env@".environment.FOO = "bar,buzz";
              users.users = {
                admin = {
                  isNormalUser = true;
                  extraGroups = [ "wheel" ];
                  password = "1234";
                };
                noadmin = {
                  isNormalUser = true;
                  password = "4321";
                };
              };
            }
          )
        ];
      };
    };
}
