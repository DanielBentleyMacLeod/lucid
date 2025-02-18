open Batteries
open LLSyntax
open Format
open Base
open Consts
open PrintUtils
module CL = Caml.List

(* debug string functions *)

exception Error of string

let error s = raise (Error s)

(**** debug strings ****)
let mid_to_dbgstr (m : mid) : string =
  let names = Cid.names m in
  String.concat ~sep:"_" names
;;

let oper_to_dbgstr i =
  match i with
  | Const c -> Integer.value_string c
  | Meta m -> Cid.to_string m
  | RegVar _ -> "<mem_cell>"
  | NoOper -> "<None>"
;;

let opers_to_dbgstr oper_list =
  Caml.String.concat ", " (Caml.List.map oper_to_dbgstr oper_list)
;;

let rec dbgstr_of_cid_list (args : mid list) =
  match args with
  | [] -> ""
  | [a] -> mid_to_dbgstr a
  | a :: args -> mid_to_dbgstr a ^ ", " ^ dbgstr_of_cid_list args
;;

let dbgstr_of_cidpairs cidpairs =
  Caml.String.concat
    ", "
    (CL.map
       (fun (s, d) -> sprintf "(%s, %s)" (Cid.to_string s) (Cid.to_string d))
       cidpairs)
;;

let str_of_cids cids =
  let names = Core.List.map cids ~f:Cid.to_string in
  Core.String.concat ~sep:", " names
;;

let dbgstr_of_cond c =
  match c with
  | Exact z -> string_of_int (Integer.to_int z)
  | Any -> "_"
;;

let dbgstr_of_pat pat =
  let pat_strs = Caml.List.map (fun (_, cond) -> dbgstr_of_cond cond) pat in
  "(" ^ Caml.String.concat ", " pat_strs ^ ")"
;;

let dbgstr_of_rule r =
  match r with
  | Match (_, pat, acn_id) ->
    dbgstr_of_pat pat ^ " : " ^ Cid.to_string acn_id ^ "();"
  | OffPath pat -> dbgstr_of_pat pat ^ " : NOOP();"
;;

let cids_to_string cids =
  let names = Core.List.map cids ~f:Cid.to_string in
  Core.String.concat ~sep:", " names
;;

(* wrapper to debug functions that print to a formatter *)
let stringerize_1 pp_writer pp_writer_arg =
  pp_open_vbox str_formatter 4;
  pp_writer str_formatter pp_writer_arg;
  pp_close_box str_formatter ();
  flush_str_formatter ()
;;

let ids_in_cid_decls cid_decls = CL.split cid_decls |> fst |> str_of_cids

let str_to_id str =
  match BatString.split_on_char '~' str with
  | [name; num] -> name, int_of_string num
  | _ -> error "cannot convert into an id"
;;

let str_to_cid str =
  BatString.split_on_char '.' str |> CL.map str_to_id |> Cid.create_ids
;;

let cid_str_in_cid_decls cid_decls cidstr =
  Cid.exists cid_decls (str_to_cid cidstr)
;;

let str_of_decl decl =
  PrintUtils.open_block ();
  P4tPrint.PrintComputeObject.print_decls [decl];
  PrintUtils.close_block ()
;;

let str_of_decls decls =
  PrintUtils.open_block ();
  P4tPrint.PrintComputeObject.print_decls decls;
  PrintUtils.close_block ()
;;

let str_of_cid_decls cid_decls =
  PrintUtils.open_block ();
  P4tPrint.PrintComputeObject.print_decls (CL.split cid_decls |> snd);
  PrintUtils.close_block ()
;;
