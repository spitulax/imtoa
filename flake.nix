{
  description = "Image to ASCII";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    mypkgs.url = "github:spitulax/mypkgs";
  };

  outputs = { self, nixpkgs, mypkgs, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: lib.genAttrs systems f;
      pkgsFor = eachSystem (system:
        import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              odin = mypkgs.packages.${final.system}.odin;
            })
          ];
        });
    in
    {
      devShells = eachSystem (system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            name = "imtoa" + "-shell";
            nativeBuildInputs = with pkgs; [
              odin
              hexedit
            ];
            shellHook = "exec $SHELL";
          };
        }
      );
    };

  nixConfig = {
    extra-substituters = [
      "spitulax.cachix.org"
    ];
    extra-trusted-public-keys = [
      "spitulax.cachix.org-1:GQRdtUgc9vwHTkfukneFHFXLPOo0G/2lj2nRw66ENmU="
    ];
  };
}
