{ pkgs, source }:
let
  # One selection, reused by Linux and the Windows compiler. The existing
  # nixpkgs lock owns font versions and upstream content hashes.
  choices = [
    {
      role = "ui";
      family = "IBM Plex Sans JP";
      package = pkgs.ibm-plex.sans-jp;
      directory = "share/fonts";
    }
    {
      role = "terminal";
      family = "PlemolJP Console NF";
      package = pkgs.plemoljp-nf;
      directory = "share/fonts/truetype/plemoljp-nf-console";
      # The font-only NF release omits a standalone license. Retain the
      # upstream license from the same version; do not weaken the packer gate.
      licenseSource = pkgs.runCommand "plemoljp-license" {} ''
        mkdir -p "$out"
        cp ${pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/yuru7/PlemolJP/v${pkgs.plemoljp-nf.version}/LICENSE";
          sha256 = "52bbb5e729acc62435831d20641ece6a919e610100285ba183ef4d7233fb1e9a";
        }} "$out/LICENSE"
      '';
    }
  ];
  policy = pkgs.writeText "font-selection.json" (builtins.toJSON (map (choice: {
    inherit (choice) role family;
    inherit (choice.package) version;
    directory = "${choice.package}/${choice.directory}";
    licenseSource = toString (choice.licenseSource or choice.package.src);
  }) choices));
  python = pkgs.python3.withPackages (ps: [ ps.fonttools ]);
  backend = pkgs.fetchurl {
    url = "https://github.com/PowerShell/DSC/releases/download/v3.3.0/DSC-3.3.0-x86_64-pc-windows-msvc.zip";
    sha256 = "3f8b27f648661903d066cc19d5a6e7a8c13bd07eb738d4d765ce7239619b8b5f";
  };
  fonts = pkgs.runCommand "common-fonts" { nativeBuildInputs = [ python ]; } ''
    python ${./pack.py} fonts ${policy} "$out"
  '';
  dist = pkgs.runCommand "windows-dist" { nativeBuildInputs = [ python ]; } ''
    python ${./pack.py} dist ${fonts} ${backend} ${./.} ${pkgs.lib.escapeShellArg source} "$out"
  '';
in {
  inherit fonts dist;
  check = pkgs.runCommand "windows-dist-check" {
    nativeBuildInputs = [ python pkgs.unzip ];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    python -m unittest discover -s ${./.} -p 'test_*.py' -v
    unzip -t ${dist}/windows-dist.zip
    touch "$out"
  '';
}
