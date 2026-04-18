(lang dune 3.16)

(name valkey)

(generate_opam_files true)

(source
 (github valkey-io/ocaml-valkey))

(authors "Avi")

(maintainers "Avi")

(license MIT)

(package
 (name valkey)
 (synopsis "Modern Valkey client for OCaml 5 + Eio (RESP3-only)")
 (description "A Valkey client targeting OCaml 5.3+ and Valkey 7.2+. Eio-native, RESP3-only, no legacy baggage.")
 (depends
  (ocaml (>= 5.3.0))
  (eio (>= 1.3))
  (eio_main (>= 1.3))))
