#!/usr/bin/env ocaml
#use "topfind"
#require "topkg"
open Topkg

let () =
  Pkg.describe "mirage_ci" @@ fun c ->
  Ok [
    Pkg.lib "src/mirage-ci.mllib";
    Pkg.bin "src-bin/mirageCI";
    Pkg.bin "src-bin/avsmCI";
    Pkg.bin "src-bin/datakitToml";
  ]