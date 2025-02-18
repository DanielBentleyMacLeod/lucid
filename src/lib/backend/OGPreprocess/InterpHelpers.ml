(* Helper functions to partially interpret the source syntax *)

open Syntax
open SyntaxUtils
open Batteries
module CL = Caml.List

let trans_err msg ex = error (msg ^ " " ^ Printing.exp_to_string ex)

let trans_info str =
  Console.show_message str ANSITerminal.Green "Tofino translation"
;;

(* defaults *)
let int_width = 32

(**** types ****)
let intwidth_from_raw_ty rty : int =
  match TyTQVar.strip_links rty with
  | TQVar _ ->
    error
      "tried to translate object type that was not inferred -- this can happen \
       if the program has something that is declared without a type and then \
       never used."
  | TBool -> 1
  | TInt sz -> extract_size sz
  | _ -> error "cannot get size from this type"
;;

let width_from_ty ty = intwidth_from_raw_ty ty.raw_ty

let extract_size_opt s =
  match normalize_size s with
  | IConst n -> Some n
  | _ -> None
;;

let intwidth_from_raw_ty_opt rty : int option =
  match TyTQVar.strip_links rty with
  | TQVar _ ->
    error
      "tried to translate object type that was not inferred -- this can happen \
       if the program has something that is declared without a type and then \
       never used."
  | TBool -> Some 1
  | TInt sz -> extract_size_opt sz
  | _ -> error "cannot get size from this type"
;;

let width_from_ty_opt ty = intwidth_from_raw_ty_opt ty.raw_ty

(**** values ****)
let vint_ty i ty =
  avalue
    (VInt (Integer.create ~value:i ~size:(width_from_ty ty)))
    (Some ty)
    Span.default
;;

(**** expressions ****)
(* typed op expression *)
let eop_tyspan op args ety espan = aexp (EOp (op, args)) ety espan
let eop_ty op args rty = eop_tyspan op args (Some rty) Span.default
let eval v = Syntax.exp (EVal v)
let eval_bool b = eval (vbool b)
let evar_cid cid = Syntax.exp (EVar cid)
let evar id = Syntax.exp (EVar (Cid.id id))

(* typed integer expression *)
let eval_vint_ty i ty = value_to_exp (vint_ty i ty)

(* let eint_width v w =
  let rty = TInt (IConst w) in
  let vint = VInt (Integer.create ~value:v ~size:w) in
  aexp (EVal (vint_ty vint rty)) (Some (ty rty)) Span.default
;;
 *)

(* let eval_int_ty int ty =
  let rty = ty.raw_ty in
  let width = intwidth_from_ty ty in




  let rty = TInt (IConst w) in
  let vint = VInt (Integer.create ~value:v ~size:w) in
  aexp (EVal (vint_ty vint rty)) (Some rty) Span.default
;;

 *)

(*
    And [a, b] -->
      And [a, b]
    And [a, b, c] -->
      And [(And [a]), (And [b, c])]
    And a::[...] ->
      And [a, recurse(iii)]
  *)
let rec fold_commutative_eop exp =
  match exp with
  | { e = EOp (op, args); ety; espan } ->
    (match args with
    | [_; _] -> exp
    | [a1; a2; a3] ->
      let inner_eop = { e = EOp (op, [a2; a3]); ety; espan } in
      { e = EOp (op, [a1; inner_eop]); ety; espan }
    | a1 :: args ->
      let inner_eop = { e = EOp (op, args); ety; espan } in
      { e = EOp (op, [a1; fold_commutative_eop inner_eop]); ety; espan }
    | _ -> error "binop with only 1 arg...")
  | _ -> error "not an eop"
;;

(**** statements ****)

(**** statement tree (un)flattening ****)
let rec unfold_stmts (st : statement) =
  match st.s with
  | SNoop -> []
  | SSeq (s1, s2) -> unfold_stmts s1 @ unfold_stmts s2
  | _ -> [st]
;;

let rec fold_stmts (sts : statement list) : statement =
  match sts with
  | [] -> snoop
  | [st] -> st
  | [st1; st2] -> sseq st1 st2
  | st1 :: sts -> sseq st1 (fold_stmts sts)
;;

let rhs_of_stmt s =
  match s with
  | SAssign (_, rhs) -> Some rhs
  | SLocal (_, _, rhs) -> Some rhs
  | _ -> None
;;

let id_of_stmt s =
  match s with
  | SAssign (id, _) -> Some id
  | SLocal (id, _, _) -> Some id
  | _ -> None
;;

