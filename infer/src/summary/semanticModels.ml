open Pervasives
module L = Logging
module Domain = SemanticSummaryDomain
open Domain 

let fold_two_avs f lhs rhs base =
  let iter_lhs = fun (lhs_v, lhs_cst) base ->
    let iter_rhs = fun (rhs_v, rhs_cst) base ->
      f (lhs_v, lhs_cst) (rhs_v, rhs_cst) base
    in
    AVS.fold iter_rhs rhs base
  in
  AVS.fold iter_lhs lhs base

let sem_strcat: Var.t -> AVS.t list -> Env.t -> Heap.t -> CallLogs.t -> Domain.t =
  fun lhs_var args_avs env heap logs ->
    if (Caml.List.length args_avs) = 2 then
      let fst_avs = Caml.List.nth args_avs 0 in
      let snd_avs = Caml.List.nth args_avs 1 in
      let f = fun ((lhs_v: Val.t), lhs_cst) heap ->
        let lhs_loc = Val.to_loc lhs_v in
        let lhs_avs = Heap.find lhs_loc heap in
        let f' = fun ((rhs_v: Val.t), rhs_cst) avs ->
          let rhs_loc = Val.to_loc rhs_v in
          let rhs_avs = Heap.find rhs_loc heap in
          let f'' = fun ((lhs_v: Val.t), lhs_cst) ((rhs_v: Val.t), rhs_cst) base ->
            match lhs_v, rhs_v with 
            | Str lhs_s, Str rhs_s ->
                (match lhs_s, rhs_s with
                | Top, _ | _, Top -> 
                    AVS.add (Val.of_str SStr.top, (Cst.cst_and lhs_cst rhs_cst)) base
                | String s1, String s2 ->
                    AVS.add (Val.of_str (SStr.of_string (s1 ^ s2)), (Cst.cst_and lhs_cst rhs_cst)) base)
            | _ -> 
                AVS.add (Val.of_str SStr.top, (Cst.cst_and lhs_cst rhs_cst)) base
          in
          fold_two_avs f'' lhs_avs rhs_avs avs
        in
        let avs = AVS.fold f' snd_avs AVS.empty in
        let navs = HelperFunction.(avs ^ lhs_cst) in
        let preavs = HelperFunction.(lhs_avs ^ (Cst.cst_not lhs_cst)) in
        let () = L.progress "NAVS: %a\n@." AVS.pp navs in
        let () = L.progress "PREAVS: %a\n@." AVS.pp preavs in
        Heap.add lhs_loc (AVS.union navs preavs) heap
      in
      let heap' = AVS.fold f fst_avs heap in
      let res = Domain.make env heap' logs in
      let () = L.progress "Domain: %a\n@." Domain.pp res in
      res
    else
      failwith "strcpy function must take only two arguments."

let sem_strcpy: Var.t -> AVS.t list -> Env.t -> Heap.t -> CallLogs.t -> Domain.t =
  fun lhs_var args_avs env heap logs ->
    if (Caml.List.length args_avs) = 2 then
      let dst_avs = Caml.List.nth args_avs 0 in
      let src_avs = Caml.List.nth args_avs 1 in
      let rhs_avs = HelperFunction.load src_avs heap in
      let heap' = HelperFunction.store dst_avs rhs_avs heap in
      Domain.make env heap' logs
    else
      failwith "strcpy function must take only two arguments."


let models = [
  (*  "__new_array", sem_new_array
  ;*) "strcpy", sem_strcpy
  ; "strcat", sem_strcat
]

let is_modeled f = 
  let fname = Typ.Procname.to_string f in
  Caml.List.exists (fun (name, _) -> name = fname) models

let apply_semantics lhs_var fname args_avs env heap logs =
  let _, handler = Caml.List.find (fun (name, _) -> name = fname) models in
  handler lhs_var args_avs env heap logs

