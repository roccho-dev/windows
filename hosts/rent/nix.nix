{ port, sshDir, certFile }:

assert builtins.isInt port && port > 1023 && port < 65536;
assert builtins.isString sshDir && builtins.substring 0 1 sshDir == "/";
assert builtins.isString certFile;
# Host key and authorized keys live only in the state volume, never in the home. Sessions read no global or system
# Git configuration: credentials come only from a repository's own binding to the owner helper (#8-C).
''
  Port ${builtins.toString port}
  ListenAddress 0.0.0.0
  HostKey ${sshDir}/ssh_host_ed25519_key
  AuthorizedKeysFile ${sshDir}/authorized_keys
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin no
  AllowUsers dev
  UsePAM no
  SetEnv SSL_CERT_FILE=${certFile} GIT_SSL_CAINFO=${certFile} NIX_SSL_CERT_FILE=${certFile} NIX_REMOTE=daemon GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  PidFile /tmp/rent-sshd.pid
  Subsystem sftp internal-sftp
''
