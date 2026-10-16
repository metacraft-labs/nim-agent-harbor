{
  description = "nim-agent-harbor - Agent Harbor REST/SSE client for Nim";

  inputs = {
    mcl-standard-hook-source = {
      url = "github:metacraft-labs/devops-modules/c8ef41d446e211892fe9775182b43d5d517554ac";
      flake = false;
    };
    managed-hook-reprobuild.url = "github:metacraft-labs/reprobuild/064daf5b154ea6a0758ddb2dcbcbc07685216e44";
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          # The tracked portable configuration is preserved as source. Native
          # activation runs the complete named set through guarded constructors.
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            fi
            unset _own_repo_root
          '';

          legacyPreCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
          # Preserve the original native 500 KB cap while adopting the complete
          # named standard set and retaining the merge-conflict and lint gates.
          standardHooks = import (inputs.mcl-standard-hook-source + "/git-hooks/standard-hooks.nix") {
            inherit pkgs;
            lib = pkgs.lib;
            src = inputs.mcl-standard-hook-source;
            maxKB = 500;
          };
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            configPath = ".pre-commit-config.nix.yaml";
            hooks = standardHooks // {
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
          nativeHookFactory =
            configuration:
            pkgs.runCommand "nim-agent-harbor-native-hook-factory"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.bash
                  configuration.config.package
                ];
              }
              ''
                export PRE_COMMIT_HOME="$TMPDIR/nim-agent-harbor-native-hook-cache"
                export XDG_CACHE_HOME="$TMPDIR/nim-agent-harbor-native-factory-cache"
                export GIT_CONFIG_GLOBAL="$TMPDIR/nim-agent-harbor-native-factory-gitconfig"
                export GIT_CONFIG_NOSYSTEM=1
                : > "$GIT_CONFIG_GLOBAL"
                mkdir -p "$PRE_COMMIT_HOME" "$XDG_CACHE_HOME" fixture
                cd fixture
                git init --template= >/dev/null
                if git config --get core.hooksPath; then
                  echo 'Unexpected native factory hooksPath authority' >&2
                  exit 1
                fi
                test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$PWD/.git/hooks"
                ln -s ${configuration.config.configFile} ${configuration.config.configPath}
                mkdir -p "$out"
                for hook in pre-commit pre-push; do
                  ${pkgs.lib.getExe configuration.config.package} install -c ${configuration.config.configPath} -t "$hook"
                  install -m 0755 ".git/hooks/$hook" "$out/$hook"
                done
              '';
          expectedNativeHook = nativeHookFactory preCommit;
          expectedLegacyNativeHook = nativeHookFactory legacyPreCommit;
          hookOwnershipGuard = ./nix/hook-ownership-guard.py;
          hookTransaction = ./nix/hook-transaction.py;
          actualNativeInstaller = pkgs.writeShellScript "nim-agent-harbor-native-hook-installer" preCommit.shellHook;
          managedHookConstructor = inputs.managed-hook-reprobuild.packages.${system}.reprobuild;
          guardedHookInstall = ''
            if [ -n "''${REPROBUILD_REPRO:-}" ] && [ "$REPROBUILD_REPRO" != "${managedHookConstructor}/bin/repro" ]; then
              echo 'Foreign inherited managed constructor authority' >&2
              exit 1
            fi
            export REPROBUILD_REPRO="${managedHookConstructor}/bin/repro"
            ${pkgs.python3}/bin/python3 ${hookTransaction} "$_own_repo_root" ${hookOwnershipGuard} ${expectedNativeHook} ${pkgs.git}/share/git-core/templates ${expectedLegacyNativeHook} ${preCommit.config.configFile} ${legacyPreCommit.config.configFile} ${actualNativeInstaller} ${pkgs.git}/bin/git ${pkgs.bash}/bin/bash >&2
            _nim_agent_harbor_hook_status=$?
            if [ "$_nim_agent_harbor_hook_status" -ne 0 ]; then
              unset _nim_agent_harbor_hook_status
              exit 1
            fi
            unset _nim_agent_harbor_hook_status
          '';
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            REPROBUILD_REPRO = "${managedHookConstructor}/bin/repro";
            NIM_AGENT_HARBOR_FULL_HOOK_CONFIG = preCommit.config.configFile;
            NIM_AGENT_HARBOR_EXPECTED_NATIVE_HOOKS = expectedNativeHook;
            NIM_AGENT_HARBOR_HOOK_INSTALLER = pkgs.writeShellScript "nim-agent-harbor-guarded-hook-installer" (
              ownRepoOnly guardedHookInstall
            );
            packages = [
              managedHookConstructor
              preCommit.config.package
            ]
            ++ preCommit.enabledPackages
            ++ (with pkgs; [
              nim
              nimble
              just
              nodejs
              nixfmt-rfc-style
              git
              bash
              python3
              direnv
              uv
            ]);
            shellHook = ''
              ${ownRepoOnly guardedHookInstall}
            '';
          };
          packages.native-hook-config = preCommit.config.configFile;
          packages.legacy-native-hook-config = legacyPreCommit.config.configFile;
          packages.expected-native-hooks = expectedNativeHook;
          packages.expected-legacy-native-hooks = expectedLegacyNativeHook;
          packages.managed-hook-constructor = managedHookConstructor;
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "nim-agent-harbor";
            version = builtins.readFile ./VERSION;
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src nim_agent_harbor.nimble VERSION README.md $out/
            '';
          };
        };
    };
}
