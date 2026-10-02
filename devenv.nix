{ pkgs, lib, config, ... }:

{
  languages.ruby.enable = true;
  languages.ruby.versionFile = ./web/.ruby-version;
  languages.ruby.bundler.enable = false;

  languages.python.enable = true;
  languages.python.package = pkgs.python313;
  languages.python.uv.enable = true;

  env.UV_PROJECT_ENVIRONMENT = lib.mkForce "${config.devenv.root}/pipeline/.venv";

  packages = with pkgs; [
    gnumake
    docker-compose
    postgresql_18
    git
    pkg-config
    libyaml
    openssl
    zlib
  ];

  enterShell = ''
    echo "mnemosyne  ruby $(ruby -e 'print RUBY_VERSION')  python $(python --version | cut -d' ' -f2)"
    if [ ! -f deploy/.env ]; then
      echo "  ! deploy/.env missing -- cp deploy/.env.example deploy/.env"
    fi
    if [ ! -x pipeline/.venv/bin/python ]; then
      echo "  ! pipeline/.venv missing -- cd pipeline && uv sync"
    fi
  '';
}
