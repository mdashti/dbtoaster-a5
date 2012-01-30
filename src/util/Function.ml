type ('a, 'b) table_fn_t = ('a * 'b) list

exception NonFunctionalMappingException

(* for partial functions with a default value to be returned if x is
   not in the domain of theta. *)
let apply (theta: ('a, 'b) table_fn_t)
          (default: 'b) (x: 'a): 'b =
   let g (y, z) = if(x = y) then [z] else []
   in
   let x2 = List.flatten (List.map g theta)
   in
   if (List.length x2) = 0 then default
   else if (List.length x2) = 1 then (List.hd x2)
   else raise NonFunctionalMappingException

let apply_if_present (theta: ('a,'a) table_fn_t) (x: 'a): 'b =
   apply theta x x

let string_of_table_fn (theta:('a,'b) table_fn_t)
                       (left_to_s:('a -> string))
                       (right_to_s:('b -> string)): string =
  match (List.fold_left (fun accum (x,y) ->
       Some((match accum with | Some(a) -> a^", " | None -> "")^
            "{ "^(left_to_s x)^
            " => "^(right_to_s y)^
            " }"
       )
     ) None theta) with
   | Some(a) -> "[ "^a^" ]"
   | None -> "[]"

let apply_strict (theta: ('a, 'b) table_fn_t) (x: 'a): 'b =
   let g (y, z) = if(x = y) then [z] else []
   in
   let x2 = List.flatten (List.map g theta)
   in
   if (List.length x2) = 1 then (List.hd x2)
   else raise NonFunctionalMappingException

let dom (theta: ('a, 'b) table_fn_t): 'a list = fst (List.split theta)
let img (theta: ('a, 'b) table_fn_t): 'a list = snd (List.split theta)

let in_dom (theta: ('a, 'b) table_fn_t) (a:'a): bool = 
   List.mem_assoc a theta

let in_img (theta: ('a, 'b) table_fn_t) (b:'b): bool =
   List.exists (fun (_,cmp_b) -> cmp_b = b) theta

let functional (theta: ('a, 'b) table_fn_t): bool =
   let d = dom theta in
   ((ListAsSet.no_duplicates d) = d)

let onto (theta: ('a, 'b) table_fn_t): bool =
   let i = img theta in 
   ((ListAsSet.no_duplicates i) = i)
   
let merge ?(require_onto = false)
          (theta1:('a,'b) table_fn_t) (theta2:('a,'b) table_fn_t):
          (('a,'b) table_fn_t) option = 
   if List.exists (fun a -> (List.assoc a theta1) <> (List.assoc a theta2))
                  (ListAsSet.inter (dom theta1) (dom theta2))
   then None else 
   let merged = ListAsSet.union theta1 theta2 in
   if onto merged then Some(merged) else None

let multimerge (thetas:('a,'b) table_fn_t list): ('a,'b) table_fn_t option =
   List.fold_left (fun a b -> match a with Some(sa) -> merge sa b | None->None)
                  (Some([])) thetas


let identities (theta: ('a, 'a) table_fn_t): ('a list) =
   let f (x,y) = if (x=y) then [x] else [] in
   List.flatten (List.map f theta)

let intransitive (theta: ('a, 'a) table_fn_t): bool =
   ((ListAsSet.diff (ListAsSet.inter (dom theta) (img theta))
                    (identities theta)) = [])

(* only for functions from strings to strings *)
let string_of_string_fn theta: string =
   "{" ^(ListExtras.string_of_list ~sep:", " (fun (x,y) -> x^"->"^y) theta)^"}"