(** Occurs checking: Ensure that a given TVar doesn't occur in a type/effect/size,
    to prevent circular types/effects/sizes *)
open Syntax

open SyntaxUtils
open Batteries
open Printing
open TyperUtil

exception Occurs

(* Physical ref equality *)
let equal_tyvars t1 t2 = t1 == t2

let check_occurs span occ f tvar x : unit =
  try occ tvar x with
  | Occurs ->
    error_sp
      span
      (Printf.sprintf "%s occurs in %s\n" (tqvar_to_string f (TVar tvar)) (f x))
;;

let occurs_tqvar occ tvar tqvar : unit =
  match tqvar with
  | TVar tvr when equal_tyvars tvr tvar -> raise Occurs
  | TVar ({ contents = Unbound (name, l') } as tv) ->
    let min_level =
      match !tvar with
      | Unbound (_, l) -> min l l'
      | _ -> l'
    in
    tv := Unbound (name, min_level)
  | TVar { contents = Link x } -> occ tvar x
  | QVar id ->
    Printf.printf
      "Unexpected: QVar %s appears in occ check!\n"
      (Printing.id_to_string id)
;;

let occurs_size span tvar size : unit =
  let rec occ tvar size =
    match size with
    | IVar tvr -> occurs_tqvar occ tvar tvr
    | IConst _ | IUser _ -> ()
    | ISum (sizes, _) -> List.iter (occ tvar) sizes
  in
  check_occurs span occ size_to_string tvar size
;;

let occurs_effect span tvar eff : unit =
  let rec occ tvar eff =
    match eff with
    | FVar tvr -> occurs_tqvar occ tvar tvr
    | FZero -> ()
    | FSucc eff | FProj eff | FIndex (_, eff) -> occ tvar eff
  in
  check_occurs span occ effect_to_string tvar eff
;;

let occurs_ty span tvar raw_ty : unit =
  let rec occ tvar raw_ty =
    match raw_ty with
    | TQVar tvr -> occurs_tqvar occ tvar tvr
    | TBool | TInt _ | TName _ | TVoid | TEvent _ | TGroup | TMemop _ -> ()
    | TRecord lst -> List.iter (fun (_, raw_ty) -> occ tvar raw_ty) lst
    | TTuple lst -> List.iter (occ tvar) lst
    | TFun { arg_tys; ret_ty; _ } ->
      List.iter (fun ty -> occ tvar ty.raw_ty) arg_tys;
      occ tvar ret_ty.raw_ty
    | TVector (raw_ty, _) -> occ tvar raw_ty
  in
  check_occurs span occ raw_ty_to_string tvar raw_ty
;;

(** Unification functions **)

exception CannotUnify

let try_unify_lists f lst1 lst2 =
  try List.iter2 f lst1 lst2 with
  (* Different lengths *)
  | Invalid_argument _ -> raise CannotUnify
;;

let check_unify span try_unify f x1 x2 : unit =
  try try_unify x1 x2 with
  | CannotUnify ->
    Console.error_position
      span
      (Printf.sprintf "Cannot unify\n %s\n with\n %s\n" (f x1) (f x2))
;;

let try_unify_tqvar occ try_unify equiv tqvar x : unit =
  if equiv tqvar x
  then ()
  else (
    (* physical equality *)
    match tqvar with
    | TVar { contents = Link x' } -> try_unify x x'
    | QVar _ ->
      Console.warning "Internal error: encountered QVar during unification!";
      raise CannotUnify
    | TVar ({ contents = Unbound _ } as tv) ->
      occ tv x;
      tv := Link x)
;;

(* Remove all elements appearing in lst2 from lst1. Uses structural equality
   to compare refs, but that should be fine in this case since we won't have
   Links, and we only generate each Unbound value once. *)
let sub lst1 lst2 = List.filter (fun x -> not (List.mem x lst2)) lst1

(* Since the grammar allows arbitrary addition, and we don't know how to unify
   e.g. a+b with c+d, we have to be careful when unifying Sums *)

let rec try_unify_size span size1 size2 =
  (* Printf.printf
       "Trying to unify %s and %s\n"
       (Printing.size_to_string size1)
        (Printing.size_to_string size2); *)
  let try_unify = try_unify_size span in
  let size1, size2 = normalize_size size1, normalize_size size2 in
  (* Physical equality *)
  if size1 == size2
  then ()
  else (
    match size1, size2 with
    | IVar tqv, size | size, IVar tqv ->
      try_unify_tqvar
        (occurs_size span)
        try_unify
        STQVar.phys_equiv_tqvar
        tqv
        size
    | IConst n1, IConst n2 -> if n1 <> n2 then raise CannotUnify
    | IUser id1, IUser id2 -> if not (Cid.equal id1 id2) then raise CannotUnify
    | ISum (vs, n1), IConst n2 | IConst n2, ISum (vs, n1) ->
      (* We can only unify if the sum is of the form a + x and x <= n2 *)
      begin
        match vs with
        | [hd] when n1 <= n2 -> try_unify hd (IConst (n2 - n1))
        | _ -> raise CannotUnify
      end
    | ISum (vs1, n1), ISum (vs2, n2) ->
      (* Remove any terms they have in common, and subtract the larger n from
            the smaller one. We can then unify iff we end up with a single variable
            on the side with the smaller n, or no variables and the same n *)
      begin
        match sub vs1 vs2, sub vs2 vs1 with
        | [], [] -> if n1 <> n2 then raise CannotUnify
        | [hd], vs2' when n1 <= n2 -> try_unify hd (ISum (vs2', n2 - n1))
        | vs1', [hd] when n2 <= n1 -> try_unify hd (ISum (vs1', n1 - n2))
        | _ -> raise CannotUnify
      end
    | IUser _, _ | _, IUser _ -> raise CannotUnify)
