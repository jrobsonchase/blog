{ lib
, stdenv
, zola
, tree
, baseURL ? "https://josh.robsonchase.com"
, drafts ? true
, drafts-path ? "wip"
}:
stdenv.mkDerivation {
  name = "blog-robsonchase-com${lib.optionalString (!drafts) "-stable"}";

  src = lib.cleanSourceWith {
    src = lib.cleanSource ./.;
    filter = path: _type: ! (lib.hasSuffix ".nix" path);
  };

  nativeBuildInputs = [
    zola
  ];

  buildPhase =
    let
      args = lib.concatStringsSep " " ([
        "-u"
        "${baseURL}"
      ]
      ++ (lib.optionals drafts [
        "--drafts"
      ]));
    in
    ''
      zola build ${args}
    '';

  installPhase = ''
    cp -a ./public $out
  '';
}
