open! IStd
open Core
module F = Format
module L = Logging
module Sem = SemanticFunctions

module PpSumm = struct
  let get_inst_type (i: Sil.instr) = 
    match i with
    |Load _ -> 
      "Load"
    | Store _ -> 
        "Store"
    | Prune _ -> 
        "Prune"
    | Call _ -> 
        "Call"
    | Nullify _ -> 
        "Nullify"
    | Abstract _ -> 
        "Abstract"
    | ExitScope _ -> 
        "ExitScope"

  let pp_inst fmt ((node, index), inst) = 
    let node_id = Procdesc.Node.get_id node in
    let inst_type = get_inst_type inst in
    F.fprintf fmt "%a: [%s] %a" Procdesc.Node.pp_id node_id inst_type (Sil.pp_instr ~print_types: true Pp.text) inst
end

module LocSet = PrettyPrintable.MakePPSet(SemanticSummaryDomain.Loc)

module TypMap = struct
  include PrettyPrintable.MakePPMap(
    struct 
      include Typ
      let pp = pp_full Pp.text
    end
  )

  let add typ loc map =  
    match find_opt typ map with
    | Some s ->
        let loc_set = LocSet.add loc s in
        add typ loc_set map
    | None ->
        add typ (LocSet.singleton loc) map 

  let pp = pp ~pp_value: LocSet.pp
end

module GlobalEnv = struct
  let glob_env = ref SemanticSummaryDomain.Env.empty

  let glob_heap = ref SemanticSummaryDomain.Heap.empty

  let glob_tmap = ref TypMap.empty

  let glob_locs = ref []

  let is_global_init = ref false
end

type env_t = SemanticSummaryDomain.Loc.t SemanticSummaryDomain.Env.t
type heap_t = SemanticSummaryDomain.AVS.t SemanticSummaryDomain.Heap.t
type typmap_t = LocSet.t TypMap.t

let get_global_heap () = !GlobalEnv.glob_heap
let get_global_locs () = !GlobalEnv.glob_locs

let is_struct = Typ.is_cpp_class

module CFG = ProcCfg.NormalOneInstrPerNode

