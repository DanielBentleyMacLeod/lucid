open Syntax

(* Builtin variables *)
let self_id = Id.create "self"
let self_ty = ty (TInt (IConst 32))
let builtin_vars = [self_id, self_ty]
let builtin_type_ids = [Arrays.t_id; Counters.t_id]

(* Building modules *)
let builtin_modules =
  [Arrays.module_id; Counters.module_id; Events.module_id; System.module_id]
;;

let builtin_defs = Arrays.defs @ Counters.defs @ Events.defs @ System.defs

(* Not a global var *)
let this_id = Id.create "this"
let this_ty = ty @@ TEvent false

(* Used in constraints *)
let start_id = Id.create "start"
