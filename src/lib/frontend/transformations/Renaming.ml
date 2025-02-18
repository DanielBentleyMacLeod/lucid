open Batteries
open Syntax
open Collections

type kind = [%import: TyperUtil.kind]

module KindSet = TyperUtil.KindSet

(*** Do alpha-renaming to ensure that variable names are globally unique. Do the
    same for size names ***)

type env =
  { var_map : Cid.t CidMap.t
  ; size_map : Cid.t CidMap.t
  ; ty_map : Cid.t CidMap.t
  ; active : int (* Tells us which map to do lookups in at any given point *)
  ; module_defs : KindSet.t
  }

let empty_env =
  { var_map = CidMap.empty
  ; size_map = CidMap.empty
  ; ty_map = CidMap.empty
  ; active = 0
  ; module_defs = KindSet.empty
  }
;;

(* After going through a module body, add all the new definitions to the old
   environment, but with the module id as a prefix *)
let add_module_defs m_id old_env m_env =
  let prefix cid = Compound (m_id, cid) in
  let prefixed_maps =
    KindSet.fold
      (fun (k, cid) acc ->
        match k with
        | KSize ->
          let size = CidMap.find cid m_env.size_map |> prefix in
          { acc with size_map = CidMap.add (prefix cid) size acc.size_map }
        | KConstr | KConst ->
          let x = CidMap.find cid m_env.var_map |> prefix in
          { acc with var_map = CidMap.add (prefix cid) x acc.var_map }
        | KUserTy ->
          let x = CidMap.find cid m_env.ty_map |> prefix in
          { acc with ty_map = CidMap.add (prefix cid) x acc.ty_map }
        | KHandler -> acc)
      m_env.module_defs
      old_env
  in
  { prefixed_maps with
    module_defs =
      KindSet.union
        old_env.module_defs
        (KindSet.map (fun (k, id) -> k, prefix id) m_env.module_defs)
  }
;;

(* Unfortunately, scope isn't baked into the structure of our syntax the way it
   is in OCaml. This means that we need to maintain a global environment instead
   of threading it through function calls. This also means that we need to reset
   that environment at the end of each scope. A scope is created every time we
   recurse into a statement, except in SSeq. *)