(* destructors and filters *)
let unpack_eop exp =
  match exp with
  | { e = EOp (op, args); ety; espan } -> op, args, ety, espan
  | _ -> error "cannot unpack exp"
;;

let name_from_exp (ex : exp) : Cid.t =
  match ex.e with
  | EVar n -> n
  | _ -> trans_err "could not evaluate expression to a name" ex
;;

let int_from_exp (ex : exp) =
  print_endline ("[int_from_exp]: " ^ Printing.exp_to_string ex);
  match ex.e with
  | EVal { v = VInt zint; _ } -> Integer.to_int zint
  | EInt (z, _) ->
    Z.to_int z (* Integer.create_z ~value:z ~size:(extract_size sz)  *)
  | _ -> trans_err "could not evaluate expression to an int" ex
;;

let ty_of_exp (exp : exp) : ty =
  match exp.ety with
  | Some rty -> rty
  | None -> error "untyped expression after type checking / inference..."
;;

let raw_ty_of_exp exp = TyTQVar.strip_links (ty_of_exp exp).raw_ty

let intwidth_of_exp (exp : exp) : int =
  match exp.ety with
  | None -> error "untyped expression after type checking/inference..."
  | Some rty -> intwidth_from_raw_ty rty.raw_ty
;;

let args_of_exp exp =
  match exp.e with
  | EOp (_, args) | ECall (_, args) | EHash (_, args) -> args
  | _ -> []
;;

let op_of_exp exp =
  match exp.e with
  | EOp (op, _) -> Some op
  | _ -> None
;;

(* filters *)
let filter_eop_kind kind exp =
  match exp.e with
  | EOp (op, _) -> op = kind
  | _ -> false
;;

let is_bool exp =
  match raw_ty_of_exp exp with
  | TBool -> true
  | _ -> false
;;

(* is an expression an associative operation? *)
let is_assoc_op exp =
  match op_of_exp exp with
  | Some Plus -> true
  | _ -> false
;;

let is_immediate exp =
  match exp.e with
  | EVal _ -> true
  | EInt _ -> true
  | EVar _ -> true
  | _ -> false
;;

(* can an expression be done in one step? *)
let is_atomic exp =
  match exp.e with
  (* immediates are atomic. *)
  | EVal _ | EInt _ | EVar _ -> true
  (* ops are atomic if they are binary with all args immediates *)
  | EOp (_, args) ->
    CL.map is_immediate args |> CL.for_all identity && CL.length args <= 2
  (* calls are atomic if they have all immediate args *)
  | EHash (_, args) | ECall (_, args) ->
    CL.map is_immediate args |> CL.for_all identity
  | EProj _
  | ERecord _
  | EWith _
  | EComp _
  | EIndex _
  | EVector _
  | ETuple _
  | ESizeCast _
  | EStmt _ -> error "Should be removed before IR."
;;

let is_bool_non_immediate exp = is_bool exp && not (is_immediate exp)

(* transformations *)
(* return a statement that precomputes expression
and the variable that it gets put in *)
let precompute exp =
  let var_id = Id.fresh "precompute" in
  let precompute_stmt = slocal var_id (ty_of_exp exp) exp in
  let new_exp = { exp with e = EVar (Cid.id var_id) } in
  precompute_stmt, new_exp
;;

let replace_assign_rhs stmt exp =
  match stmt.s with
  | SAssign (id, _) -> { stmt with s = SAssign (id, exp) }
  | SLocal (id, ty, _) -> { stmt with s = SLocal (id, ty, exp) }
  | _ ->
    error "tried to replace the rhs of a statement that is not an assign/local"
;;

let replace_args exp new_args =
  match exp.e with
  | EOp (op, _) -> { exp with e = EOp (op, new_args) }
  | ECall (id, _) -> { exp with e = ECall (id, new_args) }
  | EHash (sz, _) -> { exp with e = EHash (sz, new_args) }
  | _ -> exp
;;

let rec flatten_disjunction exp =
  (* flatten all the ors *)
  match exp with
  | { e = EOp (Or, args) } -> CL.map flatten_disjunction args |> CL.flatten
  | _ -> [exp]
;;

let rec flatten_conjunction exp =
  (* flatten all the ors *)
  match exp with
  | { e = EOp (And, args) } -> CL.map flatten_conjunction args |> CL.flatten
  | _ -> [exp]
;;

