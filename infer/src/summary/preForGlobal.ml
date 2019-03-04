(*
 * Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open Core
module F = Format
module L = Logging

module NameType : sig 
  include AbstractDomain.S
  val add : string -> Typ.t -> t -> t  
  val mem : string -> t -> bool
  val empty : t 
  val pp_m : t -> string
  val union : (string -> Typ.t -> Typ.t -> Typ.t option) -> t -> t -> t 
  val fold : (string -> Typ.t -> 'a -> 'a) -> t -> 'a -> 'a
end = struct
    module Base = Caml.Map.Make(String)

    type t = Typ.t Base.t

    let add s typ t = 
      Base.add s typ t

    let mem s t = Base.mem s t

    let empty = Base.empty

    let union f t1 t2 = Base.union f t1 t2

    let fold f t i = Base.fold f t i

    let pp_m m =  
        let fst = ref true in
        let f v l i = if !fst then (fst := false ; Printf.sprintf "%s%s -> %s" i v (Typ.to_string l)) else Printf.sprintf "%s, %s -> %s" i v (Typ.to_string l) in
        Printf.sprintf "%s]" (fold f m "[")

    (* top and bottom *)
    let top = empty

    (* is top or bottom? *)
    let is_top = Base.is_empty

    let tcomp = [%compare: Typ.t]

    let ( <= ) ~lhs ~rhs = 
        match Base.compare tcomp lhs rhs with
        | x when x <= 0 -> true
        | _ -> false

    let join lhs rhs = 
      let f k t1 t2 = 
        match tcomp t1 t2 with
        | 0 -> Some t1
        | _ -> failwith "cannot be joined."
      in
      union f lhs rhs

    let widen ~prev ~next ~num_iters = join prev next

    let pp f m = F.pp_print_string f (Printf.sprintf "%s" (pp_m m))
end

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = NameType

  type extras = ProcData.no_extras

  let get_glob_name pvar = 
    if Pvar.is_global pvar then
      let tu = Pvar.get_translation_unit pvar in
      match tu with
      | Some s -> 
          "#GB_" ^ (SourceFile.to_string s) ^ "_" ^ (Pvar.to_string pvar)
      | None -> 
          Pvar.to_string pvar
    else if Pvar.is_local pvar then
      Mangled.to_string (Pvar.get_name pvar)
    else failwith "no other variable types in C"

  let exec_expr m (expr : Exp.t) t do_strip : Domain.t =
      match expr with
      | Var i -> m
      | UnOp (op, e, typ) -> m
      | BinOp (op, e1, e2) -> m
      | Exn typ -> m
      | Closure f -> m
      | Const c -> m
      | Cast (typ, e) -> m
      | Lfield (e, fn, typ) -> m
      | Lindex (e1, e2) -> m
      | Sizeof data -> m
      | Lvar pvar -> 
              if Pvar.is_global pvar then
                if do_strip then
                  Domain.add (get_glob_name pvar) (Typ.strip_ptr t) m
                else 
                 Domain.add (get_glob_name pvar) t m
              else 
                  m

  let get_inst_type (i: Sil.instr) = 
    match i with
    | Load _ -> "Load"
    | Store _ -> "Store"
    | Prune _ -> "Prune"
    | Call _ -> "Call"
    | Nullify _ -> "Nullify"
    | Abstract _ -> "Abstract"
    | ExitScope _ -> "ExitScope"

  let pp_inst i = L.progress "[%s] %a\n@." (get_inst_type i) (Sil.pp_instr ~print_types:true Pp.text) i 

  let exec_instr astate proc_data node (instr: Sil.instr) =
      (*L.progress "PRE: %s\n@." (Domain.pp_m astate);
      pp_inst instr; *)
      let post = (
      match instr with
      | Load (id, e1, typ, loc) -> 
              exec_expr astate e1 typ false
      | Store (e1, typ, e2, loc) -> 
          let astate' = exec_expr astate e1 typ false in
          exec_expr astate' e2 typ true 
      | Prune (e, loc, b, i) -> astate
      | Call ((id, typ_e1), (Const (Cfun callee_pname)), args, loc, flag) -> 
          if (Typ.Procname.to_string callee_pname) = "__variable_initialization" then
            Caml.List.fold_left (fun i (e, t) -> exec_expr i e t false) astate args
          else
            Caml.List.fold_left (fun i (e, t) -> exec_expr i e t true) astate args
      | Call ((id, typ_e1), _, args, loc, flag) -> 
          failwith "C does not support this!"
      | Nullify (pid, loc) -> astate
      | Abstract loc -> astate
      | ExitScope (id_list, loc) -> astate
              ) in
    let node_kind = CFG.Node.kind node in
    let pname = Procdesc.get_proc_name proc_data.ProcData.pdesc in
    (*L.progress "POST: %s\n@." (Domain.pp_m post); *)
    post

    let pp_session_name _node fmt = F.pp_print_string fmt "C/C++ semantic summary analysis"
end

module Analyzer = AbstractInterpreter.MakeRPO (TransferFunctions (ProcCfg.Exceptional))

let summ = ref NameType.empty

module Procs : sig
    type typ
    val add : Typ.Procname.t -> Procdesc.t -> typ -> typ
    val find : Typ.Procname.t -> typ -> Procdesc.t
    val find_opt : Typ.Procname.t -> typ -> Procdesc.t option
    val empty : typ
    val find_first: (Typ.Procname.t -> bool) -> typ -> Typ.Procname.t * Procdesc.t
end = struct
    include Caml.Map.Make(Typ.Procname)
    type typ = Procdesc.t t
end

let procs = ref Procs.empty

module Storage : sig
    val store : NameType.t -> unit 
    val load : unit -> NameType.t
    val store_fun : Procs.typ -> unit 
    val load_fun : unit -> Procs.typ
end = struct
    let glob_env = "glob_env.dat"
    let func_env = "funcs.dat"

    let store a = 
        let oc = Pervasives.open_out glob_env in
        Marshal.to_channel oc a [];
        Pervasives.close_out oc

    let load () = 
        let ic = Pervasives.open_in glob_env in
        let res = Marshal.from_channel ic in
        Pervasives.close_in ic; res

    let store_fun a = 
        let oc = Pervasives.open_out func_env in
        Marshal.to_channel oc a [];
        Pervasives.close_out oc

    let load_fun () = 
        let ic = Pervasives.open_in func_env in
        let res = Marshal.from_channel ic in
        Pervasives.close_in ic; res
end

let checker {Callbacks.proc_desc; tenv; summary} : Summary.t =
    let proc_name = Procdesc.get_proc_name proc_desc in
    (
        procs := Procs.add proc_name proc_desc !procs;
        Storage.store_fun !procs
    );
    let merge node_id state = 
        let post = state.AbstractInterpreter.State.post in
        summ := NameType.union (fun x y z -> Some y) post !summ
    in 
    let proc_name_str = Typ.Procname.to_string (Procdesc.get_proc_name proc_desc) in
    let inv_map = Analyzer.exec_pdesc (ProcData.make_default proc_desc tenv) ~initial:(!summ) in
    Analyzer.InvariantMap.iter merge inv_map;
    Storage.store !summ;
    summary
