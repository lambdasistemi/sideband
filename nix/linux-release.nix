{ pkgs
, system
, packageVersion
, artifactVersion ? packageVersion
, package
, bundlers
}:

# Wrap the executable so it carries a CA store inside its own closure.
#
# The Haskell `tls`/`x509-system` reads the host's `/etc/ssl/certs`
# directly. On NixOS that directory only contains `ca-bundle.crt`
# (no per-CA `.pem` files), so an AppImage run there sees an empty
# trust store and `swap-wizard --price-source` fails with
# `UnknownCa`. Exporting `SSL_CERT_FILE` / `SYSTEM_CERTIFICATE_PATH`
# from the dev shell already fixes the source build; the wrapper
# brings the same defaults to every release artifact.
#
# `--set-default` means an operator who already has a working
# `SSL_CERT_FILE` exported keeps it; the wrapper only fills in the
# fallback when the env is unset.
let
  packageWithCa = pkgs.symlinkJoin {
    name = "sideband-${packageVersion}-with-ca";
    # The executable is `tg`, not `sideband`; the bundlers use mainProgram
    # to find the AppImage/DEB/RPM entrypoint.
    meta.mainProgram = "tg";
    paths = [ package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for prog in $out/bin/*; do
        if [ -L "$prog" ]; then
          target=$(readlink -f "$prog")
          rm "$prog"
          makeWrapper "$target" "$prog" \
            --set-default SSL_CERT_FILE \
              ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
            --set-default SYSTEM_CERTIFICATE_PATH \
              ${pkgs.cacert}/etc/ssl/certs
        fi
      done
    '';
  };

  appImage = bundlers.bundlers.${system}.toAppImage packageWithCa;
  deb = bundlers.bundlers.${system}.toDEB packageWithCa;
  rpm = bundlers.bundlers.${system}.toRPM packageWithCa;
in
pkgs.runCommand
  "sideband-${artifactVersion}-${system}-artifacts"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.findutils ];
    passthru = {
      inherit appImage deb rpm packageWithCa;
    };
  } ''
  mkdir -p "$out"

  cp -L ${appImage} "$out/sideband-${artifactVersion}-${system}.AppImage"
  cp -L ${appImage} "$out/sideband.AppImage"

  deb_file="$(find ${deb} -maxdepth 1 -type f -name '*.deb' | head -1)"
  rpm_file="$(find ${rpm} -maxdepth 1 -type f -name '*.rpm' | head -1)"

  test -n "$deb_file"
  test -n "$rpm_file"

  cp "$deb_file" "$out/sideband-${artifactVersion}-${system}.deb"
  cp "$rpm_file" "$out/sideband-${artifactVersion}-${system}.rpm"

  (cd "$out" && sha256sum * > SHA256SUMS)
''
