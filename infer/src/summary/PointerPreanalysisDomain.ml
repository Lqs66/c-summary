(*
 * Copyright (c) 2020, SW@ Laboratory at CNU.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open Core
open Pervasives
module F = Format
module L = Logging

module LocHolder = struct
  type t = AddrHolder of SemanticSummaryDomain.Loc.t
  | Holder of SemanticSummaryDomain.Loc.t
  | None
  [@@deriving compare]

  let none = None

  let mk_addr_holder (l: SemanticSummaryDomain.Loc.t) =
    match l with
    | Explicit _ | Implicit _ | Const _ | FunPointer _ | Ret _ | Offset _ -> AddrHolder l
    | Pointer (base, _, _) -> Holder base
    | LocTop -> failwith "Pointer analysis does not handle Location Top!"

  let mk_holder (l: SemanticSummaryDomain.Loc.t) = Holder l

  let is_addr_holder = function AddrHolder _ -> true | _ -> false

  let get_loc = function
    | Holder loc -> loc
    | AddrHolder loc -> loc
    | _ -> failwith "cannot get a location from none" 

  let get_offset = function
    | Holder loc -> (
      match loc with
      | Offset (base, offset) -> offset
      | _ -> failwith "It is not a offset location.")
    | _ ->
        failwith "It is not a location holder."

  let is_primitive = function
    | Holder loc -> (SemanticSummaryDomain.Loc.mk_implicit "primitive") = loc
    | _ -> false

  let is_offset = function
    | Holder loc -> (
      match loc with
      | Offset _ -> true 
      | _ -> false)
    | _ -> false

  let is_pointer = function
    | Holder loc -> (
      match loc with
      | Pointer _ -> true 
      | _ -> false)
    | _ -> false

  let pp fmt = function
    | AddrHolder l ->
        F.fprintf fmt "&(%a)" SemanticSummaryDomain.Loc.pp l
    | Holder l ->
        F.fprintf fmt "%a" SemanticSummaryDomain.Loc.pp l
    | None -> 
        F.fprintf fmt "None" 
end

module type Context = sig
  type t
  val empty : t
  val make : LocHolder.t -> CallSite.t -> t
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

let ctxt_depth = 1

module EveryWhere : Context = struct
  type t = EveryWhere
  [@@deriving compare]

  let empty = EveryWhere

  let make receiver callsite = EveryWhere

  let equal lhs rhs = true

  let pp fmt ctxt = F.fprintf fmt "EveryWhere"
end

module OBJContext : Context = struct
  type t = None
  | OBJ of LocHolder.t
  [@@deriving compare]

  let empty = None

  let make receiver callsite = OBJ receiver

  let equal lhs rhs = (compare lhs rhs) = 0

  let pp fmt = function
    | None -> 
        F.fprintf fmt " "
    | OBJ pk -> 
        F.fprintf fmt "%a" LocHolder.pp pk
end

module CSContext : Context = struct
  type t = None
  | CS of CallSite.t
  [@@deriving compare]

  let empty = None 

  let make receiver callsite = CS callsite

  let equal lhs rhs = (compare lhs rhs) = 0

  let pp fmt = function
    | None ->
        F.fprintf fmt " "
    | CS cs ->
        F.fprintf fmt "%a" CallSite.pp cs
end

module VVar = struct
  include SemanticSummaryDomain.VVar
end

module Loc = struct
  include SemanticSummaryDomain.Loc

  let primitive = mk_implicit "primitive"
end

(* Choose Context for Pointer analysis *)
module Ctxt = CSContext 

module PointerKey = struct
  type t = { holder: LocHolder.t; mutable ctxt: Ctxt.t list }
  [@@deriving compare]

  let mk_lpk_w_ctxt ctxt l = { holder = LocHolder.mk_addr_holder l; ctxt }

  let mk_pk_w_ctxt ctxt l = { holder = LocHolder.mk_holder l; ctxt }

  let mk_lpk (l: Loc.t) = mk_lpk_w_ctxt [] l

  let mk_pk (l: Loc.t) = mk_pk_w_ctxt [] l

  let is_primitive { holder } = LocHolder.is_primitive holder

  let get_holder { holder } = holder

  let get_ctxt { ctxt } = ctxt

  let is_offset { holder } = LocHolder.is_offset holder

  let is_pointer { holder } = LocHolder.is_pointer holder

  let is_complex o = is_offset o || is_pointer o

  (* Preserve the context *)
  let get_base_pk { holder; ctxt } =
    if LocHolder.is_addr_holder holder then
      failwith "It is a location holder."
    else
      let (loc: SemanticSummaryDomain.Loc.t) = LocHolder.get_loc holder in
      match loc with
      | LocTop | Explicit _ | Implicit _ | Const _ | FunPointer _ | Ret _ ->
          failwith (F.asprintf "Cannot get the base pointer key of %a." SemanticSummaryDomain.Loc.pp loc)
      | Pointer (base, _, _) -> 
          mk_pk_w_ctxt ctxt base
      | Offset (base, _) ->
          mk_pk_w_ctxt ctxt base

  let get_base_pk_opt pk = try Some (get_base_pk pk) with _ -> None

  let pp_ctxt fmt ctxt_list = 
    let rec impl fmt = function
      | [] -> F.fprintf fmt "]"
      | h :: [] -> F.fprintf fmt "%a ]" Ctxt.pp h
      | h :: t -> F.fprintf fmt "%a :: %a" Ctxt.pp h impl t
    in
    F.fprintf fmt "[ %a" impl ctxt_list

  let pp fmt { holder;  ctxt } = F.fprintf fmt "%a : %a" LocHolder.pp holder pp_ctxt ctxt

  let to_string pk = F.asprintf "%a" pp pk

  let copy { holder; ctxt } = { holder; ctxt }

  let assign_ctxt ctxt pk = if ctxt <> Ctxt.empty && ( Caml.List.length pk.ctxt ) < ctxt_depth then pk.ctxt <- (pk.ctxt @ [ctxt]) ; pk
end

module UnionFind = struct
  module Tree = struct
    module Node = struct
      type t = Nil
      | N of { mutable parent: t; pk: PointerKey.t }
      [@@deriving compare]

      let nil = Nil

      let mk_node l = N { parent = Nil; pk= l }

      let is_nil = function Nil -> true | _ -> false

      let is_root = function N n -> is_nil n.parent | _ -> false

      let get_parent = function N n -> n.parent | _ -> failwith "Nil"

      let set_parent p = function N n -> n.parent <- p | _ -> failwith "Nil"

      let get_pk = function N n -> n.pk | _ -> failwith "Nil"

      let rec pp fmt = function
        | Nil ->  
            Format.fprintf fmt "Nil"
        | N { parent; pk } ->
            Format.fprintf fmt "%a <- %a" pp parent PointerKey.pp pk

      let chg_pk pk n = 
        match n with
        | Nil -> failwith "cannot assign pk to Nil"
        | N { parent } -> N { parent ; pk = pk }
    end

    type t = Node.t
  end

  let rec find n =
    let open Tree.Node in
    if is_root n then n
    else 
      let p' = find (get_parent n) in
      (set_parent p' n; p')

  let union n1 n2 =
    let open Tree.Node in
    let root1 = find n1 in
    let root2 = find n2 in
    if root1 <> root2 then (
      if not (is_root root1) || not (is_root root2) then
        failwith "root must be nil!"
      else
        Tree.Node.set_parent root1 root2)
end

module Pk2NodeMap = struct
  module M = PrettyPrintable.MakePPMap(PointerKey) 

  include (M: module type of M with type 'a t := 'a M.t)

  type t = UnionFind.Tree.Node.t M.t
    
end

module InstEnv = struct
  module M = PrettyPrintable.MakePPMap(UnionFind.Tree.Node) 

  include (M: module type of M with type 'a t := 'a M.t)

  type t = UnionFind.Tree.Node.t M.t
end

type t = Pk2NodeMap.t

let mk_ctxt cs args = 
  let receiver = 
    if Caml.List.length args = 0 then
      LocHolder.none
    else 
      LocHolder.mk_addr_holder (Caml.List.hd args)
  in
  Ctxt.make receiver cs

(* NOTE: this function handles mutable structures! *)
let assign_context ctxt m = 
  let open UnionFind.Tree in
  let rec f pk n (ienv, m) =
    if n = Node.nil || InstEnv.mem n ienv then
      (ienv, m)
    else
      let pk' = PointerKey.copy pk |> PointerKey.assign_ctxt ctxt in
      let n' = Node.chg_pk pk' n in 
      let m' = Pk2NodeMap.add pk' n' m in
      let ienv' = InstEnv.add n n' ienv in (
        match InstEnv.find_opt (Node.get_parent n')ienv with
        | Some p ->
            (Node.set_parent p n'; (ienv', m'))
        | None ->
            let p = Node.get_parent n' in
            let (ienv'', m'') = f (Node.get_pk p) p (ienv', m') in
            (Node.set_parent (InstEnv.find p ienv'') n'); (ienv'', m''))
  in
  let _, m' = Pk2NodeMap.fold f m (InstEnv.add UnionFind.Tree.Node.nil UnionFind.Tree.Node.nil InstEnv.empty, Pk2NodeMap.empty) in
  m'

let join = Pk2NodeMap.union (fun k (n1: UnionFind.Tree.Node.t) (n2: UnionFind.Tree.Node.t) -> 
  if n1 = n2 then Some n1
  else (UnionFind.union n1 n2; Some n2))

let widen ~prev ~next ~num_iters = join prev next

let compare = Pk2NodeMap.compare (fun n1 n2 -> UnionFind.Tree.Node.compare n1 n2) 

let (<=) ~lhs ~rhs = if compare lhs rhs <= 0 then true else false

let pp = Pk2NodeMap.pp ~pp_value:UnionFind.Tree.Node.pp 

let mk_node l m = 
  match Pk2NodeMap.find_opt l m with
  | Some n -> (n, m)
  | None ->
      let n = UnionFind.Tree.Node.mk_node l in
      (n, Pk2NodeMap.add l n m)

let eq (lhs: PointerKey.t) (rhs: PointerKey.t) m =
  if PointerKey.is_primitive lhs || PointerKey.is_primitive rhs then
    m
  else
    let n_lhs, m' = mk_node lhs m in
    let n_rhs, m'' = mk_node rhs m' in
    let p_lhs = UnionFind.find n_lhs in
    let p_rhs = UnionFind.find n_rhs in
    let () = if p_lhs <> p_rhs then UnionFind.union n_lhs n_rhs in m''

let empty = Pk2NodeMap.empty

let is_implicit_root node =
  let open UnionFind.Tree.Node in
  let (loc: SemanticSummaryDomain.Loc.t) = get_pk node |> PointerKey.get_holder |> LocHolder.get_loc in
  match loc with
  | Implicit s -> String.is_prefix s ~prefix:"ROOT_"
  | _ -> false

  (*
let root_conversion m =
  let open UnionFind.Tree.Node in
  let convert pk node m =
    let m' = Pk2NodeMap.add pk node m in
    if is_root node && not (is_implicit_root node) then
      let new_root_pk = PointerKey.mk_pk_w_ctxt [] (SemanticSummaryDomain.Loc.mk_implicit ("ROOT_" ^ (PointerKey.to_string pk))) in
      let new_root_node = mk_node new_root_pk in
      (set_parent new_root_node node; Pk2NodeMap.add new_root_pk new_root_node m')
    else m'
  in
  Pk2NodeMap.fold convert m Pk2NodeMap.empty
  *)

let root_lift m = 
  let open SemanticSummaryDomain in
  let rec impl m = 
    let updated = ref false in
    let add_base pk cur_m = (
      match Pk2NodeMap.find_opt pk m with
      | Some n -> (n, cur_m)
      | None -> (
        match Pk2NodeMap.find_opt pk cur_m with
        | Some n -> (n, cur_m)
        | None -> (updated := true; mk_node pk cur_m)))
    in
    let rec lift pk n acc = 
      let m'' = Pk2NodeMap.add pk n acc in
      if PointerKey.is_pointer pk then
        let base = PointerKey.get_base_pk pk in
        let base_n, acc' = add_base base acc in
        let acc'' = lift base base_n acc' in
        let base_loc = UnionFind.find base_n |> UnionFind.Tree.Node.get_pk |> PointerKey.get_holder |> LocHolder.get_loc in
        let ctxt = PointerKey.get_ctxt base in
        let ptr_base_loc = Loc.mk_var_pointer base_loc in
        let ptr_base_pk = PointerKey.mk_pk_w_ctxt ctxt ptr_base_loc in 
        let ptr_base_n, acc''' = add_base ptr_base_pk acc'' in
        let ptr_base_root = UnionFind.find ptr_base_n in
        let n_root = UnionFind.find n in
        (if ptr_base_root <> n_root then
          begin
            updated := true;
            UnionFind.union n ptr_base_n;
            acc'''
          end
        else
          acc''')
      else if PointerKey.is_offset pk then
        let base = PointerKey.get_base_pk pk in
        let base_n, acc' = add_base base acc in
        let acc'' = lift base base_n acc' in
        let base_loc = UnionFind.find base_n |> UnionFind.Tree.Node.get_pk |> PointerKey.get_holder |> LocHolder.get_loc in
        let ctxt = PointerKey.get_ctxt base in
        let offset = PointerKey.get_holder pk |> LocHolder.get_offset in
        let off_base_loc = Loc.mk_offset base_loc offset in
        let off_base_pk = PointerKey.mk_pk_w_ctxt ctxt off_base_loc in 
        let off_base_n, acc''' = add_base off_base_pk acc'' in
        let off_base_root = UnionFind.find off_base_n in
        let n_root = UnionFind.find n in
        (if off_base_root <> n_root then
          begin
            updated := true;
            UnionFind.union n off_base_n;
            acc'''
          end
        else
          acc''')
      else
        m''
    in
    let new_m = Pk2NodeMap.fold lift m Pk2NodeMap.empty in
    (if !updated then
      impl new_m
    else
      new_m)
  in
  impl m