module TransferFunctions = struct
  module CFG = CFG
  module Helper = HelperFunction
  module Domain = SemanticSummaryDomain.Domain
  open SemanticSummaryDomain

  type extras = ProcData.no_extras

  let opt_heap_every_stmt = false

  let mk_domain env heap logs = 
    if opt_heap_every_stmt then
      Domain.make env (Optimizer.opt_cst_in_heap heap) logs
    else
      Domain.make env heap logs

  let get_proc_summary ?caller callee_name = 
    let () = L.progress "Request summary of %s\n@." (Typ.Procname.to_string callee_name) in
    let sum = 
      match caller with
      | Some s -> (
        Ondemand.analyze_proc_name ~caller_pdesc:s callee_name)
      | None -> (
        Ondemand.analyze_proc_name callee_name)
    in
    match sum with
    | Some s -> (
        match s.Summary.payloads.Payloads.semantic_summary with
        | Some _ as o -> 
            o
        | None -> 
            None)
    | None -> 
        None

  let rec exec_expr : Loc.t Env.t -> AVS.t Heap.t -> Exp.t -> AVS.t * AVS.t Heap.t =
    fun env heap expr ->
      match expr with
      | Var i -> 
          let var = Var.of_id i in
          let loc = Env.find var env in
          Heap.find loc heap, heap
      | UnOp (op, e, typ) ->
          let v, heap' = exec_expr env heap e in
          AbstractOperators.unop op v, heap'
      | BinOp (op, e1, e2) -> 
          let lhs, heap' = exec_expr env heap e1 in
          let rhs, heap'' = exec_expr env heap' e2 in
          AbstractOperators.binop op lhs rhs, heap''
      | Exn typ ->
          (* do not handle exceptions *)
          AVS.top, heap
      | Closure f -> 
          failwith "C does not support anonymous functions"
      | Const c -> 
          (* only handle string constants *)
          (match c with
          | Cint s -> 
              let i = IntLit.to_int_exn s |> Int.of_int in
              AVS.singleton (Val.of_int i, Cst.cst_true), heap
          | Cfun _ ->
              AVS.bot, heap
          | Cstr s -> 
              let nloc = Loc.new_const_loc () in
              let str = SStr.of_string s in
              let heap' = Heap.add nloc (AVS.singleton (Val.of_str str, Cst.cst_true)) heap in
              AVS.singleton (Val.of_loc nloc, Cst.cst_true), heap'
          | Cfloat _ -> AVS.top, heap
          | Cclass _ -> AVS.bot, heap)
      | Cast (typ, e) ->
          (* TODO: need type casting? *)
          exec_expr env heap e
      | Lvar pvar -> (* Location of a variable *)
          let var = Var.of_pvar pvar in
          let loc = Env.find var env in
          AVS.singleton (Val.of_loc loc, Cst.cst_true), heap
      | Lfield (e, fn_tn, typ) -> (* Location of a field *)
          let fn = Typ.Fieldname.to_string fn_tn in
          let obj_loc_avs, heap' = exec_expr env heap e in
          let () = L.progress "Expr: %a, AVS: %a\n@." Exp.pp e AVS.pp obj_loc_avs in
          let it_obj_loc = fun (obj_loc_val, obj_loc_cst) avs ->
            let obj_ptr_avs = Val.to_loc obj_loc_val |> (fun x -> Heap.find x heap') in
            let it_obj_ptr = fun (obj_ptr, obj_ptr_cst) avs ->
              let obj_avs = Val.to_loc obj_ptr |> (fun x -> Heap.find x heap') in
              let it_obj = fun (obj, obj_cst) avs ->
                let obj_str = Val.to_struct obj in
                let f_loc = Struct.find fn obj_str in
                let f_val = Val.of_loc f_loc in
                let f_avs = AVS.singleton (f_val, obj_cst) in
                Helper.(avs + Helper.((f_avs ^ obj_loc_cst) ^ obj_ptr_cst))
              in
              AVS.fold it_obj obj_avs avs
            in
            AVS.fold it_obj_ptr obj_ptr_avs avs 
          in
          AVS.fold it_obj_loc obj_loc_avs AVS.empty, heap'
      | Lindex (e1, e2) -> 
          let index_avs, heap' = exec_expr env heap e2 in
          let arr_loc_avs, heap'' = exec_expr env heap' e1 in
          let arr_avs = Helper.indirect_load arr_loc_avs heap'' in
          Sem.handle_array_lookup arr_avs index_avs, heap''
      | Sizeof data -> 
          (* TODO: does not always return a constant 1 *)
          AVS.singleton (Val.of_int (Int.of_int 1), Cst.cst_true), heap
          (* AVS.singleton (Val.of_int (Int.top), Cst.cst_true) *)

  let exec_instr : Domain.t -> extras ProcData.t -> CFG.Node.t -> Sil.instr -> Domain.t = 
    fun {env; heap; logs} {pdesc; tenv; extras} node instr ->
      let () = L.progress "%a\n@." PpSumm.pp_inst (node, instr) in
      match instr with
      | Load (id, e1, typ, loc) -> 
          let lhs_var = Var.of_id id in
          let env' = 
            if Env.mem lhs_var env then 
              env
            else (* for temporal variables *)
              Env.add lhs_var (Loc.new_const_loc ()) env
          in
          let lhs_addr = Env.find lhs_var env' in
          let rhs_val, heap' = exec_expr env heap e1 in
          let rhs_avs = Helper.load rhs_val heap in
          let heap'' = Heap.add lhs_addr rhs_avs heap' in
          mk_domain env' heap'' logs
      | Store (Lvar pvar, typ, e2, loc) when Pvar.is_return pvar -> (* for return statements *)
          let rhs_avs, heap' = exec_expr env heap e2 in
          let mname = Typ.Procname.to_string (Procdesc.get_proc_name pdesc) in
          let ret_loc = Loc.mk_ret mname in
          let heap'' = Heap.weak_update ret_loc rhs_avs heap' in
          mk_domain env heap'' logs
      | Store (Lindex (arr, index), typ, e2, loc) -> 
          let lhs_avs, heap' = exec_expr env heap (Lindex (arr, index)) in
          let rhs_avs, heap''  = exec_expr env heap' e2 in
          let heap''' = Helper.store lhs_avs rhs_avs heap'' in
          mk_domain env heap''' logs
      | Store (e1 , typ, e2, loc) -> 
          (* let () = L.progress "Domain:%a\n@." Domain.pp (mk_domain env heap logs) in *)
          let lhs_avs, heap' = exec_expr env heap e1 in
          let rhs_avs, heap'' = exec_expr env heap' e2 in
          let heap''' = Helper.store lhs_avs rhs_avs heap'' in
          mk_domain env heap''' logs
      | Prune (e, loc, b, i) -> (* do not support heap pruning *)
          {env; heap; logs}
      | Call ((id, ret_typ), (Const (Cfun callee_pname)), args, loc, flag) when JniModel.is_jni callee_pname -> (* for jni function calls *)
          let lhs_var = Var.of_id id in
          let env' = 
            if Env.mem lhs_var env then
              env
            else (* for temporal variables *)
              Env.add lhs_var (Loc.new_const_loc ()) env
          in
          let lhs_loc = Env.find lhs_var env' in
          let ret_loc = Loc.new_const_loc () in
          let ret_loc_ptr = Loc.new_const_loc () in
          let heap' = Heap.add lhs_loc (AVS.singleton (Val.of_loc ret_loc, Cst.cst_true)) heap in
          let heap'' = Heap.add ret_loc (AVS.singleton (Val.of_loc ret_loc_ptr, Cst.cst_true)) heap' in
          let jnifun = JNIFun.of_procname callee_pname in
          let f = fun (arg_expr, _) (dumped_heap, arg_locs) ->
            let arg_loc = Loc.new_const_loc () in
            let arg_avs, heap' = exec_expr env' dumped_heap arg_expr in
            (Heap.add arg_loc arg_avs heap', arg_loc :: arg_locs)
          in
          let dumped_heap, arg_locs = 
            Caml.List.fold_right f args (heap'', []) 
          in
          let log = LogUnit.make ret_loc jnifun arg_locs dumped_heap in
          let logs' = CallLogs.add log logs in  
          mk_domain env' heap'' logs'
      | Call ((id, ret_typ), (Const (Cfun callee_pname)), args, loc, flag) when SemanticModels.is_modeled callee_pname -> (* for modeled functions for summary generation *)
          let lhs_var = Var.of_id id in
          let env' = 
            if Env.mem lhs_var env then
              env
            else (* for temporal variables *)
              Env.add lhs_var (Loc.new_const_loc ()) env
          in
          let lhs_loc = Env.find lhs_var env' in
          let args_avs, heap' = 
            Caml.List.fold_right (fun (arg_expr, _) (avs, heap) -> 
              let arg_avs, heap' = exec_expr env' heap arg_expr in
              arg_avs :: avs, heap') args ([], heap)
          in
          let {env; heap; logs} = SemanticModels.apply_semantics lhs_var (Typ.Procname.to_string callee_pname) args_avs env' heap' logs in
          mk_domain env heap logs 
      | Call ((id, ret_typ), (Const (Cfun callee_pname)), args, loc, flag) -> 
          let lhs_var = Var.of_id id in
          let env' = 
            if Env.mem lhs_var env then
              env
            else (* for temporal variables *)
              Env.add lhs_var (Loc.new_const_loc ()) env
          in
          let lhs_loc = Env.find lhs_var env' in
          (match Ondemand.get_proc_desc callee_pname with 
          | Some callee_desc -> (* no exisiting function: because of functions Infer made *)
              (match get_proc_summary ~caller:pdesc callee_pname with
              | Some ({ env = init_env
                      ; heap = init_heap
                      ; logs = init_logs }, 
                      { env = end_env
                      ; heap = end_heap
                      ; logs = end_logs }) ->
                let args_avs, heap' = 
                  Caml.List.fold_right (fun (arg_expr, _) (avs, heap) -> 
                    let arg_avs, heap' = exec_expr env' heap arg_expr in
                    arg_avs :: avs, heap') args ([], heap)
                in
                let ienv = 
                  Instantiation.mk_ienv tenv callee_desc args_avs init_env init_heap heap' (get_global_locs ()) (get_global_heap ())
                in
                let heap'' = 
                  Instantiation.comp_heap heap' heap' end_heap ienv 
                in
                let logs' = 
                  Instantiation.comp_log logs end_logs heap'' ienv 
                in
                let ret_loc = 
                  Loc.mk_ret_of_pname callee_pname 
                in
                let heap''' = 
                  (match Heap.find_opt ret_loc heap'' with
                  | Some avs -> 
                      Heap.add lhs_loc avs heap''
                  | None -> (* kind of passing parameter as a return value *)
                      let ret_param_var = Var.of_string "__return_param" in
                      (match Env.find_opt ret_param_var end_env with
                        | Some loc -> 
                            (match Heap.find_opt loc heap'' with
                            | Some avs ->
                              Heap.add lhs_loc avs heap''
                            | None ->
                              Heap.add lhs_loc (AVS.singleton (Val.bot, Cst.cst_true)) heap'')
                        | None -> 
                            Heap.add lhs_loc (AVS.singleton (Val.bot, Cst.cst_true)) heap'')
                   )
                in
                mk_domain env' heap''' logs'
              | None -> 
                  let () = L.progress "Not existing callee. Just ignore this call.\n@." in
                  {env; heap; logs}
                  )
          | None -> 
              let () = L.progress "Not existing callee. Just ignore this call.\n@." in
              {env; heap; logs})
      | Call _ ->
          failwith "This statement is not supported in C/C++!"
      | Nullify (pid, loc) -> 
          {env; heap; logs}
      | Abstract loc -> 
          {env; heap; logs}
      | ExitScope (id_list, loc) -> 
          {env; heap; logs}

  let pp_session_name _node fmt = F.pp_print_string fmt "C/C++ semantic summary analysis" 
end

module Analyzer = AbstractInterpreter.MakeWTO (TransferFunctions)

module Initializer = struct
  open SemanticSummaryDomain
    
  module Helper = HelperFunction


  let init_env : (Var.t * Typ.t) list -> Loc.t Env.t -> Loc.t Env.t =
    fun vars env ->
      let iter_var = fun env (var, typ) ->
        Env.add var (Loc.new_const_loc ()) env 
      in
      Caml.List.fold_left iter_var env vars 

  let get_struct typ tenv =
    match Typ.name typ with
    | Some s -> 
      (match Tenv.lookup tenv s with
      | Some s -> 
          s
      | None -> 
          failwith ("The structure cannot be found in a type environment: " ^ (Typ.to_string typ)))
    | _ -> failwith ("this typ is not a struct type: " ^ (Typ.to_string typ))

  let rec init_heap : 
    (Loc.t * bool * Typ.t) list 
    -> Tenv.t 
    -> heap_t
    -> typmap_t
    -> heap_t * typmap_t =
    (fun locs tenv heap tmap ->
      let is_gt = fun l1 l2 -> 
        (Loc.compare l1 l2) = 1 
      in
      let pos_aliases = fun loc typ tmap ->
        match TypMap.find_first_opt (fun typ' -> 
          typ'.Typ.desc = typ.Typ.desc
        ) tmap with
        | None -> 
            LocSet.empty 
        | Some (_, s) -> 
            LocSet.filter (is_gt loc) s (*|> LocSet.filter (Loc.is_pointer)*)
      in
      let rec iter_loc : (heap_t * typmap_t) -> (Loc.t * bool * Typ.t) -> (heap_t * typmap_t) =
        fun (heap, tmap) (loc, is_arg, typ) ->
          let desc = typ.Typ.desc in
          match desc with
          | Tptr (ptr_typ, kind) ->
              let ptr_loc = Loc.mk_pointer loc in
              let aliases = pos_aliases ptr_loc typ tmap in (*ptr_typ tmap in*)
              let iter_alias = fun alias_ptr (avs, cst) -> 
                let alias_eq_cst = Cst.cst_eq ptr_loc alias_ptr in
                let alias_cst = Cst.cst_and cst alias_eq_cst in
                let alias_val = Val.of_loc alias_ptr in
                let alias_avs = AVS.singleton (alias_val, alias_cst) in
                Helper.(avs + alias_avs), Cst.cst_and cst (Cst.cst_not alias_eq_cst)
              in
              let avs, cst = LocSet.fold iter_alias aliases (AVS.empty, Cst.cst_true) in
              let ptr_val = Val.of_loc ptr_loc in
              let avs' = AVS.add (ptr_val, cst) avs in
              let heap' = Heap.add loc avs' heap in
              if is_arg then
                iter_loc (heap', TypMap.add (*ptr_typ*) typ ptr_loc tmap) (ptr_loc, true, ptr_typ)
              else
                iter_loc (heap', tmap) (ptr_loc, false, ptr_typ)
          | Tstruct name ->
              mk_struct tenv heap tmap loc typ, tmap
          | Tarray {elt; length} ->
              mk_array tenv heap tmap loc typ, tmap
          | _ -> 
              let ptr_loc = Loc.mk_pointer loc in
              let ptr_val = Val.of_loc ptr_loc in
              let avs' = AVS.singleton (ptr_val, Cst.cst_true) in
              let heap' = Heap.add loc avs' heap in
              heap', tmap
      in
      Caml.List.fold_left iter_loc (heap, tmap) locs)

  and mk_struct : Tenv.t -> heap_t -> typmap_t -> Loc.t -> Typ.t -> heap_t = 
    fun tenv heap tmap loc typ ->
      if JniModel.is_jni_obj_typ typ then
        let nloc = Loc.new_const_loc () in
        let nloc_val = Val.of_loc nloc in
        Heap.add loc (AVS.singleton (nloc_val, Cst.cst_true)) heap
      else
        let s = get_struct typ tenv in
        let fill_up_fields = fun (str, heap) (field_tn, typ, _) ->
          let field = Typ.Fieldname.to_string field_tn in
          let nloc = Loc.new_const_loc () in
          let heap', tmap' = init_heap [nloc, true, typ] tenv heap tmap in
          (Struct.add field nloc str, heap')
        in
        let str, heap' = Caml.List.fold_left fill_up_fields (Struct.empty, heap) s.Typ.Struct.fields in
        let str_val = Val.of_struct str in
        let str_avs = AVS.singleton (str_val, Cst.cst_true) in
        let nloc = Loc.mk_pointer loc in
        let heap'' = Heap.add loc (AVS.singleton (Val.of_loc nloc, Cst.cst_true)) heap' in
        Heap.add nloc str_avs heap''

  and mk_array : Tenv.t -> heap_t -> typmap_t -> Loc.t -> Typ.t -> heap_t =
    fun tenv heap tmap loc typ ->
      let desc = typ.Typ.desc in
      match desc with
      | Tarray { elt; length = Some i } -> 
          let length = IntLit.to_int_exn i in
          let rec fill_up_index = fun (str, heap) cur_index ->
            if cur_index = length then
              str, heap
            else
              let nloc = Loc.new_const_loc () in
              let heap', tmap' = init_heap [nloc, true, elt] tenv heap tmap in
              fill_up_index (Struct.add (string_of_int cur_index) nloc str, heap') (cur_index + 1)
          in
          let str, heap' = fill_up_index (Struct.empty, heap) 0 in
          let str_val = Val.of_struct str in
          let str_avs = AVS.singleton (str_val, Cst.cst_true) in
         (* let nloc = Loc.mk_pointer loc in
          let heap'' = Heap.add loc (AVS.singleton (Val.of_loc nloc, Cst.cst_true)) heap' in *)
          Heap.add loc str_avs heap'
      | _ ->
          let () = L.progress "Do not handle dynamic size array" in
          heap          

  let exec_initializers env heap tmap global_vars =
    let handle: Pvar.t * Typ.t -> env_t * heap_t * typmap_t -> env_t * heap_t * typmap_t =
      fun (pvar, typ) (env, heap, tmap) ->
        match Pvar.get_initializer_pname pvar with
        | Some callee_pname -> (
            match TransferFunctions.get_proc_summary callee_pname with
            | Some (_, {env; heap; logs}) ->
                let () = L.progress "CALLEE: %a - %s\n@." (Pvar.pp Pp.text) pvar (Typ.Procname.to_string callee_pname)  in
                let var = Var.of_pvar pvar in
                let rec update_tmap env heap tmap loc (typ: Typ.t) =
                  match typ.desc with
                  | Tptr (typ', kind) ->
                      tmap
                  | Tstruct name ->
                      tmap
                  | Tarray { elt; length = Some i } ->
                      tmap
                in
                (env, heap, tmap)
            | None ->
                let () = L.progress "Cannot execute it!" in
                (env, heap, tmap))
        | None ->
            let () = L.progress "NONE? %a \n@." (Pvar.pp Pp.text) pvar in
            (env, heap, tmap)
    in
    Caml.List.fold_right handle global_vars (env, heap, tmap)

  let init_global : Tenv.t -> Loc.t Env.t * AVS.t Heap.t * LocSet.t TypMap.t =
    fun tenv ->
      let open GlobalEnv in
      if not !is_global_init then
        let globals = PreForGlobal.Storage.load () in
        let global_pvars = 
          (fun pvar typ res ->
            (pvar, typ) :: res)
          |> (fun x -> PreForGlobal.NameType.fold x globals [])
        in
        let global_vars = 
          (fun (pvar, typ) res ->
            (Var.of_pvar pvar, typ) :: res)
          |> (fun x -> Caml.List.fold_right x global_pvars [])
        in
        let env = init_env global_vars Env.empty in
        let iter_var = fun (var, typ) locs ->
          ((Env.find var env), true, typ) :: locs
        in
        let locs = Caml.List.fold_right iter_var global_vars [] in
        let tmap = Caml.List.fold_left (fun tmap (loc, _, typ) -> TypMap.add (Typ.mk (Tptr (typ, Pk_pointer))) loc tmap) TypMap.empty locs in
        let heap, tmap' = 
          init_heap locs tenv Heap.empty tmap
        in
        let (env', heap', tmap'') = exec_initializers env heap tmap' global_pvars in
        let () = is_global_init := true in
        let () = glob_env := env' in
        let () = glob_heap := heap' in
        let () = glob_tmap := tmap' in
        let () = glob_locs := locs in
        !glob_env, !glob_heap, !glob_tmap
      else
        !glob_env, !glob_heap, !glob_tmap

  let init : Tenv.t -> Procdesc.t -> env_t * heap_t =
    fun tenv pdesc ->
      let attrs = Procdesc.get_attributes pdesc in
      let iter_args = fun (arg, typ) ->
        (Var.of_string (Mangled.to_string arg), typ) 
      in
      let iter_locals : ProcAttributes.var_data -> Var.t * Typ.t = 
        fun {name; typ} ->
        (Var.of_string (Mangled.to_string name), typ)
      in
      let arg_vars = Caml.List.map iter_args attrs.formals in
      let local_vars = Caml.List.map iter_locals attrs.locals in
      let env, heap, tmap = init_global tenv in
      let env' = init_env (arg_vars @ local_vars) env in
      let iter_var = fun (var, typ) (locs, is_arg) ->
        (((Env.find var env'), is_arg, typ) :: locs, is_arg)
      in
      let locs_arg, _ = Caml.List.fold_right iter_var arg_vars ([], true) in
      let locs_loc, _ = Caml.List.fold_right iter_var local_vars ([], false) in
      let heap', _ = init_heap (locs_arg @ locs_loc) tenv heap tmap in
      let () = L.progress "INIT:\n ENV: %a\n HEAP: %a\n@." Env.pp env' Heap.pp heap' in
      env', heap'
end

let checker {Callbacks.proc_desc; tenv; summary} : Summary.t =
    let proc_name = Procdesc.get_proc_name proc_desc in
    if not (JniModel.is_jni proc_name) then (
        let () = L.progress "Analyzing a function %s\n@." (Typ.Procname.to_string proc_name) in
        let (env, heap) = Initializer.init tenv proc_desc in
        let before_astate = SemanticSummaryDomain.make env heap SemanticSummaryDomain.CallLogs.empty in
        let proc_data = ProcData.make_default proc_desc tenv in 
        match Analyzer.compute_post proc_data ~initial:before_astate with
        | Some p -> 
                let opt_astate = Optimizer.optimize p (Typ.Procname.to_string proc_name) in
        let session = incr summary.Summary.sessions ; !(summary.Summary.sessions) in
        let summ' = {summary with Summary.payloads = { summary.Summary.payloads with Payloads.semantic_summary = Some (before_astate, opt_astate)}; Summary.proc_desc = proc_desc; Summary.sessions = ref session} in
        Summary.store summ'; 
        (if JniModel.is_java_native proc_name then
          let ldg = LogDepGraph.mk_ldg opt_astate.logs in
          let dot_graph = LogDepGraph.DotPrinter.DotGraph.to_dot_graph ldg in
          let graph_str = F.asprintf "%a" LogDepGraph.DotPrinter.DotGraph.pp dot_graph in
          let oc = open_out ((Typ.Procname.to_string proc_name) ^ ".out") in
          let () = Printf.fprintf oc "%s" graph_str in
          close_out oc
        );
        L.progress "Final in %s: %a\n@." (Typ.Procname.to_string proc_name) SemanticSummaryDomain.pp opt_astate;
        summ'
        | None -> summary
    )
    else 
        (L.progress "Skiping analysis for a JNI function %s\n@." (Typ.Procname.to_string proc_name); summary)
