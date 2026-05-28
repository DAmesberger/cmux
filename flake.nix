{
  description = "cmux — dev shell that pins Zig 0.15.2 (with the macOS 26 TBD fix) plus build companions.";

  inputs = {
    # Track nixpkgs-unstable so we get Zig 0.15.2 in `pkgs.zig_0_15`. The same
    # channel ghostty's flake uses, keeping the two stdenvs aligned.
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      # Zig 0.15.2 with the macOS 26 (Xcode 26.4+) TBD fix overlayed in.
      # Upstream Zig 0.15.2 can't link against the new SDK because Apple
      # merged `arm64-macos` into `arm64e-macos` in their TBD stub files.
      # Codeberg issue #31658 → PR #31673 fixes Zig's MachO linker; the
      # backport patch (kept identical to the one in `ghostty/nix/patches`)
      # lives at `nix/patches/zig-macos26-arm64e.patch`. Vendored rather
      # than pulled from the submodule so this flake's eval doesn't depend
      # on submodule files being tracked by git.
      #
      # Drop the override when ghostty migrates to Zig 0.16
      # (https://github.com/ghostty-org/ghostty/issues/12228) — 0.16 has the
      # fix natively.
      patchedZig =
        if pkgs.stdenv.hostPlatform.isDarwin
        then
          pkgs.zig_0_15.overrideAttrs (old: {
            patches = (old.patches or []) ++ [./nix/patches/zig-macos26-arm64e.patch];
          })
        else pkgs.zig_0_15;
    in {
      devShells.default = pkgs.mkShellNoCC {
        # `mkShellNoCC` (instead of `mkShell`) keeps stdenv's clang/cctools
        # out of the shell. That matters on Darwin: regular `mkShell`
        # exports `DEVELOPER_DIR` / `SDKROOT` pointing at a Nix-provided
        # apple-sdk that lacks `xcodebuild`, which then breaks
        # `scripts/reload.sh` with `tool 'xcodebuild' not found`. We want
        # the system Xcode to be the source of truth for the
        # `xcodebuild` step; this shell only pins the Zig + gettext that
        # Apple's tooling can't provide.
        name = "cmux";

        packages = [
          patchedZig
          pkgs.gettext # msgfmt — ghostty's locale install step calls it
        ];

        # Expose the resolved Zig path so `scripts/reload.sh` /
        # `scripts/build-ghostty-cli-helper.sh` pick it up via CMUX_ZIG
        # without having to relitigate which Zig is "the right one".
        shellHook = ''
          export CMUX_ZIG="${patchedZig}/bin/zig"
          echo "cmux dev shell — zig $(${patchedZig}/bin/zig version) [patched for macOS 26]"
        '';
      };

      # Re-export the patched Zig so other tools / CI / nested shells can
      # `nix build .#zig` without re-entering the dev shell.
      packages.zig = patchedZig;
    });
}
