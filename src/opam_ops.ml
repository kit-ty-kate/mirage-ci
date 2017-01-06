(*---------------------------------------------------------------------------
   Copyright (c) 2016 Anil Madhavapeddy. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open !Astring
open Datakit_ci
open Datakit_github
open Term.Infix
module OD = Opam_docker

module type V = sig
  open Term
  val build_archive : ?volume:Fpath.t -> Docker_build.t -> Docker_run.t -> string -> string t
  val run_package : ?volume:Fpath.t -> Docker_run.t -> Docker_build.image -> string -> string t * string
  val run_packages : ?volume:Fpath.t -> Docker_run.t -> Docker_build.image -> string list -> (string * string Datakit_ci.Term.t * string) list t
  val list_all_packages : Docker_run.t -> Docker_build.image -> string list t
  val list_revdeps : Docker_ops.t -> Docker_build.image -> string -> string list t
  val run_revdeps: ?volume:Fpath.t -> Docker_ops.t -> string list -> Docker_build.image -> unit t
end

open Docker_ops
module V1 = struct
  open !Dockerfile

  let build_archive ?volume docker_build_t docker_run_t rev =
    let dfile =
      let open Dockerfile in
      from ~tag:"alpine_ocaml-4.03.0" "ocaml/opam" @@
      OD.V1.set_opam_repo_rev rev in
    let hum = Fmt.strf "base image for opam archive (%s)" (String.with_range ~len:6 rev) in
    let volumes =
      match volume with
      | None -> []
      | Some h -> [h,(Fpath.v "/home/opam/opam-repository/archives")]
    in
    Docker_build.run docker_build_t ~pull:true ~hum dfile >>= fun img ->
    let cmd = ["sh";"-c";"sudo chown opam /home/opam/opam-repository/archives && opam admin make"] in
    Docker_run.run ~volumes ~tag:img.Docker_build.sha256 ~cmd docker_run_t 

  let list_all_packages t image =
    let cmd = ["opam";"list";"-a";"-s";"--color=never"] in
    Docker_run.run ~tag:image.Docker_build.sha256 ~cmd t >|=
    String.cuts ~empty:false ~sep:"\n" >|=
    List.map (fun s -> String.trim s)

  let list_revdeps {run_t} image pkg =
    let cmd = ["opam";"list";"-s";"--depends-on";pkg] in
    Docker_run.run ~tag:image.Docker_build.sha256 ~cmd run_t >|=
    String.cuts ~empty:false ~sep:"\n"

  let run_package ?volume t image pkg =
    let cmd = ["opam-ci-install";pkg] in
    let volumes =
      match volume with
      | None -> []
      | Some h -> [h,(Fpath.v "/home/opam/opam-repository/archives")]
    in
    let r = Docker_run.run ~volumes ~tag:image.Docker_build.sha256 ~cmd t in
    let b = Docker_run.branch ~volumes ~tag:image.Docker_build.sha256 ~cmd () in
    r, b

  let run_packages ?volume t image pkgs =
    List.map (fun pkg ->
      let t, branch = run_package ?volume t image pkg in
      pkg, t, branch
    ) pkgs |> fun r ->
    Term.wait_for_all (List.map (fun (a,b,_) -> (a,b)) r) |>
    Term_utils.ignore_failure ~on_fail:(fun _ -> ()) >>= fun () ->
    Term.return r

  let run_revdeps ?volume ({run_t;_} as t) packages image =
    List.map (fun pkg ->
      let terms =
        list_revdeps t image pkg >>=
        run_packages ?volume run_t image in
      let l = Fmt.strf "revdeps:%s" pkg in
      l, terms) packages |>
    Term.wait_for_all

end

module V2 = struct
  open !Dockerfile

  let build_archive ?volume docker_build_t docker_run_t rev =
    let dfile =
      from ~tag:"alpine_ocaml-4.03.0" "ocaml/opam-dev" @@
      OD.V2.set_opam_repo_rev rev @@
      run "echo 'archive-mirrors: [ \"file:///home/opam/opam-repository/cache\" ]' >> /home/opam/.opam/config"
    in
    let hum = Fmt.strf "base image for opam2 archive (%s)" (String.with_range ~len:6 rev) in
    let volumes =
      match volume with
      | None -> []
      | Some h -> [h,(Fpath.v "/home/opam/opam-repository/cache")]
    in
    Docker_build.run docker_build_t ~pull:true ~hum dfile >>= fun img ->
    let cmd = ["sh";"-c";"sudo chown opam /home/opam/opam-repository/cache && opam admin make"] in
    Docker_run.run ~volumes ~tag:img.Docker_build.sha256 ~cmd docker_run_t 

  let run_package ?volume t image pkg =
    let cmd = ["opam-ci-install";pkg] in
    let volumes =
      match volume with
      | None -> []
      | Some h -> [h,(Fpath.v "/home/opam/opam-repository/cache")]
    in
    let r = Docker_run.run ~volumes ~tag:image.Docker_build.sha256 ~cmd t in
    let b = Docker_run.branch ~volumes ~tag:image.Docker_build.sha256 ~cmd () in
    r, b

  let run_packages ?volume t image pkgs =
    List.map (fun pkg ->
      let t, branch = run_package ?volume t image pkg in
      pkg, t, branch
    ) pkgs |> fun r ->
    Term.wait_for_all (List.map (fun (a,b,_) -> (a,b)) r) |>
    Term_utils.ignore_failure ~on_fail:(fun _ -> ()) >>= fun () ->
    Term.return r

  let list_all_packages t image =
    let cmd = ["opam";"list";"-a";"-s";"--color=never";"--installable"] in
    Docker_run.run ~tag:image.Docker_build.sha256 ~cmd t >|=
    String.cuts ~empty:false ~sep:"\n" >|=
    List.map (fun s -> String.trim s)

  let list_revdeps {run_t} image pkg =
    let cmd = ["opam";"list";"-s";"--color=never";"--depends-on";pkg;"--installable"] in
    Docker_run.run ~tag:image.Docker_build.sha256 ~cmd run_t >|=
    String.cuts ~empty:false ~sep:"\n" >|=
    List.map (fun s -> String.trim s)

  let run_revdeps ?volume ({run_t;_} as t) packages image =
    List.map (fun pkg ->
      let terms =
        list_revdeps t image pkg >>=
        run_packages ?volume run_t image in
      let l = Fmt.strf "revdeps:%s" pkg in
      l, terms) packages |>
    Term.wait_for_all

end

let build_package {build_t;_} image pkg =
  let open !Dockerfile in
  let dfile =
    from image.Docker_build.sha256 @@
    run "opam-ci-install %s" pkg in
  let hum = Fmt.strf "opam install %s" pkg in
  Docker_build.run build_t ~hum dfile

let build_packages t image pkgs =
  let builds = List.map (fun pkg ->
    let t = build_package t image pkg in
    pkg, t
  ) pkgs in
  Term.wait_for_all builds >>= fun () ->
  let rec gather acc = function
    | [] -> Term.return (List.rev acc)
    | (l,hd)::tl -> hd >>= fun hd -> gather ((l,hd)::acc) tl in
  gather [] builds

let packages_from_diff ?(default=["ocamlfind"]) {pull_t;run_t;_} target =
  let opam_slug = Fmt.strf "%a" Repo.pp (Target.repo target) in
  match Target.id target with
  |`Ref _ -> Term.return default
  |`PR pr_num ->
(*    let time = Ptime_clock.now () in
    Docker_pull.run ~slug:"unikernel/mirage-ci" ~tag:"opam-diff" ~time pull_t >>= fun img -> *)
    let cmd = [opam_slug; string_of_int pr_num] in
    Docker_run.run ~tag:"unikernel/mirage-ci:opam-diff" ~cmd run_t >|=
    fun x -> String.cuts ~empty:false ~sep:"\n" x |> List.map String.trim

let run_revdeps ?volume ~opam_version docker_t packages img =
  match opam_version with
  |`V1 -> V1.run_revdeps ?volume docker_t packages img
  |`V2 -> V2.run_revdeps ?volume docker_t packages img

let distro_build ~packages ~target ~distro ~ocaml_version ~remotes ~typ ~opam_version ~opam_repo opam_t docker_t =
  (* Get the commits for the mainline opam repo *)
  let opam_repo, opam_repo_branch = opam_repo in
  Term.branch_head opam_repo opam_repo_branch >>= fun opam_repo_commit ->
  let opam_repo_remote = {Opam_docker.Remote.repo=opam_repo; commit=opam_repo_commit; full_remote=true} in
  (* Get commits for any extra OPAM remotes *)
  Term_utils.term_map_s (fun (repo,branch) ->
    Term.branch_head repo branch >|= fun commit ->
    {Opam_docker.Remote.repo; commit; full_remote=false}
  ) remotes >>= fun remotes ->
  let remotes = opam_repo_remote :: remotes in
  Term.target target >>= fun target ->
  Opam_build.run ~packages ~target ~distro ~ocaml_version ~remotes ~typ ~opam_version opam_t >>= fun df ->
  let hum = Fmt.(strf "base image for opam install %a" (list ~sep:sp string) packages) in
  Docker_build.run docker_t.Docker_ops.build_t ~pull:true ~hum df >>= fun img ->
  match packages with
  | [] -> Term.return ["base",img]
  | _ -> build_packages docker_t img packages

let primary_ocaml_version = "4.03.0"
let compiler_variants = ["4.02.3";"4.04.0";"4.04.0_flambda"]

let rec max_list acc sz = function
  | hd::tl when List.length acc > sz -> List.rev acc
  | hd::tl -> max_list (hd::acc) sz tl
  | [] -> List.rev acc

let run_phases ~revdeps ~packages ~remotes ~typ ~opam_version ~opam_repo opam_t docker_t target =
  let build ~distro ~ocaml_version =
    packages >>= fun packages ->
    distro_build ~packages ~target ~distro ~ocaml_version ~remotes ~typ ~opam_version ~opam_repo opam_t docker_t 
  in
  (* phase 1 *)
  let ubuntu = build "ubuntu-16.04" primary_ocaml_version in
  let phase1 = ubuntu >>= fun _ -> Term.return () in
  (* phase 2 revdeps *)
  let pkg_revdeps =
    ubuntu >>= fun ubuntu ->
    let ts = List.map (fun (l,img) ->
      let t = 
        packages >>= fun packages ->
        run_revdeps ~opam_version docker_t packages img in
      (Fmt.strf "revdep:%s" l), t
    ) (max_list [] 4 ubuntu) in
    Term.wait_for_all ts in
  let phase2 =
      Term_utils.after phase1 >>= fun () ->
      pkg_revdeps in
    (* phase 3 compiler variants *)
  let compiler_versions =
      List.map (fun oc ->
        let t = build "alpine-3.5" oc in
        ("OCaml "^oc), t
      ) compiler_variants in
    let phase3 =
      Term_utils.after phase1 >>= fun () ->
      Term.wait_for_all compiler_versions in
    (* phase 4 *)
    let debian = build "debian-stable" primary_ocaml_version in
    let ubuntu1604 = build "ubuntu-16.04" primary_ocaml_version in
    let centos7 = build "centos-7" primary_ocaml_version in
    let phase4 =
      Term_utils.after phase3 >>= fun () ->
      Term.wait_for_all [
        "Debian Stable", debian;
        "Ubuntu 16.04", ubuntu1604;
        "CentOS7", centos7 ] in
    (* phase 5 *)
    let debiant = build "debian-testing" primary_ocaml_version in
    let debianu = build "debian-unstable" primary_ocaml_version in
    let opensuse = build "opensuse-42.1" primary_ocaml_version in
    let fedora24 = build "fedora-24" primary_ocaml_version in
    let phase5 =
      Term_utils.after phase4 >>= fun () ->
      Term.wait_for_all [
        "Debian Testing", debiant;
        "Debian Unstable", debianu;
        "OpenSUSE 42.1", opensuse;
        "Fedora 24", fedora24 ]
    in
    let lf = Fmt.strf "%s %s" (match opam_version with |`V1 -> "V1.2" |`V2 -> "V2.0") in
    [   Term_utils.report ~order:1 ~label:(lf "Build") phase1;
        Term_utils.report ~order:3 ~label:(lf "Compilers") phase3;
        Term_utils.report ~order:4 ~label:(lf "Common Distros") phase4;
        Term_utils.report ~order:5 ~label:(lf "All Distros") phase5;
    ] @ (match revdeps with false -> [] | true ->
        [Term_utils.report ~order:2 ~label:(lf "Revdeps") phase2])
 
(*---------------------------------------------------------------------------
   Copyright (c) 2016 Anil Madhavapeddy

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)

