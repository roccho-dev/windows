# ownBinding is the declared own target; CI passes an alternate one to prove the projection.
{ pkgs, source, ownBinding ? builtins.fromJSON (builtins.readFile ../own/bindings/G6I3.json) }:
let
  # Read-only projection: the remote owner changes the accepted image/mount binding.
  # Windows never writes that source or depends on the retired Xpra fields.
  ownSpec = builtins.fromJSON (builtins.readFile ../own/spec.json);
  # A Binding Windows SSH path (%USERPROFILE%\.ssh\<name>) as the profile-relative form the runtime joins.
  profileRelative = path: let m = builtins.match ''%USERPROFILE%\\\.ssh\\([A-Za-z0-9._-]+)'' path; in
    assert m != null; ".ssh/${builtins.head m}";
  # The declared target's session and container; nothing here names a site.
  nocttyLaunch = { inherit (ownBinding) session container;
    shell = "/bin/sh"; windowSaveState = "never"; };
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
  # Official stable WinGet recovery, fetched only when a missing Store app needs it.
  # Bundle and inner app versions differ. These assets are not distribution payloads.
  microsoftPublisher = "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US";
  # Explicit machine-platform recovery only; not a normal Restore prerequisite.
  # Official stable bytes are verified by CI and fetched again before native deployment.
  wslPlatform = {
    architecture = "x64"; minimumBuild = 26100; minimumVersion = "2.9.3.0";
    feature = "VirtualMachinePlatform";
    appxName = "MicrosoftCorporationII.WindowsSubsystemForLinux"; publisherId = "8wekyb3d8bbwe";
    url = "https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi";
    size = 367669248;
    sha256 = "28b1a0d013640a2ac95898ea705fa186e5b4ff767a1c1b49257161bc106599c6";
    release = "stable"; version = "3.0.1.0";
    productCode = "{14CEDBC6-042F-4AB4-B177-BAFE1C16BC7A}";
    upgradeCode = "{6D5B792B-1EDC-4DE9-8EAD-201B820F8E82}";
    packageCode = "{8C6DA5D3-6340-4B41-A662-6580A3A559CD}";
    productName = "Windows Subsystem for Linux"; manufacturer = "Microsoft Corporation";
    publisher = microsoftPublisher; template = "x64;1033";
  };
  wingetBootstrap = {
    architecture = "x64";
    publisher = microsoftPublisher;
    publisherId = "8wekyb3d8bbwe";
    bundle = {
      url = "https://github.com/microsoft/winget-cli/releases/download/v1.29.380/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle";
      size = 217276577;
      sha256 = "65dea9c01ce08ee7b763366b27c0e651f97db857c11ca9b9c301826c10092f2e";
      name = "Microsoft.DesktopAppInstaller";
      version = "2026.917.151.0";
      entry = "AppInstaller_x64.msix";
      appVersion = "1.29.380.0";
    };
    dependencies = {
      url = "https://github.com/microsoft/winget-cli/releases/download/v1.29.380/DesktopAppInstaller_Dependencies.zip";
      size = 97760717;
      sha256 = "ba875afe9d190f61218985ac0292a99d1db710bf93e13c68944ca9d89f0d82d1";
      packages = map (p: p // { entry = "x64/${p.name}_${p.version}_x64.appx"; }) [
        { name = "Microsoft.VCLibs.140.00"; version = "14.0.33519.0"; }
        { name = "Microsoft.VCLibs.140.00.UWPDesktop"; version = "14.0.33728.0"; }
        { name = "Microsoft.WindowsAppRuntime.1.8"; version = "8000.616.304.0"; }
      ];
    };
  };
  # Release-asset locks. The bytes are never bundled; the build fetches them only
  # to verify the lock and pin the extracted file inventory; Restore must fetch
  # and verify them again before any effect. Paths are relative to
  # %LOCALAPPDATA% with '/' separators and must be names Windows recreates exactly.
  #   version     a digit first and no '-', so Programs/<name>-<version> splits one way only
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
  #   seed        optional: Chromium's initial_preferences, beside the executable, which pack.py
  #               writes from these font roles (families from choices); a file of the owned tree
  #               that Chromium reads only when it creates a profile (README)
  #   appPath     optional: the one HKCU App Paths name (<name>.exe, lowercase .exe) that launches the
  #               owned executable by name (Win+R); never the executable's own name when another
  #               product owns it (chrome.exe is Google Chrome's)
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
      seed = { path = "Chrome-bin/initial_preferences"; fonts = { proportional = "ui"; fixed = "terminal"; }; };
      appPath = "chromium.exe";
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
  # archive listing, and inventories the tree 7-Zip extracts: each file's sha256
  # and unpackedSize, the sum of their sizes (never written here by hand). The seed and
  # appPath are not part of the archive, so the inventory's input omits them.
  inventory = lock: let
    archive = pkgs.fetchurl { inherit (lock) url sha256; };
    upstream = builtins.removeAttrs lock [ "seed" "appPath" ];
  in pkgs.runCommand "package-inventory-${lock.name}" { nativeBuildInputs = [ python pkgs._7zz ]; } ''
    7zz l -slt ${archive} > listing.txt
    python ${./pack.py} listing listing.txt
    mkdir tree
    7zz x -y -otree ${archive} > /dev/null
    python ${./pack.py} inventory ${pkgs.writeText "${lock.name}-lock.json" (builtins.toJSON upstream)} ${archive} listing.txt tree "$out"
  '';
  ownResume = {
    inherit (ownBinding) expectHost container hostPort image;
    session = nocttyLaunch.session;
    volumes = [
      { name = ownBinding.volume; destination = ownSpec.stateMount; }
      { name = ownBinding.workVolume; destination = ownSpec.workMount; }
      { name = ownBinding.nixVolume; destination = ownSpec.nixMount; }
    ];
    ssh = { alias = ownBinding.sshAlias; identity = profileRelative ownBinding.windowsIdentityFile;
      knownHosts = profileRelative ownBinding.knownHostsFile; };
  };
  windowsChoices = pkgs.writeText "windows-restore-selection.json" (builtins.toJSON {
    noctty = {
      version = nocttyVersion;
      fontFamily = "PlemolJP Console NF";
      # Ordinary windows/tabs enter this existing normal-user OCI. Handoff
      # adopts the caller's PTY instead. No session/container is started here.
      launch = nocttyLaunch;
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
    inherit ownResume wingetBootstrap wslPlatform;
    packages = map (lock: lock // { inventory = "${inventory lock}"; }) packageLocks;
    # The desktop UI font face: the family of this role, set face-only in the six Win32 UI font slots
    # in HKCU WindowMetrics; ui-font.ahk reads the live faces only (no setter or compiler).
    typography = { desktop = "ui"; interpreter = "AutoHotkey"; };
    # Microsoft Store apps Restore installs when absent, by the official WinGet from the msstore source.
    # Not pinned: the Store serves and updates its current version, and installing needs the network.
    # An app present is never reinstalled or owned. A newly introduced package is ledgered;
    # removal is held pending disposable proof. Its data is never owned.
    # The ChatGPT desktop app's package family is OpenAI.Codex_2p2nqsd0c76g0.
    # appearance: the app's own font settings (its light and dark themes in the user's Codex config), written
    # through the app's bundled config service. fonts name roles of `choices`, written as quoted CSS families.
    # defaults are the app's own complete themes (initial.js `jq` of 26.928.1915.0, with accentSource), written
    # only where a theme is absent: a theme with fonts alone is invalid and dropped by the app. Of an existing
    # theme only the font leaves change (and a font Face, which would override the family, is removed).
    apps = [
      {
        name = "ChatGPT"; source = "msstore"; id = "9PLM9XGG6VKS"; package = "OpenAI.Codex"; publisherId = "2p2nqsd0c76g0";
        appearance = {
          fonts = { ui = "ui"; content = "ui"; code = "terminal"; };
          defaults = {
            light = { accent = "#339cff"; accentSource = "chatgpt"; contrast = 45; ink = "#1a1c1f"; opaqueWindows = false; surface = "#ffffff";
              semanticColors = { diffAdded = "#00a240"; diffRemoved = "#ba2623"; skill = "#924ff7"; }; };
            dark = { accent = "#339cff"; accentSource = "chatgpt"; contrast = 60; ink = "#ffffff"; opaqueWindows = false; surface = "#181818";
              semanticColors = { diffAdded = "#40c977"; diffRemoved = "#fa423e"; skill = "#ad7bf9"; }; };
          };
        };
      }
    ];
  });
  fonts = pkgs.runCommand "common-fonts" { nativeBuildInputs = [ python ]; } ''
    python ${./pack.py} fonts ${policy} "$out"
  '';
  dist = pkgs.runCommand "windows-dist" { nativeBuildInputs = [ python ]; } ''
    python ${./pack.py} platform ${pkgs.writeText "wsl-platform.json" (builtins.toJSON wslPlatform)} \
      ${pkgs.fetchurl { inherit (wslPlatform) url sha256; }}
    python ${./pack.py} bootstrap ${pkgs.writeText "winget-bootstrap.json" (builtins.toJSON wingetBootstrap)} \
      ${pkgs.fetchurl { inherit (wingetBootstrap.bundle) url sha256; }} \
      ${pkgs.fetchurl { inherit (wingetBootstrap.dependencies) url sha256; }}
    python ${./pack.py} dist ${fonts} ${noctty} ${cloudflared} ${windowsChoices} ${./.} ${pkgs.lib.escapeShellArg source} "$out"
  '';
in {
  inherit fonts dist python;
  # The production projection of ownBinding, exactly as windowsChoices carries it.
  ownProjection = { launch = nocttyLaunch; inherit ownResume; };
  check = pkgs.runCommand "windows-dist-check" {
    nativeBuildInputs = [ python pkgs.unzip ];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    python -m unittest discover -s ${./.} -p 'test_*.py' -v
    unzip -t ${dist}/windows-dist.zip
    touch "$out"
  '';
}
