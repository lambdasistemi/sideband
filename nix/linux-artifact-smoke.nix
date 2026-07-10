{ pkgs, system }:

pkgs.writeShellApplication {
  name = "linux-artifact-smoke";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.dpkg
    pkgs.rpm
    pkgs.cpio
  ];
  text = ''
    set -euo pipefail

    usage() {
      cat <<'USAGE'
    Usage: linux-artifact-smoke --artifacts-dir DIR --artifact-version VERSION

    Extracts and smoke-tests the Linux AppImage, DEB, and RPM release artifacts.
    USAGE
    }

    artifacts_dir=""
    artifact_version=""
    system_suffix="${system}"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --artifacts-dir)
          artifacts_dir="$2"
          shift 2
          ;;
        --artifact-version)
          artifact_version="$2"
          shift 2
          ;;
        --system-suffix)
          system_suffix="$2"
          shift 2
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          echo "unknown option: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done

    if [ -z "$artifacts_dir" ] || [ -z "$artifact_version" ]; then
      usage >&2
      exit 2
    fi

    artifacts_dir="$(cd "$artifacts_dir" && pwd)"
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    # Assert the wrapper around `sideband` carries a CA store
    # so live quote sources work on hosts whose `/etc/ssl/certs` shape
    # the bundled Haskell `tls` library can't read (e.g. NixOS).
    # Verifies four things end-to-end:
    #   1. the artifact ships a shell wrapper (not just the raw ELF),
    #   2. the wrapper sets `SSL_CERT_FILE` if it's unset in the env,
    #   3. the same goes for `SYSTEM_CERTIFICATE_PATH`,
    #   4. the wrapper's CA-bundle path exists inside the artifact's
    #      closure, and
    #   5. running the wrapper with both env vars explicitly unset
    #      still produces `--help` output — proving the wrapper
    #      override path is wired correctly.
    assert_ca_wrapper() {
      bin="$1"
      artifact_root="$2"

      head -1 "$bin" | grep -F '#! /nix/store' | grep -F 'bash' >/dev/null \
        || { echo "linux-artifact-smoke: $bin is not a /nix/store bash wrapper" >&2; exit 1; }

      grep -F "SSL_CERT_FILE=\''${SSL_CERT_FILE-" "$bin" >/dev/null \
        || { echo "linux-artifact-smoke: wrapper missing SSL_CERT_FILE default" >&2; exit 1; }

      grep -F "SYSTEM_CERTIFICATE_PATH=\''${SYSTEM_CERTIFICATE_PATH-" "$bin" >/dev/null \
        || { echo "linux-artifact-smoke: wrapper missing SYSTEM_CERTIFICATE_PATH default" >&2; exit 1; }

      ca_bundle_in_wrapper="$(
        grep -F "SSL_CERT_FILE=\''${SSL_CERT_FILE-" "$bin" \
          | sed -E "s/.*'(\\/nix\\/store[^']*)'.*/\\1/" \
          | head -1
      )"
      test -n "$ca_bundle_in_wrapper"

      ca_bundle_under_root="$artifact_root$ca_bundle_in_wrapper"
      test -f "$ca_bundle_under_root" \
        || { echo "linux-artifact-smoke: CA bundle missing in closure: $ca_bundle_under_root" >&2; exit 1; }

      env -u SSL_CERT_FILE -u SYSTEM_CERTIFICATE_PATH "$bin" --help \
        >/dev/null \
        || { echo "linux-artifact-smoke: wrapper failed --help with env vars unset" >&2; exit 1; }
    }

    smoke_cli() {
      bin="$1"
      test -x "$bin"

      # `tg --help` must work offline and list the core commands.
      help_start=$(date +%s)
      help_out="$("$bin" --help)"
      elapsed=$(( $(date +%s) - help_start ))
      printf '%s\n' "$help_out"
      for needle in send ask inbox daemon; do
        grep -F -- "$needle" <<<"$help_out" >/dev/null \
          || { echo "linux-artifact-smoke: 'tg --help' missing '$needle'" >&2; exit 1; }
      done

      if [ "$elapsed" -gt 10 ]; then
        printf 'linux-artifact-smoke: SLOW tg --help (%ss > 10s)\n' "$elapsed" >&2
        exit 1
      fi
    }

    smoke_appimage() {
      appimage="$artifacts_dir/sideband-$artifact_version-$system_suffix.AppImage"
      test -f "$appimage"
      appimage_dir="$workdir/appimage"
      mkdir -p "$appimage_dir"
      appimage_copy="$appimage_dir/sideband.AppImage"
      cp -L "$appimage" "$appimage_copy"
      chmod +x "$appimage_copy"
      (
        cd "$appimage_dir"
        "$appimage_copy" --appimage-extract >/dev/null
      )
      # In an extracted AppImage the wrapper sits in the
      # `*-with-ca` derivation, while the bundler also keeps the
      # unwrapped exe path on disk. Pick the wrapper (a shell script,
      # not an ELF), then drive both checks against it.
      bin="$(find "$appimage_dir" -path '*-with-ca*/bin/tg' \
        -type f -executable | head -1)"
      test -n "$bin" \
        || { echo "linux-artifact-smoke: AppImage wrapper not found" >&2; exit 1; }
      assert_ca_wrapper "$bin" "$appimage_dir/squashfs-root"
      smoke_cli "$bin"
    }

    smoke_deb() {
      deb="$artifacts_dir/sideband-$artifact_version-$system_suffix.deb"
      test -f "$deb"
      deb_dir="$workdir/deb"
      mkdir -p "$deb_dir"
      dpkg-deb -x "$deb" "$deb_dir"
      bin="$(find "$deb_dir" -path '*-with-ca*/bin/tg' \
        -type f -executable | head -1)"
      test -n "$bin" \
        || { echo "linux-artifact-smoke: DEB wrapper not found" >&2; exit 1; }
      assert_ca_wrapper "$bin" "$deb_dir"
      smoke_cli "$bin"
    }

    smoke_rpm() {
      rpm="$artifacts_dir/sideband-$artifact_version-$system_suffix.rpm"
      test -f "$rpm"
      rpm_dir="$workdir/rpm"
      mkdir -p "$rpm_dir"
      (
        cd "$rpm_dir"
        rpm2cpio "$rpm" | cpio -idm >/dev/null
      )
      bin="$(find "$rpm_dir" -path '*-with-ca*/bin/tg' \
        -type f -executable | head -1)"
      test -n "$bin" \
        || { echo "linux-artifact-smoke: RPM wrapper not found" >&2; exit 1; }
      assert_ca_wrapper "$bin" "$rpm_dir"
      smoke_cli "$bin"
    }

    smoke_appimage
    smoke_deb
    smoke_rpm
  '';
}
