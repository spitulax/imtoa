{ self, lib, inputs, mypkgs }: {
  default = final: prev: rec {
    imtoa = final.callPackage ./default.nix { };
    imtoa-debug = imtoa.override { debug = true; };
  };

  odin = final: prev: {
    odin = mypkgs.packages.${final.system}.odin;
  };
}
