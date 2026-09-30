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
  nocttyVersion = "1.3.131";
  noctty = pkgs.fetchurl {
    url = "https://github.com/amanthanvi/noctty/releases/download/v${nocttyVersion}/noctty-${nocttyVersion}-windows-x64-portable.zip";
    sha256 = "d776bd0e4507abd3a3d6e4a4b347d089960ad5171d0caeeb783e01dd4b0e15fd";
  };
  # The Windows OpenSSH ProxyCommand client: the official release of exactly the cloudflared version the rent image
  # runs (the locked nixpkgs), pinned by hash. A nixpkgs bump fails here until this pin is moved with it.
  cloudflaredVersion = assert pkgs.cloudflared.version == "2026.6.1"; pkgs.cloudflared.version;
  cloudflared = pkgs.fetchurl {
    url = "https://github.com/cloudflare/cloudflared/releases/download/${cloudflaredVersion}/cloudflared-windows-amd64.exe";
    sha256 = "5253e66f1f493c4e13539749f1aa86fd0c61e3072900fec29a44ba046a6d97e2";
  };
  # Release-asset locks. The bytes are never bundled; the build fetches them only
  # to verify the lock and pin the extracted file inventory; Restore must fetch
  # and verify them again before any effect. Paths are relative to
  # %LOCALAPPDATA% with '/' separators and must be names Windows recreates exactly.
  #   directory   the only owned effect: the inventoried per-file tree, current user only;
  #               no registry, shortcut, PATH or machine-scope effect. The inventory
  #               lists files only; an archive with a directory holding no file fails
  #               the build, so every directory is a parent of a listed file.
  #   executable  a required file of that tree
  #   existing    presence: an HKCU or HKLM Uninstall\<uninstallKey> entry with this
  #               DisplayName and Publisher makes the product preexisting, never absent,
  #               wherever that entry's own InstallLocation points. It is
  #               preexisting-match only when its DisplayVersion and the ProductVersion
  #               of <entry InstallLocation>/<existing.executable> equal version, else
  #               preexisting-drift (also when InstallLocation is missing or unreadable).
  #               Either way nothing is installed or written. existing.installLocation
  #               is only the expected current-user location, kept disjoint from directory.
  #   protected   runtime data the product uses but no mode owns, writes or removes
  packageLocks = [
    {
      # Hibbiki third-party build (the approved exception). sha256 is GitHub's
      # asset digest; sha1 is the one the publisher states on the release page.
      name = "Chromium";
      version = "154.0.8037.58";
      url = "https://github.com/Hibbiki/chromium-win64/releases/download/v154.0.8037.58-r1689415/chrome.7z";
      format = "7z";
      size = 443675526;
      sha256 = "c1b9d1384fe5e342d834c36e40aec905e6c534ca1292026a16293bc36d8b732c";
      sha1 = "b154facbc2e76d781c162a504953a81d8062c8ea";
      scope = "user";
      effect = "tree-extracted";
      directory = "Programs/chromium-154.0.8037.58";
      executable = "Chrome-bin/chrome.exe";
      existing = {
        uninstallKey = "Chromium";
        displayName = "Chromium";
        publisher = "The Chromium Authors";
        installLocation = "Chromium/Application";
        executable = "chrome.exe";
      };
      # Without --user-data-dir this build uses the synced profile's location.
      protected = [ "Chromium/User Data" ];
    }
    {
      # Official release; publisher SHA256 equals GitHub's asset digest.
      name = "AutoHotkey";
      version = "2.0.28";
      url = "https://github.com/AutoHotkey/AutoHotkey/releases/download/v2.0.28/AutoHotkey_2.0.28.zip";
      format = "zip";
      size = 3155126;
      sha256 = "b63be7548792b4ad0dfe424d91cc69376694ed2f758245b7a75a0c77d693b478";
      scope = "user";
      effect = "tree-extracted";
      directory = "Programs/autohotkey-2.0.28";
      executable = "AutoHotkey64.exe";
      existing = {
        uninstallKey = "AutoHotkey";
        displayName = "AutoHotkey (user)";
        publisher = "AutoHotkey Foundation LLC";
        installLocation = "Programs/AutoHotkey";
        executable = "v2/AutoHotkey64.exe";
      };
      protected = [ ];
    }
  ];
  # The fixed-output fetch checks sha256; pack.py checks size, sha1 and the
  # archive listing, and inventories the tree 7-Zip extracts.
  inventory = lock: let
    archive = pkgs.fetchurl { inherit (lock) url sha256; };
  in pkgs.runCommand "package-inventory-${lock.name}" { nativeBuildInputs = [ python pkgs._7zz ]; } ''
    7zz l -slt ${archive} > listing.txt
    python ${./pack.py} listing listing.txt
    mkdir tree
    7zz x -y -otree ${archive} > /dev/null
    python ${./pack.py} inventory ${pkgs.writeText "${lock.name}-lock.json" (builtins.toJSON lock)} ${archive} listing.txt tree "$out"
  '';
  windowsChoices = pkgs.writeText "windows-restore-selection.json" (builtins.toJSON {
    noctty = {
      version = nocttyVersion;
      fontFamily = "PlemolJP Console NF";
      # The HKCU String values the default-terminal handoff needs, as the vendor registration
      # wrote them on CI #58 (G4) without its own bookkeeping and descriptions; {install} is
      # %LOCALAPPDATA%\Programs\noctty-<version>. win.ps1 derives the keys to create below the
      # shared Software\Classes\CLSID and Interface roots, which are never owned.
      registration = [
        { key = ''Software\Classes\CLSID\{33368C6F-D328-410C-B225-26DC9F12C728}\LocalServer32''; name = ""; data = ''"{install}\noctty\noctty.exe"''; }
        { key = ''Software\Classes\CLSID\{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32''; name = ""; data = ''{install}\noctty\noctty-terminal-handoff-proxy.dll''; }
        { key = ''Software\Classes\CLSID\{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32''; name = "ThreadingModel"; data = "Both"; }
        { key = ''Software\Classes\Interface\{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}\ProxyStubClsid32''; name = ""; data = "{1D349824-21FB-46C7-ACF3-746EDC991D52}"; }
        { key = ''Software\Classes\Interface\{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}\ProxyStubClsid32''; name = ""; data = "{1D349824-21FB-46C7-ACF3-746EDC991D52}"; }
        { key = ''Software\Classes\Interface\{AA6B364F-4A50-4176-9002-0AE755E7B5EF}\ProxyStubClsid32''; name = ""; data = "{1D349824-21FB-46C7-ACF3-746EDC991D52}"; }
      ];
    };
    cloudflared.version = cloudflaredVersion;
    packages = map (lock: lock // { inventory = "${inventory lock}"; }) packageLocks;
  });
  fonts = pkgs.runCommand "common-fonts" { nativeBuildInputs = [ python ]; } ''
    python ${./pack.py} fonts ${policy} "$out"
  '';
  dist = pkgs.runCommand "windows-dist" { nativeBuildInputs = [ python ]; } ''
    python ${./pack.py} dist ${fonts} ${noctty} ${cloudflared} ${windowsChoices} ${./.} ${pkgs.lib.escapeShellArg source} "$out"
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