module BalancedTree = struct
  type btnode =
    | BtNode of btnode option * btnode option
    | BtLeaf of exp
    | BtEmpty

  let rec len btnode_opt =
    match btnode_opt with
    | None -> 0
    | Some BtEmpty -> 0
    | Some (BtLeaf _) -> 1
    | Some (BtNode (left_opt, right_opt)) -> len left_opt + len right_opt
  ;;

  let aleafopt exp = Some (BtLeaf exp)

  (* add node to tree, keeping it balanced. *)
  let rec add btnode exp =
    match btnode with
    | BtEmpty -> BtLeaf exp
    (* leaf --> node with a leaf *)
    | BtLeaf _ -> BtNode (aleafopt exp, Some btnode)
    (* node with lhs empty --> node with lhs leaf *)
    | BtNode (None, rnode_opt) -> BtNode (aleafopt exp, rnode_opt)
    (* node with rhs empty --> node with rhs leaf *)
    | BtNode (lnode_opt, None) -> BtNode (lnode_opt, aleafopt exp)
    (* neither side is empty, add to smaller side *)
    | BtNode (Some lnode, Some rnode) ->
      let lnode_len = len (Some lnode) in
      let rnode_len = len (Some rnode) in
      (match lnode_len <= rnode_len with
      | true -> BtNode (Some (add lnode exp), Some rnode)
      | false -> BtNode (Some lnode, Some (add rnode exp)))
  ;;

  (* build a balanced tree from the exps *)
  let build exps = CL.fold_left add BtEmpty exps

  (* convert the expression tree into a tree of a single type of operation *)
  let rec to_eop_tree op ety espan btnode =
    match btnode with
    | BtEmpty -> error "cannot convert an empty btree into an expr tree"
    | BtLeaf exp -> exp
    | BtNode (Some lnode, Some rnode) ->
      eop_tyspan
        op
        [to_eop_tree op ety espan lnode; to_eop_tree op ety espan rnode]
        ety
        espan
    | BtNode (_, _) -> error "Btnode without two children -- shouldn't exist"
  ;;
end

(* flatten a tree of commutative eops into a single eop.
      example:
      a + (b + (c + (d + (e + f) ) ) ) ->
      + [a; b; c; d; e; f]
      Recursion stops when it hits an "atom" -- an expression
      that is not of the form EOp(<op>, _) *)
let rec extract_atomic_opargs op exp =
  match exp with
  | { e = EOp (o, args); _ } ->
    (match o = op with
    | false -> [exp] (* cannot recurse *)
    | true ->
      CL.map (extract_atomic_opargs op) args |> CL.flatten (* can recurse *))
  | _ -> [exp]
;;

(* cannot recurse *)

(* balance the tree of commutative operations rooted at exp *)
let balance_eop_tree exp =
  let op, args, ety, espan = unpack_eop exp in
  let flat_args = CL.map (extract_atomic_opargs op) args |> CL.flatten in
  let btree = BalancedTree.build flat_args in
  let balanced_eop = BalancedTree.to_eop_tree op ety espan btree in
  balanced_eop
;;

let vars_in_exp exp =
  let v =
    object
      inherit [_] s_iter as super

      val mutable keyfields : cid list = []

      method keyfields = keyfields

      method! visit_EVar _ cid = keyfields <- keyfields @ [cid]
    end
  in
  v#visit_exp () exp;
  let key = v#keyfields in
  key
;;

(* get the var subexpressions useful bc it gives you type info. *)
let evars_in_exp exp =
  let v =
    object
      inherit [_] s_iter as super

      val mutable evars : exp list = []

      method evars = evars

      method! visit_exp ctx exp =
        match exp.e with
        | EVar _ -> evars <- evars @ [exp]
        | _ -> super#visit_exp ctx exp
    end
  in
  v#visit_exp () exp;
  v#evars
;;

let cids_from_params params =
  let ids, _ = CL.split params in
  CL.map Cid.id ids
;;

let vardefs_from_params params =
  let map_f (id, ty) = Cid.id id, width_from_ty ty in
  CL.map map_f params
;;

(* unpacking parameters *)
let unpack_assign stmt =
  match stmt.s with
  | SAssign (id, val_exp) -> id, val_exp
  | _ -> error "not an assign."
;;

let unpack_local stmt =
  match stmt.s with
  | SLocal (id, ty, val_exp) -> id, ty, val_exp
  | _ -> error "not a local."
;;

let unpack_unit stmt =
  match stmt.s with
  | SUnit val_exp -> val_exp
  | _ -> error "not a unit."
;;

let unpack_match stmt =
  match stmt.s with
  | SMatch (keys, branches) -> keys, branches
  | _ -> error "not a match."
;;

let unpack_if stmt =
  match stmt with
  | { s = SIf (boole, s1, s2); sspan } -> boole, s1, s2, sspan
  | _ -> error "not an sif "
