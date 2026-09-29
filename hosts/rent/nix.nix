{ port, sshDir, certFile }:

assert builtins.isInt port && port > 1023 && port < 65536;
assert builtins.isString sshDir && builtins.substring 0 1 sshDir == "/";
assert builtins.isString certFile;
# Host key and authorized keys live only in the state volume, never in the home.
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
  SetEnv SSL_CERT_FILE=${certFile} GIT_SSL_CAINFO=${certFile} NIX_SSL_CERT_FILE=${certFile} NIX_REMOTE=daemon
  PidFile /tmp/rent-sshd.pid
  Subsystem sftp internal-sftp
''
