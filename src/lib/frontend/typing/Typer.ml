open Syntax
open SyntaxUtils
open Batteries
open Collections
open Printing
open TyperUtil
open TyperUnify
open TyperInstGen
open TyperModules

let mk_ty rty = ty_eff rty (fresh_effect ())
let inst ty = instantiator#visit_ty (fresh_maps ()) ty

let check_constraints span err_str (env : env) end_eff constraints =
  match env.ret_ty, IdMap.is_empty env.indices with
  | None, true ->
    (* In this case, we're in a handler, and not inside a loop. This means we're
       not doing inference, we're just checking that the user's constraints
       imply the function's constraints. *)
    if not (TyperZ3.check_implies env.constraints constraints)
    then
      error_sp span
      @@ err_str
      ^ " in a handler may violate global order. (Did you include all the \
         necessary constraints when declaring the event?)";
    { env with current_effect = end_eff }
  | _ ->
    (* In this case, either we're not in a handler or we're in a loop body.
       We should record the new constraints and make sure they're still
       satisfiable *)
    let new_constraints = constraints @ env.constraints in
    if not (TyperZ3.check_sat new_constraints)
    then error_sp span @@ err_str ^ " violates the global order";
    { env with current_effect = end_eff; constraints = new_constraints }
;;

let infer_value v =
  let vty =
    match v.v with
    | VBool _ -> TBool
    | VInt n -> TInt (IConst (Integer.size n))
    | VGlobal _ | VEvent _ | VGroup _ ->
      failwith "Cannot write values of these types"
  in
  { v with vty = Some (mk_ty vty) }
;;

let infer_pattern p =
  match p with
  | PWild -> (fresh_type ()).raw_ty
  | PNum _ -> TInt (fresh_size ())
  | PBit ps -> TInt (IConst (List.length ps))
;;

let rec infer_exp (env : env) (e : exp) : env * exp =
  (* print_endline @@ "Inferring " ^ exp_to_string e; *)
  match e.e with
  | EVar cid ->
    let inst t = instantiator#visit_ty (fresh_maps ()) t in
    let t = lookup_var e.espan env cid in
    env, Some (inst t) |> wrap e
  | EVal v -> env, (infer_value v).vty |> wrap e
  | EInt (z, szo) ->
    ( env
    , (match szo with
      | None ->
        let new_size = fresh_size () in
        { e with
          e = EInt (z, Some new_size)
        ; ety = Some (mk_ty @@ TInt new_size)
        }
      | Some sz ->
        validate_size e.espan env sz;
        Some (mk_ty @@ TInt sz) |> wrap e) )
  | ESizeCast (sz, _) -> env, Some (mk_ty @@ TInt sz) |> wrap e
  | EOp (op, args) -> infer_op env e.espan op args
  | EHash (size, es) ->
    if List.length es < 2
    then error_sp e.espan "Must pass at least two arguments to hash";
    validate_size e.espan env size;
    let env, inf_es = infer_exps env es in
    let hd = List.hd inf_es in
    unify_ty hd.espan (Option.get hd.ety) (mk_ty @@ TInt (fresh_size ()));
    env, { e with e = EHash (size, inf_es); ety = Some (mk_ty @@ TInt size) }
  | ECall (f, args) ->
    let _, _, inferred_fty =
      (* Get type of f as if we used the var rule for the function *)
      infer_exp env { e with e = EVar f } |> textract
    in
    let env, inferred_args = infer_exps env args in
    let fty : func_ty =
      { arg_tys = List.map (fun arg -> Option.get arg.ety) inferred_args
      ; ret_ty = fresh_type ()
      ; start_eff = env.current_effect
      ; end_eff = fresh_effect ()
      ; constraints = ref []
      }
    in
    (* print_endline @@ "Inferred_fty: " ^ Printing.ty_to_string inferred_fty;
    print_endline @@ "fty: " ^ Printing.func_to_string fty; *)
    unify_raw_ty e.espan (TFun fty) inferred_fty.raw_ty;
    let new_env =
      check_constraints e.espan "Function call" env fty.end_eff
      @@ !(fty.constraints)
    in
    new_env, { e with e = ECall (f, inferred_args); ety = Some fty.ret_ty }
  | EProj (e, label) ->
    let env, inf_e = infer_exp env e in
    let expected_ty, entries =
      match Option.map inst @@ StringMap.find_opt label env.record_labels with
      | Some ({ raw_ty = TRecord lst } as ty) -> ty, lst
      | Some _ -> failwith "Impossible, I hope"
      | None -> error_sp e.espan @@ "Unknown label " ^ label
    in
    unify_ty e.espan expected_ty (Option.get inf_e.ety);
    let e_effect = (Option.get inf_e.ety).teffect in
    let idx, (_, raw_ret_ty) = List.findi (fun _ (l, _) -> l = label) entries in
    let ret_ty =
      ty_eff raw_ret_ty (wrap_effect e_effect [None, 0; None, idx])
    in
    env, { e with e = EProj (inf_e, label); ety = Some ret_ty }
  | ERecord entries ->
    let labels, es = List.split entries in
    let env, inf_es = infer_exps env es in
    let expected_ty =
      match StringMap.find_opt (List.hd labels) env.record_labels with
      | Some ty ->
        if (not env.in_global_def) && is_global ty
        then
          error_sp e.espan "Cannot dynamically create values of a global type"
        else inst ty
      | None -> error_sp e.espan @@ "Unknown label " ^ List.hd labels
    in
    let inf_ety =
      TRecord
        (List.map2 (fun l e -> l, (Option.get e.ety).raw_ty) labels inf_es)
      |> mk_ty
    in
    unify_ty e.espan expected_ty inf_ety;
    let inf_entries = List.combine labels inf_es in
    env, { e with e = ERecord inf_entries; ety = Some expected_ty }
  | EWith (base, entries) ->
    let labels, es = List.split entries in
    let expected_ty =
      match StringMap.find_opt (List.hd labels) env.record_labels with
      | Some ty ->
        if (not env.in_global_def) && is_global ty
        then
          error_sp e.espan "Cannot dynamically create values of a global type"
        else inst ty
      | None -> error_sp e.espan @@ "Unknown label " ^ List.hd labels
    in
    let env, inf_base, inf_basety = infer_exp env base |> textract in
    unify_raw_ty e.espan expected_ty.raw_ty inf_basety.raw_ty;
    let env, inf_es = infer_exps env es in
    let inf_entries = List.combine labels inf_es in
    let expected_entries =
      match TyTQVar.strip_links expected_ty.raw_ty with
      | TRecord entries -> entries
      | _ -> failwith "impossible"
    in
    List.iter
      (fun (l, e) ->
        let expected =
          try List.assoc l expected_entries with
          | Not_found ->
            Console.error_position e.espan
            @@ "Label "
            ^ l
            ^ " does not belong to the same type as label "
            ^ List.hd labels
        in
        unify_raw_ty e.espan (Option.get e.ety).raw_ty expected)
      inf_entries;
    env, { e with e = EWith (inf_base, inf_entries); ety = Some expected_ty }
  | ETuple es ->
    let env, inf_es = infer_exps env es in
    let eff = fresh_effect () in
    List.iteri
      (fun i e' ->
        if (not env.in_global_def) && is_global (Option.get e'.ety)
        then
          error_sp
            e'.espan
            "Cannot dynamically create tuples containing global types"
        else (
          let expected = wrap_effect eff [None, 0; None, i] in
          unify_effect e.espan expected (Option.get e'.ety).teffect))
      inf_es;
    let final_ety =
      ty_eff (TTuple (List.map (fun e -> (Option.get e.ety).raw_ty) inf_es)) eff
    in
    env, { e with e = ETuple inf_es; ety = Some final_ety }
  | EVector es ->
    let env, inf_es = infer_exps env es in
    let ety = fresh_type () in
    List.iteri
      (fun i e' ->
        if (not env.in_global_def) && is_global (Option.get e'.ety)
        then
          error_sp
            e'.espan
            "Cannot dynamically create vectors containing global types"
        else (
          let expected =
            { ety with teffect = wrap_effect ety.teffect [None, 0; None, i] }
          in
          unify_ty e.espan expected (Option.get e'.ety)))
      inf_es;
    let final_ety = TVector (ety.raw_ty, IConst (List.length es)) |> mk_ty in
    env, { e with e = EVector inf_es; ety = Some final_ety }
  | EIndex (e1, IUser (Id idx)) ->
    let env, inf_e1, inf_e1ty = infer_exp env e1 |> textract in
    let renamed_idx, expected_length =
      match IdMap.find_opt idx env.indices with
      | Some x -> x
      | None ->
        error_sp e.espan
        @@ "Index "
        ^ id_to_string idx
        ^ " was not declared in a for loop or comprehension"
    in
    let length = fresh_size () in
    let entry_ty = fresh_type () in
    let expected_ety =
      ty_eff (TVector (entry_ty.raw_ty, length)) (fresh_effect ())
    in
    unify_ty e1.espan inf_e1ty expected_ety;
    if List.exists
         (function
           | Some id, _ -> Id.equal id renamed_idx
           | _ -> false)
         (unwrap_effect inf_e1ty.teffect |> snd)
    then
      error_sp e.espan
      @@ Printf.sprintf
           "Index variable %s was already used as an index to a list \
            containing this one"
           (id_to_string renamed_idx);
    (try unify_size e.espan length expected_length with
    | CannotUnify ->
      error_sp e.espan
      @@ Printf.sprintf
           "Index %s has maximum value %s, but the list has length %s. These \
            values should be identical."
           (id_to_string idx)
           (size_to_string length)
           (size_to_string expected_length));
    let ety =
      Some { entry_ty with teffect = FIndex (renamed_idx, inf_e1ty.teffect) }
    in
    env, { e with e = EIndex (inf_e1, IUser (Id idx)); ety }
  | EIndex (e1, idx) ->
    let i =
      match idx with
      | IConst i -> i
      | _ ->
        error_sp e.espan
        @@ "Index "
        ^ size_to_string idx
        ^ " is neither a variable nor a constant."
    in
    let env, inf_e1, inf_e1ty = infer_exp env e1 |> textract in
    let length = fresh_size () in
    let entry_ty = fresh_type () in
    let expected_ety =
      ty_eff (TVector (entry_ty.raw_ty, length)) (fresh_effect ())
    in
    unify_ty e1.espan inf_e1ty expected_ety;
    (match STQVar.strip_links length with
    | IConst n ->
      if i >= n
      then
        error_sp e.espan
        @@ Printf.sprintf "Invalid index %d: list has length %d" i n
    | sz ->
      error_sp e.espan
      @@ "Invalid indexing operation: list must have a known length, not "
      ^ size_to_string sz);
    let ety =
      Some
        { entry_ty with
          teffect = wrap_effect inf_e1ty.teffect [None, 0; None, i]
        }
    in
    env, { e with e = EIndex (inf_e1, idx); ety }
  | EComp (e1, idx, sz) ->
    validate_size e.espan env sz;
    let renamed_idx = Id.freshen idx in
    (* Effect before starting the loop *)
    let initial_effect = env.current_effect in
    (* Abstract starting effect for typechecking the loop body *)
    let alpha_start = fresh_effect ~name:"start" () in
    let env1, inf_e1, inf_ety =
      infer_exp
        { env with
          indices = IdMap.add idx (renamed_idx, sz) env.indices
        ; current_effect = alpha_start
        }
        e1
      |> textract
    in
    unify_effect
      e1.espan
      inf_ety.teffect
      (FIndex (renamed_idx, fresh_effect ()));
    let alpha_start_id =
      match FTQVar.strip_links alpha_start with
      | FVar (TVar { contents = Unbound (id, _) }) -> id
      | _ -> failwith "impossible"
    in
    (* Effect at the end of the loop, in terms of renamed_idx and start_effect *)
    let end_effect = env1.current_effect in
    (* Constraints that we got from the loop body *)
    let loop_constraints = drop_constraints env env1 in
    (* Helper function for substituting renamed_idx and start_effect into the end_effect *)
    let subst_env i start = (renamed_idx, i), (alpha_start_id, start) in
    (* Helper function that does the substitution *)
    let inst_constraints i start =
      List.map (subst_loop#visit_constr (subst_env i start)) loop_constraints
    in
    (* Effect at start of loop iteration 0 *)
    let start_effect_0 = initial_effect in
    (* Effect at start of loop iteration 1 *)
    let start_effect_1 =
      subst_loop#visit_effect (subst_env 0 start_effect_0) end_effect
    in
    let c0 = inst_constraints 0 start_effect_0 in
    let c1 = inst_constraints 1 start_effect_1 in
    (* Effect after finishing execution of the loop *)
    let final_effect =
      if equiv_effect end_effect alpha_start
      then initial_effect
      else FSucc (drop_indexes renamed_idx end_effect)
    in
    (* Env after finishing execution of the loop *)
    let new_env =
      check_constraints
        e.espan
        "Comprehension "
        env
        final_effect
        (c0 @ c1 @ env.constraints)
    in
    ( new_env
    , { e with
        e = EComp (inf_e1, idx, sz)
      ; ety = Some (mk_ty (TVector (inf_ety.raw_ty, sz)))
      } )
  | EStmt (s, e1) ->
    let env, inf_s = infer_statement env s in
    let env, inf_e1, inf_e1ty = infer_exp env e1 |> textract in
    env, { e with e = EStmt (inf_s, inf_e1); ety = Some inf_e1ty }

and infer_op env span op args =
  let env, ty, new_args =
    match op, args with
    | Not, [e] ->
      let env, inf_e, inf_ety = infer_exp env e |> textract in
      unify_raw_ty span inf_ety.raw_ty TBool;
      env, mk_ty TBool, [inf_e]
    | (Neg | BitNot), [e] ->
      let env, inf_e, inf_ety = infer_exp env e |> textract in
      unify_raw_ty span inf_ety.raw_ty TBool;
      env, mk_ty (TInt (fresh_size ())), [inf_e]
    | (And | Or), [e1; e2] ->
      let env, inf_e1, inf_ety1 = infer_exp env e1 |> textract in
      let env, inf_e2, inf_ety2 = infer_exp env e2 |> textract in
      unify_raw_ty span inf_ety1.raw_ty TBool;
      unify_raw_ty span inf_ety2.raw_ty TBool;
      env, mk_ty TBool, [inf_e1; inf_e2]
    | (Eq | Neq), [e1; e2] ->
      let env, inf_e1, inf_ety1 = infer_exp env e1 |> textract in
      let env, inf_e2, inf_ety2 = infer_exp env e2 |> textract in
      unify_ty span inf_ety1 inf_ety2;
      env, mk_ty TBool, [inf_e1; inf_e2]
    | (Less | More | Leq | Geq), [e1; e2] ->
      let tsize = fresh_size () in
      let env, inf_e1, inf_ety1 = infer_exp env e1 |> textract in
      let env, inf_e2, inf_ety2 = infer_exp env e2 |> textract in
      unify_raw_ty span inf_ety1.raw_ty (TInt tsize);
      unify_raw_ty span inf_ety2.raw_ty (TInt tsize);
      env, mk_ty TBool, [inf_e1; inf_e2]
    | (Plus | Sub | SatPlus | SatSub | BitAnd | BitOr | BitXor), [e1; e2] ->
      let tsize = fresh_size () in
      let env, inf_e1, inf_ety1 = infer_exp env e1 |> textract in
      let env, inf_e2, inf_ety2 = infer_exp env e2 |> textract in
      unify_raw_ty span inf_ety1.raw_ty (TInt tsize);
      unify_raw_ty span inf_ety2.raw_ty (TInt tsize);
      env, mk_ty @@ TInt tsize, [inf_e1; inf_e2]
    | (LShift | RShift), [e1; e2] ->
      let tsize = fresh_size () in
      let env, inf_e1, inf_ety1 = infer_exp env e1 |> textract in
      let env, inf_e2, inf_ety2 = infer_exp env e2 |> textract in
      unify_raw_ty span inf_ety1.raw_ty (TInt tsize);
      unify_raw_ty span inf_ety2.raw_ty (TInt (fresh_size ()));
      env, mk_ty @@ TInt tsize, [inf_e1; inf_e2]
    | Conc, [e1; e2] ->
      let tsize1 = fresh_size () in
      let tsize2 = fresh_size () in
      let env, inf_e1, inf_ety1 = infer_exp env e1 |> textract in
      let env, inf_e2, inf_ety2 = infer_exp env e2 |> textract in
      unify_raw_ty span inf_ety1.raw_ty (TInt tsize1);
      unify_raw_ty span inf_ety2.raw_ty (TInt tsize2);
      env, mk_ty @@ TInt (add_sizes tsize1 tsize2), [inf_e1; inf_e2]
    | Cast out_size, [e] ->
      let tsize = fresh_size () in
      let env, inf_e, inf_ety = infer_exp env e |> textract in
      unify_raw_ty span inf_ety.raw_ty (TInt tsize);
      env, mk_ty @@ TInt out_size, [inf_e]
    | Slice (hi, lo), [e] ->
      (* FIXME: To be sound, we should also require that the size is at most hi.
                But we can't express that at the moment. *)
      if lo < 0 || lo > hi
      then error_sp span "Bad arguments to slice operator"
      else (
        let tsize = fresh_size () in
        let env, inf_e, inf_ety = infer_exp env e |> textract in
        unify_raw_ty span inf_ety.raw_ty (TInt tsize);
        env, mk_ty @@ TInt (IConst (hi - lo + 1)), [inf_e])
    | TGet (size, idx), [e] ->
      let env, inf_e, inf_ety = infer_exp env e |> textract in
      let expected_rtys = List.init size (fun _ -> (fresh_type ()).raw_ty) in
      let expected_ty = mk_ty @@ TTuple expected_rtys in
      unify_ty span inf_ety expected_ty;
      if idx < 0 || idx >= size
      then error_sp span "Invalid index in TGet operator";
      let final_ty =
        ty_eff
          (List.nth expected_rtys idx)
          (wrap_effect inf_ety.teffect [None, 0; None, idx])
      in
      env, final_ty, [inf_e]
    | ( ( Not
        | Neg
        | BitNot
        | And
        | Or
        | Eq
        | Neq
        | Less
        | More
        | Leq
        | Geq
        | Plus
        | Sub
        | SatPlus
        | SatSub
        | BitAnd
        | BitOr
        | BitXor
        | LShift
        | RShift
        | Conc
        | Cast _
        | Slice _
        | TGet _ )
      , _ ) ->
      error_sp span
      @@ "Wrong number of arguments to operator: "
      ^ e_to_string (EOp (op, args))
  in
  env, { e = EOp (op, new_args); ety = Some ty; espan = span }

and infer_exps env es =
  let env, es' =
    List.fold_left
      (fun (env, es') e ->
        let env', e' = infer_exp env e in
        env', e' :: es')
      (env, [])
      es
  in
  env, List.rev es'

and infer_statement (env : env) (s : statement) : env * statement =
  (* (match s.s with
  | SSeq _ | SNoop -> ()
  | _ -> print_endline @@ "Inferring " ^ stmt_to_string s); *)
  let env, stmt =
    match s.s with
    | SNoop -> env, s.s
    | SUnit e ->
      let env, inf_e, _ = infer_exp env e |> textract in
      env, SUnit inf_e
    | SRet eopt ->
      let err str = error_sp s.sspan @@ str ^ ": " ^ stmt_to_string s in
      let return env =
        { env with
          returned = true
        ; ret_effects = env.current_effect :: env.ret_effects
        }
      in
      begin
        match env.ret_ty, eopt with
        | None, _ -> err "Return outside of function body"
        | Some { raw_ty = TVoid }, None -> return env, SRet None
        | Some { raw_ty = TVoid }, Some _ ->
          err "Nonempty return inside void function body"
        | Some _, None -> err "Empty return inside non-void function body"
        | Some ty, Some e ->
          let env, inf_e, inf_ety = infer_exp env e |> textract in
          unify_ty s.sspan ty inf_ety;
          return env, SRet (Some inf_e)
      end
    | SLocal (id, ty, e) ->
      let env, inf_e, ety = infer_exp env e |> textract in
      unify_ty s.sspan ty ety;
      (match TyTQVar.strip_links ety.raw_ty with
      | TVoid ->
        error_sp s.sspan
        @@ "Cannot assign result of void function to variable: "
        ^ stmt_to_string s
      | _ -> ());
      ( { env with locals = CidMap.add (Id id) ty env.locals }
      , SLocal (id, ty, inf_e) )
    | SAssign (id, e) ->
      let env, inf_e, ety = infer_exp env e |> textract in
      (match CidMap.find_opt (Id id) env.locals with
      | Some rty -> unify_ty s.sspan rty ety
      | None ->
        (match CidMap.find_opt (Id id) env.consts with
        | Some _ ->
          error_sp s.sspan @@ "Assignment to constant variable " ^ Id.name id
        | None ->
          error_sp s.sspan @@ "Assignment to unbound variable " ^ Id.name id));
      (match TyTQVar.strip_links ety.raw_ty with
      | TVoid ->
        error_sp s.sspan
        @@ "Cannot assign result of void function to variable: "
        ^ stmt_to_string s
      | _ -> ());
      env, SAssign (id, inf_e)
    | SPrintf (str, es) ->
      let expected_tys = extract_print_tys s.sspan str in
      if List.length expected_tys <> List.length es
      then error_sp s.sspan "Incorrect number of arguments to printf statement";
      let env, inf_es = infer_exps env es in
      List.iter2
        (fun e ty -> unify_raw_ty s.sspan (Option.get e.ety).raw_ty ty)
        inf_es
        expected_tys;
      env, SPrintf (str, inf_es)
    | SIf (e, s1, s2) ->
      let env, inf_e, inf_ety = infer_exp env e |> textract in
      unify_raw_ty e.espan TBool inf_ety.raw_ty;
      let env1, inf_s1 = infer_statement env s1 in
      let env2, inf_s2 = infer_statement env s2 in
      let env =
        { env with
          returned = env1.returned && env2.returned
        ; constraints = drop_constraints env env1 @ env2.constraints
        ; ret_effects = drop_ret_effects env env1 @ env2.ret_effects
        }
      in
      let current_effect =
        match env1.returned, env2.returned with
        | true, true -> env.current_effect
        | false, true -> env1.current_effect
        | true, false -> env2.current_effect
        | false, false ->
          (try
             TyperZ3.find_max
               env.constraints
               env1.current_effect
               env2.current_effect
           with
          | TyperZ3.NoMax ->
            Console.error_position
              s.sspan
              "Unable to determine which globals have been used at end of if \
               statement; neither branch ends obviously later than the other.")
      in
      { env with current_effect }, SIf (inf_e, inf_s1, inf_s2)
    | SGen (b, e) ->
      let env, inf_e, ety = infer_exp env e |> textract in
      unify_raw_ty s.sspan ety.raw_ty (TEvent b);
      env, SGen (b, inf_e)
    | SSeq (s1, s2) ->
      let env, inf_s1 = infer_statement env s1 in
      let env, inf_s2 = infer_statement env s2 in
      env, SSeq (inf_s1, inf_s2)
    | SMatch (es, bs) ->
      let env, inf_es = infer_exps env es in
      let env, inf_bs =
        infer_branches
          env
          s
          (List.map (fun e -> (e.ety |> Option.get).raw_ty) inf_es)
          bs
      in
      env, SMatch (inf_es, inf_bs)
    | SLoop (s1, idx, sz) ->
      validate_size s.sspan env sz;
      let renamed_idx = Id.freshen idx in
      (* Effect before starting the loop *)
      let initial_effect = env.current_effect in
      (* Abstract starting effect for typechecking the loop body *)
      let alpha_start = fresh_effect ~name:"start" () in
      let env1, inf_s1 =
        infer_statement
          { env with
            indices = IdMap.add idx (renamed_idx, sz) env.indices
          ; current_effect = alpha_start
          }
          s1
      in
      let alpha_start_id =
        match FTQVar.strip_links alpha_start with
        | FVar (TVar { contents = Unbound (id, _) }) -> id
        | _ -> failwith "impossible"
      in
      (* Effect at the end of the loop, in terms of renamed_idx and start_effect *)
      let end_effect = env1.current_effect in
      (* Constraints that we got from the loop body *)
      let loop_constraints = drop_constraints env env1 in
      (* Helper function for substituting renamed_idx and start_effect into the end_effect *)
      let subst_env i start = (renamed_idx, i), (alpha_start_id, start) in
      (* Helper function that does the substitution *)
      let inst_constraints i start =
        List.map (subst_loop#visit_constr (subst_env i start)) loop_constraints
      in
      (* Effect at start of loop iteration 0 *)
      let start_effect_0 = initial_effect in
      (* Effect at start of loop iteration 1 *)
      let start_effect_1 =
        subst_loop#visit_effect (subst_env 0 start_effect_0) end_effect
      in
      let c0 = inst_constraints 0 start_effect_0 in
      let c1 = inst_constraints 1 start_effect_1 in
      (* Effect after finishing execution of the loop *)
      let final_effect =
        if equiv_effect end_effect alpha_start
        then initial_effect
        else FSucc (drop_indexes renamed_idx end_effect)
      in
      (* Env after finishing execution of the loop *)
      let new_env =
        check_constraints
          s.sspan
          "Loop "
          env
          final_effect
          (c0 @ c1 @ env.constraints)
      in
      new_env, SLoop (inf_s1, idx, sz)
  in
  env, { s with s = stmt }

and infer_branches (env : env) s etys branches =
  let drop_constraints = drop_constraints env in
  let drop_ret_effects = drop_ret_effects env in
  let check_pats pats =
    match pats with
    | [PWild] -> ()
    | _ when List.length pats <> List.length etys ->
      error_sp
        s.sspan
        "A branch of this match statement has the wrong number of patterns"
    | _ -> List.iter2 (unify_raw_ty s.sspan) etys (List.map infer_pattern pats)
  in
  let infer_branch (pats, s) =
    check_pats pats;
    let env1, inf_s = infer_statement env s in
    env1, (pats, inf_s)
  in
  let returned, current_effect, constraints, ret_effects, inf_bs =
    List.fold_left
      (fun (returned, acc_eff, acc_constraints, acc_ret_effects, branches) b ->
        let env1, inf_b = infer_branch b in
        let constrs = drop_constraints env1 @ acc_constraints in
        let ret_effects = drop_ret_effects env1 @ acc_ret_effects in
        let eff =
          if env1.returned
          then acc_eff
          else (
            try TyperZ3.find_max constrs env1.current_effect acc_eff with
            | TyperZ3.NoMax ->
              Console.error_position
                s.sspan
                "Unable to determine which global variables have been used \
                 after match statement.")
        in
        returned && env1.returned, eff, constrs, ret_effects, inf_b :: branches)
      (true, env.current_effect, env.constraints, env.ret_effects, [])
      branches
  in
  ( { env with returned; current_effect; constraints; ret_effects }
  , List.rev inf_bs )
;;

let infer_body env (params, s) =
  let locals =
    List.fold_left
      (fun acc (id, ty) -> CidMap.add (Id id) ty acc)
      env.locals
      params
  in
  let env, s = infer_statement { env with locals } s in
  env, (params, s)
;;

let infer_memop span env (params, s) =
  (* First, make sure we have the right number/type of arguments *)
  let arg1size = fresh_size () in
  let arg2size = fresh_size () in
  let arg1ty = TInt arg1size in
  let arg2ty = TInt arg2size in
  let env, id1, id2 =
    match params with
    | [(id1, ty1); (id2, ty2)] ->
      unify_raw_ty ty1.tspan ty1.raw_ty arg1ty;
      unify_raw_ty ty2.tspan ty2.raw_ty arg2ty;
      let locals = CidMap.add (Id id1) ty1 env.locals in
      let locals = CidMap.add (Id id2) ty2 locals in
      { env with locals }, id1, id2
    | _ -> error_sp span "Wrong number of parameters to memop"
  in
  (* Do regular typechecking of the body *)
  let _, inf_s = infer_statement { env with ret_ty = Some (mk_ty arg1ty) } s in
  (* Do grammar checking of the body *)
  let check_return e =
    ignore
    @@ check_e
         (Id id1)
         (Id id2)
         (* TODO: There are more ops that are allowed in return statements, add them here *)
           (function
           | Plus | Sub | BitAnd | BitOr -> true
           | _ -> false)
         (false, false)
         e
  in
  (match inf_s.s with
  | SRet (Some e) -> check_return e
  | SIf (test, { s = SRet (Some e1) }, { s = SRet (Some e2) }) ->
    check_test id1 id2 test;
    check_return e1;
    check_return e2
  | _ -> error_sp span "Invalid grammar for body of memop");
  arg1size, arg2size, (params, inf_s)
;;

(* Check that the event id has already been defined, and that it has the
   expected paramters, and return an instantiated version of the constraints.
   Expects that params has already been instantiated. *)
let retrieve_constraints env span id params =
  match CidMap.find_opt (Id id) env.handlers with
  | None ->
    error_sp span
    @@ Printf.sprintf
         "Handler %s has no corresponding event declaration."
         (id_to_string id)
  | Some (constraints, params2) ->
    let maps = fresh_maps () in
    let params2 = instantiator#visit_params maps params2 in
    let constraints = List.map (instantiator#visit_constr maps) constraints in
    let _ =
      (* FIXME: This isn't quite sufficient -- it won't catch e.g.
           an event which takes Array.t<<'a>>, but a hander which takes Array.t<<32>> *)
      try
        try_unify_lists
          (fun (_, ty1) (_, ty2) -> unify_ty span ty1 ty2)
          params
          params2
      with
      | CannotUnify ->
        error_sp
          span
          (Printf.sprintf
             "Event %s was declared with arguments (%s) but its handler takes \
              arguments (%s)."
             (id_to_string id)
             (comma_sep (fun (_, ty) -> ty_to_string ty) params2)
             (comma_sep (fun (_, ty) -> ty_to_string ty) params))
    in
    constraints
;;

let rec infer_declaration (env : env) (effect_count : effect) (d : decl)
    : env * effect * decl
  =
  (* print_endline @@ "Inferring decl " ^ decl_to_string d; *)
  let env, effect_count, new_d =
    match d.d with
    | DSize (id, szo) ->
      let _ = Option.map (validate_size d.dspan env) szo in
      ( { env with sizes = CidSet.add (Id id) env.sizes } |> def KSize id
      , effect_count
      , d.d )
    | DGlobal (id, ty, e) ->
      enter_level ();
      let _, inf_e, inf_ety =
        infer_exp { env with in_global_def = true } e |> textract
      in
      leave_level ();
      let ty = { ty with teffect = effect_count } in
      unify_ty d.dspan inf_ety ty;
      let ty = generalizer#visit_ty () ty in
      let env =
        { env with consts = CidMap.add (Id id) ty env.consts } |> def KConst id
      in
      env, FSucc effect_count, DGlobal (id, ty, inf_e)
    | DConst (id, ty, e) ->
      enter_level ();
      let _, inf_e, inf_ety = infer_exp env e |> textract in
      leave_level ();
      unify_ty d.dspan ty inf_ety;
      let ty = generalizer#visit_ty () ty in
      if is_global ty
      then
        error_sp d.dspan
        @@ "Type "
        ^ ty_to_string ty
        ^ " is global and must be created via a global declaration";
      let env =
        { env with consts = CidMap.add (Id id) ty env.consts } |> def KConst id
      in
      env, effect_count, DConst (id, ty, inf_e)
    | DExtern (id, ty) ->
      if is_global ty
      then
        error_sp ty.tspan
        @@ "Type "
        ^ ty_to_string ty
        ^ " is global and cannot be declared extern";
      let env =
        { env with consts = CidMap.add (Id id) ty env.consts } |> def KConst id
      in
      env, effect_count, DExtern (id, ty)
    | DSymbolic (id, ty) ->
      if is_global ty
      then
        error_sp ty.tspan
        @@ "Type "
        ^ ty_to_string ty
        ^ " is global and cannot be declared symbolic";
      let env =
        { env with consts = CidMap.add (Id id) ty env.consts } |> def KConst id
      in
      env, effect_count, DSymbolic (id, ty)
    | DGroup (id, es) ->
      enter_level ();
      let _, inf_args = infer_exps env es in
      leave_level ();
      (* Locations are just ints for now *)
      List.iter
        (fun e ->
          unify_raw_ty d.dspan (Option.get e.ety).raw_ty (TInt (IConst 32)))
        inf_args;
      let env =
        { env with consts = CidMap.add (Id id) (mk_ty TGroup) env.consts }
        |> def KConst id
      in
      env, effect_count, DGroup (id, inf_args)
    | DEvent (id, sort, constr_specs, params) ->
      let constrs, _ =
        spec_to_constraints env d.dspan FZero params constr_specs
      in
      let env =
        { env with
          handlers = CidMap.add (Id id) (constrs, params) env.handlers
        ; consts = CidMap.add (Id id) (mk_event_ty constrs params) env.consts
        }
        |> def KConst id
        |> def KHandler id
      in
      env, effect_count, DEvent (id, sort, constr_specs, params)
    | DHandler (id, body) ->
      enter_level ();
      let constraints = retrieve_constraints env d.dspan id (fst body) in
      let _, inf_body =
        infer_body
          { env with
            current_effect = FZero
          ; consts =
              CidMap.add (Id Builtins.this_id) Builtins.this_ty env.consts
          ; constraints
          }
          body
      in
      leave_level ();
      let inf_body = generalizer#visit_body () inf_body in
      env, effect_count, DHandler (id, inf_body)
    | DFun (id, ret_ty, constr_specs, body) ->
      enter_level ();
      let start_eff = fresh_effect () in
      let constraints, end_eff =
        spec_to_constraints env d.dspan start_eff (fst body) constr_specs
      in
      let ret_effects =
        match end_eff with
        | None -> []
        | Some eff -> [eff]
      in
      let end_eff, constraints, ret_effects, inf_body =
        let fun_env, inf_body =
          infer_body
            { env with
              current_effect = start_eff
            ; ret_ty = Some ret_ty
            ; constraints
            ; ret_effects
            }
            body
        in
        if (not fun_env.returned) && ret_ty.raw_ty <> TVoid
        then Console.error_position d.dspan "Non-void function may not return!";
        ( fun_env.current_effect
        , fun_env.constraints
        , fun_env.ret_effects
        , inf_body )
      in
      let end_eff =
        try
          List.fold_left (TyperZ3.find_max constraints) end_eff ret_effects
        with
        | TyperZ3.NoMax ->
          Console.error_position (snd body).sspan
          @@ "Unable to determine which globals have been used at end of \
              function; no control path obviously finishes at a later stage \
              than the others : "
          ^ Printing.stmt_to_string (snd body)
      in
      leave_level ();
      if not (TyperZ3.check_sat constraints)
      then
        error_sp d.dspan
        @@ "Function "
        ^ Id.name id
        ^ " violates ordering constraints";
      let fty : func_ty =
        { arg_tys = List.map (fun (_, ty) -> ty) (fst inf_body)
        ; ret_ty
        ; start_eff
        ; end_eff
        ; constraints = ref constraints
        }
        |> generalizer#visit_func_ty ()
      in
      let inf_body = generalizer#visit_body () inf_body in
      let env =
        { env with consts = CidMap.add (Id id) (mk_ty @@ TFun fty) env.consts }
        |> def KConst id
      in
      (* print_endline
      @@ "Inferred type for "
      ^ id_to_string id
      ^ " is "
      ^ raw_ty_to_string (TFun fty); *)
      env, effect_count, DFun (id, ret_ty, constr_specs, inf_body)
    | DMemop (id, body) ->
      enter_level ();
      let inf_size1, inf_size2, inf_memop = infer_memop d.dspan env body in
      leave_level ();
      let tmem = generalizer#visit_raw_ty () (TMemop (inf_size1, inf_size2)) in
      let env =
        { env with consts = CidMap.add (Id id) (ty tmem) env.consts }
        |> def KConst id
      in
      env, effect_count, DMemop (id, inf_memop)
    | DUserTy (id, sizes, ty) ->
      let new_env =
        { env with user_tys = CidMap.add (Id id) (ty, sizes) env.user_tys }
        |> def KUserTy id
      in
      let new_env =
        match ty.raw_ty with
        | TRecord lst ->
          let record_labels =
            List.fold_left
              (fun acc (l, _) -> StringMap.add l ty acc)
              new_env.record_labels
              lst
          in
          { new_env with record_labels }
        | _ -> new_env
      in
      new_env, effect_count, DUserTy (id, sizes, ty)
    | DConstr (id, ty, params, e) ->
      enter_level ();
      let _, inf_e, inf_ety =
        let locals =
          List.fold_left
            (fun acc (id, ty) -> CidMap.add (Id id) ty acc)
            env.locals
            params
        in
        let inf_env = { env with in_global_def = true; locals } in
        infer_exp inf_env e |> textract
      in
      leave_level ();
      unify_ty d.dspan ty inf_ety;
      let fty =
        (* If called at top level the start/end effects don't matter; otherwise,
           the constructor doesn't involve any global stuff, so it's stateless. *)
        let eff = fresh_effect () in
        { arg_tys = List.map snd params
        ; ret_ty = ty
        ; start_eff = eff
        ; end_eff = eff
        ; constraints = ref []
        }
        |> generalizer#visit_func_ty ()
      in
      let env =
        { env with constructors = CidMap.add (Id id) fty env.constructors }
        |> def KConstr id
      in
      env, effect_count, DConstr (id, ty, params, inf_e)
    | DModule (id, intf, ds) ->
      wellformed_interface env intf;
      let m_env, effect_count, ds =
        List.fold_left
          (fun (env, effect_count, ds) d ->
            let env, effect_count, d = infer_declaration env effect_count d in
            env, effect_count, d :: ds)
          ({ env with module_defs = KindSet.empty }, effect_count, [])
          ds
      in
      let ds = List.rev ds in
      let env = add_module_defs id intf env m_env in
      env, effect_count, DModule (id, intf, ds)
  in
  let new_d = { d with d = new_d } in
  Wellformed.check_qvars new_d;
  env, effect_count, new_d
;;

let ensure_fully_typed ds =
  let v =
    object (self)
      inherit [_] s_iter

      method! visit_exp _ exp =
        match exp.ety with
        | Some _ -> self#visit_e () exp.e
        | None ->
          error_sp exp.espan
          @@ Printf.sprintf
               "Internal error: expression %s has no type!"
               (Printing.exp_to_string exp)
    end
  in
  v#visit_decls () ds
;;

let infer_prog (decls : decls) : decls =
  let decls = instantiate_prog decls in
  let (env : env) = default_env in
  let infer_d (env, count, ds) d =
    let env, count, d = infer_declaration env count d in
    env, count, d :: ds
  in
  let _, _, inf_decls = List.fold_left infer_d (env, FZero, []) decls in
  ensure_fully_typed inf_decls;
  List.rev inf_decls
;;
