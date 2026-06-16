{
  lib,
  stdenv,
  libxcrypt,
}:
stdenv.mkDerivation {
  name = "capsudo";
  version = "0.1.3";

  src = lib.cleanSource ../.;

  strictDeps = true;
  __structuredAttrs = true;

  buildInputs = [
    libxcrypt
  ];

  makeFlags = [
    "PREFIX=$(out)"
  ];

  meta = {
    homepage = "https://github.com/kaniini/capsudo";
    license = lib.licenses.isc;
    mainProgram = "capsudo";
  };
}