;;

let unpack_generate stmt =
  match stmt.s with
  | SGen (_, args) -> args
  | _ -> error "not a generate stmt"
;;

let unpack_binargs args =
  match args with
  | [a1; a2] -> a1, a2
  | _ -> error "expected 2 args."
;;

(**** inlining helpers ****)
(* replace every expression EVar(t) with expression n *)
let rec replace_in_exp (exp : exp) (t : cid) (n : exp) : exp =
  match exp with
  | { e = EVar cid; _ } ->
    (match Cid.equals cid t with
    | true -> n
    | false -> exp)
  | { e = EOp (op, exps); _ } ->
    { exp with e = EOp (op, replace_in_exps exps t n) }
  | { e = ECall (name, exps); _ } ->
    { exp with e = ECall (name, replace_in_exps exps t n) }
  | { e = EHash (sz, exps); _ } ->
    { exp with e = EHash (sz, replace_in_exps exps t n) }
  | _ -> exp

and replace_in_exps exps t n = CL.map (fun e -> replace_in_exp e t n) exps

(* replace EVar(t) with exp n wherever it appears *)
let rec replace_in_stmt (stmt : statement) t n =
  match stmt with
  | { s = SUnit e1; _ } -> { stmt with s = SUnit (replace_in_exp e1 t n) }
  | { s = SLocal (id, ty, exp); _ } ->
    { stmt with s = SLocal (id, ty, replace_in_exp exp t n) }
  | { s = SAssign (id, exp); _ } ->
    { stmt with s = SAssign (id, replace_in_exp exp t n) }
  | { s = SIf (e1, s1, s2); _ } ->
    { stmt with
      s =
        SIf
          (replace_in_exp e1 t n, replace_in_stmt s1 t n, replace_in_stmt s2 t n)
    }
  | { s = SGen (b, exp); _ } ->
    { stmt with s = SGen (b, replace_in_exp exp t n) }
  | { s = SRet (Some e1); _ } ->
    { stmt with s = SRet (Some (replace_in_exp e1 t n)) }
  | { s = SSeq (s1, s2); _ } ->
    { stmt with s = SSeq (replace_in_stmt s1 t n, replace_in_stmt s2 t n) }
  | { s = SMatch (keys, branches); _ } ->
    let map_f (pats, s) = pats, replace_in_stmt s t n in
    let updated_branches = CL.map map_f branches in
    { stmt with s = SMatch (replace_in_exps keys t n, updated_branches) }
  | _ -> stmt
;;

(* replace id with new_id in the left hand side
  of local and assign statements *)
let rec replace_in_stmt_lhs (stmt : statement) (id : Id.t) new_id =
  match stmt with
  | { s = SSeq (s1, s2); _ } ->
    { stmt with
      s =
        SSeq (replace_in_stmt_lhs s1 id new_id, replace_in_stmt_lhs s2 id new_id)
    }
  | { s = SMatch (keys, branches); _ } ->
    let map_f (pats, s) = pats, replace_in_stmt_lhs s id new_id in
    let updated_branches = CL.map map_f branches in
    { stmt with s = SMatch (keys, updated_branches) }
  | { s = SIf (e1, s1, s2); _ } ->
    { stmt with
      s =
        SIf
          ( e1
          , replace_in_stmt_lhs s1 id new_id
          , replace_in_stmt_lhs s2 id new_id )
    }
  | { s = SLocal (orig_id, ty, exp); _ } ->
    (match Id.equals id orig_id with
    | true -> { stmt with s = SLocal (id, ty, exp) }
    | false -> stmt)
  | { s = SAssign (orig_id, exp); _ } ->
    print_endline ("LOOKING FOR ID IN LHS: " ^ Id.to_string id);
    print_endline ("I SEE ID IN LHS: " ^ Id.to_string orig_id);
    (match Id.equals id orig_id with
    | true -> { stmt with s = SAssign (new_id, exp) }
    | false -> stmt)
  | _ -> stmt
;;

(* make sure event parameter IDs are globally unique *)
let refresh_param_id (i, ty) = Id.refresh i, ty

let rec refresh_event_param_ids ds : decls =
  let map_f dec =
    match dec.d with
    | DEvent (ev_id, ev_sort, constr_specs, ev_params) ->
      { d =
          DEvent
            (ev_id, ev_sort, constr_specs, CL.map refresh_param_id ev_params)
      ; dspan = dec.dspan
      }
    | _ -> dec
  in
  CL.map map_f ds
;;