let rename prog =
  let v =
    object (self)
      inherit [_] s_map as super

      val mutable env : env =
        let open Builtins in
        (* Builtin stuff doesn't get renamed *)
        let var_map =
          List.fold_left
            (fun env id -> CidMap.add (Id id) (Id id) env)
            CidMap.empty
            (start_id :: this_id :: List.map fst builtin_vars)
        in
        let builtin_cids =
          List.map fst (Arrays.constructors @ Counters.constructors)
          @ List.map
              (fun (gf : InterpState.State.global_fun) -> gf.cid)
              builtin_defs
        in
        let var_map =
          List.fold_left
            (fun env cid -> CidMap.add cid cid env)
            var_map
            builtin_cids
        in
        let ty_map =
          List.fold_left
            (fun env cid -> CidMap.add cid cid env)
            CidMap.empty
            [Arrays.t_id; Counters.t_id]
        in
        { empty_env with var_map; ty_map }

      method freshen_any active x =
        let new_x = Cid.fresh (Cid.names x) in
        (match active with
        | 0 ->
          env
            <- { env with
                 module_defs = KindSet.add (KConst, x) env.module_defs
               ; var_map = CidMap.add x new_x env.var_map
               }
        | 1 ->
          env
            <- { env with
                 module_defs = KindSet.add (KSize, x) env.module_defs
               ; size_map = CidMap.add x new_x env.size_map
               }
        | _ ->
          env
            <- { env with
                 module_defs = KindSet.add (KUserTy, x) env.module_defs
               ; ty_map = CidMap.add x new_x env.ty_map
               });
        new_x

      method freshen_var x = self#freshen_any 0 (Id x) |> Cid.to_id

      method freshen_size x = self#freshen_any 1 (Id x) |> Cid.to_id

      method freshen_ty x = self#freshen_any 2 (Id x) |> Cid.to_id

      method lookup x =
        let map =
          match env.active with
          | 0 -> env.var_map
          | 1 -> env.size_map
          | _ -> env.ty_map
        in
        match CidMap.find_opt x map with
        | Some x -> x
        | _ -> failwith @@ "Renaming: Lookup failed: " ^ Cid.to_string x

      method activate_var () = env <- { env with active = 0 }

      method activate_size () = env <- { env with active = 1 }

      method activate_ty () = env <- { env with active = 2 }

      method! visit_ty dummy ty =
        let old = env in
        self#activate_ty ();
        let ret = super#visit_ty dummy ty in
        env <- { env with active = old.active };
        ret

      method! visit_TName dummy cid sizes b =
        let old = env in
        self#activate_ty ();
        let cid = self#lookup cid in
        env <- { env with active = old.active };
        TName (cid, List.map (self#visit_size dummy) sizes, b)

      method! visit_size dummy size =
        let old = env in
        self#activate_size ();
        let ret = super#visit_size dummy size in
        env <- { env with active = old.active };
        ret

      (*** Replace variable uses. Gotta be careful not to miss any cases later
           on so we don't accidentally rewrite extra things ***)
      method! visit_id _ x = self#lookup (Id x) |> Cid.to_id

      method! visit_cid _ c = self#lookup c

      (*** Places we bind new variables ***)
      method! visit_SLocal dummy x ty e =
        let replaced_e = self#visit_exp dummy e in
        let new_ty = self#visit_ty dummy ty in
        let new_x = self#freshen_var x in
        SLocal (new_x, new_ty, replaced_e)

      method! visit_body dummy (params, body) =
        let old_env = env in
        let new_params =
          List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params
        in
        let new_body = self#visit_statement dummy body in
        env <- old_env;
        new_params, new_body

      (* Since many declarations have special behavior, we'll just override
         visit_d. *)
      method! visit_d dummy d =
        (* print_endline @@ "Working on:" ^ Printing.d_to_string d; *)
        match d with
        | DGlobal (x, ty, e) ->
          let replaced_ty = self#visit_ty dummy ty in
          let replaced_e = self#visit_exp dummy e in
          let new_x = self#freshen_var x in
          DGlobal (new_x, replaced_ty, replaced_e)
        | DSize (x, size) ->
          let replaced_size = Option.map (self#visit_size dummy) size in
          let new_x = self#freshen_size x in
          DSize (new_x, replaced_size)
        | DMemop (x, body) ->
          let replaced_body = self#visit_body dummy body in
          let new_x = self#freshen_var x in
          DMemop (new_x, replaced_body)
        | DEvent (x, s, cspecs, params) ->
          let old_env = env in
          let new_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
          env <- old_env;
          let new_x = self#freshen_var x in
          DEvent (new_x, s, new_cspecs, new_params)
        | DHandler (x, body) ->
          (* Note that we require events to be declared before their handler *)
          DHandler (self#lookup (Id x) |> Cid.to_id, self#visit_body dummy body)
        | DFun (f, rty, cspecs, (params, body)) ->
          let old_env = env in
          let new_rty = self#visit_ty dummy rty in
          let new_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
          let new_body = self#visit_statement dummy body in
          env <- old_env;
          let new_f = self#freshen_var f in
          DFun (new_f, new_rty, new_cspecs, (new_params, new_body))
        | DConst (x, ty, exp) ->
          let new_exp = self#visit_exp dummy exp in
          let new_ty = self#visit_ty dummy ty in
          let new_x = self#freshen_var x in
          DConst (new_x, new_ty, new_exp)
        | DExtern (x, ty) ->
          let new_ty = self#visit_ty dummy ty in
          let new_x = self#freshen_var x in
          DExtern (new_x, new_ty)
        | DSymbolic (x, ty) ->
          let new_ty = self#visit_ty dummy ty in
          let new_x = self#freshen_var x in
          DSymbolic (new_x, new_ty)
        | DGroup (x, es) ->
          let new_es = List.map (self#visit_exp dummy) es in
          let new_x = self#freshen_var x in
          DGroup (new_x, new_es)
        | DUserTy (id, sizes, ty) ->
          let new_sizes = List.map (self#visit_size ()) sizes in
          let new_ty = self#visit_ty () ty in
          let new_id = self#freshen_ty id in
          DUserTy (new_id, new_sizes, new_ty)
        | DConstr (id, ret_ty, params, e) ->
          let orig_env = env in
          let params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let e = self#visit_exp dummy e in
          env <- orig_env;
          let ret_ty = self#visit_ty () ret_ty in
          let id = self#freshen_var id in
          DConstr (id, ret_ty, params, e)
        | DModule (id, intf, body) ->
          let orig_env = env in
          env <- { env with module_defs = KindSet.empty };
          let body = self#visit_decls dummy body in
          let intf = self#visit_interface dummy intf in
          let new_env = add_module_defs id orig_env env in
          env <- new_env;
          DModule (id, intf, body)

      (*** Places we enter a scope ***)
      method! visit_SIf dummy test left right =
        let orig_env = env in
        let test' = self#visit_exp dummy test in
        let left' = self#visit_statement dummy left in
        env <- orig_env;
        let right' = self#visit_statement dummy right in
        env <- orig_env;
        SIf (test', left', right')

      method! visit_EComp dummy e i k =
        let old_env = env in
        let k = self#visit_size dummy k in
        let i = self#freshen_size i in
        let e = self#visit_exp dummy e in
        env <- old_env;
        EComp (e, i, k)

      method! visit_SLoop dummy s i k =
        let old_env = env in
        let k = self#visit_size dummy k in
        let i = self#freshen_size i in
        let s = self#visit_statement dummy s in
        env <- old_env;
        SLoop (s, i, k)

      method! visit_SMatch dummy es branches =
        let es = List.map (self#visit_exp dummy) es in
        let old_env = env in
        let branches =
          List.map
            (fun b ->
              let ret = self#visit_branch dummy b in
              env <- old_env;
              ret)
            branches
        in
        SMatch (es, branches)

      (*** Special Cases ***)
      method! visit_params dummy params =
        (* Don't rename parameters unless they're part of a body declaration *)
        List.map (fun (id, ty) -> id, self#visit_ty dummy ty) params

      (* Declaration-like things where we don't rename parts of them *)
      method! visit_InTy dummy id sizes tyo b =
        self#activate_ty ();
        let id = self#visit_id dummy id in
        self#activate_var ();
        let sizes = List.map (self#visit_size ()) sizes in
        let tyo = Option.map (self#visit_ty dummy) tyo in
        InTy (id, sizes, tyo, b)

      method! visit_InConstr dummy id ret_ty params =
        let id = self#visit_id dummy id in
        let ret_ty = self#visit_ty dummy ret_ty in
        let params = self#visit_params dummy params in
        InConstr (id, ret_ty, params)

      method! visit_InModule dummy id intf =
        InModule (id, self#visit_interface dummy intf)

      method! visit_InFun dummy id rty cspecs params =
        let new_id = self#visit_id dummy id in
        let old_env = env in
        let new_rty = self#visit_ty dummy rty in
        let new_params =
          List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params
        in
        let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
        env <- old_env;
        InFun (new_id, new_rty, new_cspecs, new_params)

      method! visit_InEvent dummy id cspecs params =
        let new_id = self#visit_id dummy id in
        let old_env = env in
        let new_params =
          List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params
        in
        let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
        env <- old_env;
        InEvent (new_id, new_cspecs, new_params)

      method! visit_FIndex dummy id eff =
        (* Don't rename the ids here, typing takes care of that *)
        FIndex (id, self#visit_effect dummy eff)

      (* Ids inside tqvars aren't variable IDs and shouldn't be renamed *)
      method! visit_TQVar dummy tqv =
        match tqv with
        | TVar { contents = Link x } -> self#visit_raw_ty dummy x
        | _ -> TQVar tqv

      method! visit_IVar dummy tqv =
        match tqv with
        | TVar { contents = Link x } -> self#visit_size dummy x
        | _ -> IVar tqv

      method! visit_FVar dummy tqv =
        match tqv with
        | TVar { contents = Link x } -> self#visit_effect dummy x
        | _ -> FVar tqv

      method rename prog =
        self#activate_var ();
        let renamed = self#visit_decls () prog in
        env, renamed
    end
  in
  v#rename prog
;;
