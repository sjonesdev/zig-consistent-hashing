{ pkgs, lib, ... }: {
  apple.sdk = null;
  languages = {
    # devenv.sh/languages/zig/
    zig.enable = true;
  };
  enterShell = lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      export PATH="/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources:$PATH"

      if ! command -v debugserver >/dev/null; then
        echo "error: Xcode debugserver was not found"
        return 1
      fi
    '';
}