;;

let unify_size (span : Span.t) size1 size2 : unit =
  check_unify span (try_unify_size span) size_to_string size1 size2
;;

(* Much simpler that unification for sizes, because effects have much more
   restricted addition (only allowing +1) *)
let rec try_unify_effect span eff1 eff2 =
  let try_unify = try_unify_effect span in
  let eff1, eff2 = FTQVar.strip_links eff1, FTQVar.strip_links eff2 in
  if eff1 == eff2
  then ()
  else (
    match eff1, eff2 with
    | FVar tqv, eff | eff, FVar tqv ->
      try_unify_tqvar
        (occurs_effect span)
        try_unify
        FTQVar.phys_equiv_tqvar
        tqv
        eff
    | FZero, FZero -> ()
    | FSucc eff1, FSucc eff2 | FProj eff1, FProj eff2 -> try_unify eff1 eff2
    | FIndex (id1, eff1), FIndex (id2, eff2) ->
      if not (Id.equal id1 id2) then raise CannotUnify else try_unify eff1 eff2
    | (FZero | FSucc _ | FProj _ | FIndex _), _ -> raise CannotUnify)
;;

let unify_effect (span : Span.t) eff1 eff2 : unit =
  check_unify span (try_unify_effect span) effect_to_string eff1 eff2
;;

let rec try_unify_ty span ty1 ty2 =
  let ty1, ty2 = strip_links ty1, strip_links ty2 in
  if ty1.raw_ty == ty2.raw_ty && ty1.teffect == ty2.teffect
  then ()
  else (
    unify_raw_ty span ty1.raw_ty ty2.raw_ty;
    (* Don't unify effects for things which definitely aren't global *)
    if not (SyntaxUtils.is_not_global_rty ty1.raw_ty)
    then try_unify_effect span ty1.teffect ty2.teffect;
    match !(ty1.tprint_as) with
    | None -> ty1.tprint_as := !(ty2.tprint_as)
    | Some x -> ty2.tprint_as := Some x)

and try_unify_rty span rty1 rty2 =
  match rty1, rty2 with
  | TQVar tqv, ty | ty, TQVar tqv ->
    try_unify_tqvar
      (occurs_ty span)
      (unify_raw_ty span)
      TyTQVar.phys_equiv_tqvar
      tqv
      ty
  | TBool, TBool | TVoid, TVoid | TGroup, TGroup -> ()
  | TInt size1, TInt size2 -> try_unify_size span size1 size2
  | TMemop (size1a, size1b), TMemop (size2a, size2b) ->
    try_unify_size span size1a size2a;
    try_unify_size span size1b size2b
  | TEvent b1, TEvent b2 -> if b1 <> b2 then raise CannotUnify
  | TName (cid1, sizes1, b1), TName (cid2, sizes2, b2) ->
    if b1 <> b2 || not (Cid.equal cid1 cid2) then raise CannotUnify;
    List.iter2 (try_unify_size span) sizes1 sizes2
  | TFun func1, TFun func2 ->
    try_unify_lists (unify_ty span) func1.arg_tys func2.arg_tys;
    unify_ty span func1.ret_ty func2.ret_ty;
    try_unify_effect span func1.start_eff func2.start_eff;
    try_unify_effect span func1.end_eff func2.end_eff;
    let combined = !(func1.constraints) @ !(func2.constraints) in
    (* if not (check_sat combined) then raise CannotUnify; *)
    func1.constraints := combined;
    func2.constraints := combined
  | TRecord lst1, TRecord lst2 ->
    try_unify_lists
      (fun (str1, ty1) (str2, ty2) ->
        if not (String.equal str1 str2) then raise CannotUnify;
        unify_raw_ty span ty1 ty2)
      (List.sort (fun (x, _) (y, _) -> Pervasives.compare x y) lst1)
      (List.sort (fun (x, _) (y, _) -> Pervasives.compare x y) lst2)
  | TTuple lst1, TTuple lst2 -> try_unify_lists (unify_raw_ty span) lst1 lst2
  | TVector (ty1, size1), TVector (ty2, size2) ->
    try_unify_size span size1 size2;
    unify_raw_ty span ty1 ty2
  | ( ( TVoid
      | TGroup
      | TBool
      | TInt _
      | TMemop _
      | TEvent _
      | TName _
      | TFun _
      | TRecord _
      | TVector _
      | TTuple _ )
    , _ ) -> raise CannotUnify

and unify_ty (span : Span.t) ty1 ty2 : unit =
  check_unify span (try_unify_ty span) ty_to_string ty1 ty2

and unify_raw_ty (span : Span.t) ty1 ty2 : unit =
  check_unify span (try_unify_rty span) raw_ty_to_string ty1 ty2
;;
