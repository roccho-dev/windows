{ port, certFile }:

assert builtins.isInt port && port > 1023 && port < 65536;
assert builtins.isString certFile;
''
  Port ${builtins.toString port}
  ListenAddress 0.0.0.0
  HostKey /home/dev/.ssh/ssh_host_ed25519_key
  AuthorizedKeysFile .ssh/authorized_keys
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin no
  AllowUsers dev
  UsePAM no
  SetEnv SSL_CERT_FILE=${certFile} GIT_SSL_CAINFO=${certFile}
  PidFile /tmp/rent-sshd.pid
  Subsystem sftp internal-sftp
''
