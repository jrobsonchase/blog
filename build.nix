{ lib
, stdenv
, zola
, tree
, domain ? "josh.robsonchase.com"
, drafts ? false
, drafts-path ? "wip"
}:
stdenv.mkDerivation {
  name = "blog-robsonchase-com${lib.optionalString drafts "-drafts"}";

  src = ./.;

  nativeBuildInputs = [
    zola
    tree
  ];

  buildPhase =
    let
      args = lib.concatStringsSep " " ([

      ]
      ++ (lib.optionals drafts [
        "--drafts"
        "-u"
        "https://${domain}/${drafts-path}"
        "-o"
        "public/${drafts-path}"
      ]));
    in
    ''
      zola build ${args}
    '';

  installPhase = ''
    cp -a ./public $out
  '';
}
