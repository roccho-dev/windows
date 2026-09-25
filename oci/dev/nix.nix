# Helper-free windows-dev profile draft: no gh, no credential helper, no image.
{ pkgs }: {
  profile = pkgs.buildEnv {
    name = "windows-dev";
    paths = with pkgs; [ bash coreutils git cacert ];
    pathsToLink = [ "/bin" "/etc/ssl" ];
  };
}