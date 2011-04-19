exception Assert0Exception of string

open Util
open Calculus

type todo_list_t = Compiler.map_ref_t list

type map_key_binding_t = 
    Binding_Present of var_t
  | Binding_Not_Present
type bindings_list_t = map_key_binding_t list
type map_ref_t = (term_t * term_t * bindings_list_t) 

type m3_condition_or_none =
    EmptyCondition
  | Condition of M3.calc_t


let rec find_binding_calc_lf (var: var_t) (calc: readable_relcalc_lf_t) =
  match calc with
  | False                                      -> false
  | True                                       -> false
  | AtomicConstraint(comp, inner_t1, inner_t2) ->
    (find_binding_term var inner_t1) || (find_binding_term var inner_t2)
  | Rel(relname, relvars) -> List.exists ((=) var) relvars 

and find_binding_calc (var: var_t) (calc: readable_relcalc_t) =
  match calc with
  | RA_Leaf(leaf)       -> find_binding_calc_lf var leaf
  | RA_Neg(inner_calc)  -> find_binding_calc var inner_calc
  | RA_MultiUnion(u)    -> 
    failwith "Compiler.ml: finding output vars in MultiUnion not implemented yet"
  | RA_MultiNatJoin(j)  -> List.exists (find_binding_calc var) j

and find_binding_term (var: var_t) (term: readable_term_t) = 
  match term with 
  | RVal(AggSum(inner_t,phi))  -> 
    (find_binding_calc var phi) || (find_binding_term var inner_t)

  | RVal(External(mapn, vars)) ->
    failwith ("Compiler.ml: (extract_output_vars) "^
      "A portion of an uncompiled term is already compiled!")

  | RVal(Var(v))   -> false
  | RVal(Const(c)) -> false
  | RNeg(inner_t)  -> (find_binding_term var inner_t)
  | RProd(inner_ts) -> List.exists (find_binding_term var) inner_ts 
  | RSum(inner_ts) -> List.exists (find_binding_term var) inner_ts

(* TODO: think about this definition more ... *)
let rec safe_term (term: readable_term_t) =
  match term with
  | RVal(AggSum(inner_t,phi))  -> safe_vars (make_relcalc phi) []
  | RNeg(inner_t)  -> safe_term inner_t
  | RProd(inner_ts) -> Util.ListAsSet.multiunion (List.map safe_term inner_ts) 
  | RSum(inner_ts) -> Util.ListAsSet.multiunion (List.map safe_term inner_ts)
  | _ -> []

let translate_var (calc_var:var_t): M3.var_t = (fst calc_var)

let translate_var_type (calc_var:var_t): M3.var_type_t = 
  match (snd calc_var) with
  | TInt    -> M3.VT_Int
  | TDouble -> M3.VT_Float
  | TLong   -> M3.VT_Int
  | TString -> M3.VT_String
  
let translate_schema (calc_schema:var_t list): M3.var_t list = 
  (List.map translate_var calc_schema)

let translate_map_ref ((t, mt): Compiler.map_ref_t) : map_ref_t =
  (t, mt, (
    let outer_term = (readable_term t) in 
    match (readable_term mt) with
    | RVal(External(n, vs)) -> 
      List.map (fun var ->  
          if List.mem var (safe_term outer_term)
          (*if (find_binding_term var outer_term)*)
          then Binding_Present(var)
          else Binding_Not_Present)
        vs
    | _ -> failwith "LHS of a map definition is not an External()"))


let rec to_m3_initializer (map_def: term_t) (vars: var_t list) 
                          (map_prefix: string): (M3.calc_t * todo_list_t) =
  let nested_counter = ref(-1) in
  let rec map_of_nested t =
    let auxl f tl = 
      let ntl, todosl = List.split (List.map map_of_nested tl)
      in ((f ntl), List.flatten todosl)
    in match t with
    | RVal(AggSum(f,r)) -> 
      let nested_mapn = incr nested_counter;
        map_prefix^"_nest"^(string_of_int !nested_counter) in
      (* Nested aggregates only have in vars, they must have no out vars since
       * they must be scalars *)
      let in_params =
        let rc_r = make_relcalc r
        in Util.ListAsSet.diff (relcalc_vars rc_r) (safe_vars rc_r [])
      in
      let nested_map_term = RVal(External(nested_mapn, in_params)) in
      let nested_map_ref = (make_term t, make_term nested_map_term)
      in (nested_map_term, [nested_mapn, nested_map_ref])

    | RVal(_) -> (t, [])
    | RNeg(t) -> let (nt,todos) = map_of_nested t in (RNeg(nt), todos)
    | RProd(tl) -> auxl (fun ntl -> RProd(ntl)) tl
    | RSum(tl) -> auxl (fun ntl -> RSum(ntl)) tl
  in
  let rec extract_filters phi_and_psi = 
    match phi_and_psi with 
      | RA_Leaf(Rel(_)) -> (([phi_and_psi], []), [])
      
      | RA_Leaf(AtomicConstraint(op,t1,t2)) ->
        let (psi, nested_todos) =
          let new_t1, t1_todos = map_of_nested t1 in
          let new_t2, t2_todos = map_of_nested t2
          in (RA_Leaf(AtomicConstraint(op,new_t1,new_t2)), t1_todos@t2_todos)
        in (([], [psi]), nested_todos)
      
      | RA_Leaf(_) -> (([], [phi_and_psi]), [])
      | RA_MultiNatJoin([]) -> (([], []), [])
      | RA_MultiNatJoin(sub_exp) -> 
          let (new_phi, new_psi, new_todos) =
            let x,y = List.split (List.map extract_filters sub_exp) in
            let a,b = List.split x
            in a, b, List.flatten y 
          in ((List.flatten new_phi, List.flatten new_psi), new_todos)
      | RA_Neg(_) -> failwith ("TODO: to_m3_initializer: RA_Neg")
      | RA_MultiUnion(_) -> failwith ("TODO: to_m3_initializer: RA_MultiUnion")
  in
  let merge_terms a b = 
    match (a,b) with
      | (RVal(Const(Int 1)),_) -> b
      | (_,RVal(Const(Int 1))) -> a
      | (RProd(at),RProd(bt)) -> RProd(at@bt)
      | (RProd(at),_) -> RProd(b::at)
      | (_,RProd(bt)) -> RProd(a::bt)
      | (_,_) -> RProd([a;b])
  in
  let rec extract_expression tau_and_theta =
    match tau_and_theta with
      | RVal(AggSum(t,p)) ->
         failwith "CalcToM3: Map definition contains nested aggsum"
      | RVal(Const(c)) -> (RVal(Const c), RVal(Const(Int 1)))
      | RVal(Var(v)) -> 
         if (find_binding_term v (readable_term map_def)) then 
            (RVal(Const(Int 1)), RVal(Var v))
         else (RVal(Var v), RVal(Const(Int 1)))
      | RVal(External(_,_)) -> 
         failwith "CalcToM3: Map definition contains map reference";
      | RNeg(sub) ->
         let (tau,theta) = extract_expression sub in (RNeg(tau), theta)
      | RProd(sub::rest) ->
         let (stau,stheta) = extract_expression sub in
         let (rtau,rtheta) = extract_expression (RProd(rest)) in
            (merge_terms stau rtau, merge_terms stheta rtheta)
      | RProd([]) -> (RVal(Const(Int 1)), RVal(Const(Int 1)))
      | RSum(list) ->
         failwith "CalcToM3: Map definition contains sum";
  in
  (* TODO: invoke simplify here *)
  match (readable_term map_def) with 
    | RVal(AggSum(tau_and_theta, phi_and_psi)) ->
      let ((phi, psi), nested_todos) = extract_filters phi_and_psi in
      let (tau, theta) = extract_expression tau_and_theta in
      let inner_vars = 
        ListAsSet.union 
          (term_vars (make_term theta))
          (relcalc_vars (make_relcalc (RA_MultiNatJoin(phi))))
      in
      let outer_vars =
        ListAsSet.union vars
          (relcalc_vars (make_relcalc (RA_MultiNatJoin(psi))))
      in
      let init_map_name = map_prefix^"_init" in
      let init_map_term = 
        RVal(External(init_map_name, 
                      ListAsSet.inter inner_vars outer_vars))
      in
      let init_map_defn = RVal(AggSum(theta,RA_MultiNatJoin(phi))) in
      let init_map_ref = (make_term init_map_defn, make_term init_map_term) in
      let (translated_init,other_todos) =
        begin 
          Debug.print "DUMP-INITIALIZERS" (fun () -> 
            "Cond: "^(Util.list_to_string (fun x -> 
                  (relcalc_as_string (make_relcalc x))) psi)^
            " AND "^(Util.list_to_string (fun x -> 
                  (relcalc_as_string (make_relcalc x))) phi)^
            "\n  Init: "^(term_as_string 
                  (make_term init_map_term))^
            "\n  Defn: "^(term_as_string 
                  (make_term theta)));
          (to_m3 
            (if psi = [] then failwith "Conditionless map initializer." else
              RVal(AggSum((merge_terms init_map_term tau), RA_MultiNatJoin(psi))))
            (List.fold_left
              (fun acc (nested_mapn, nested_map_ref) ->
                StringMap.add nested_mapn (translate_map_ref nested_map_ref) acc)
              (StringMap.add init_map_name 
                (translate_map_ref init_map_ref) StringMap.empty)
              nested_todos))
        end
      in
        (translated_init, (List.map snd nested_todos)@other_todos@[init_map_ref])

    | _ -> failwith ("TODO: to_m3_initializer: "^
                      (term_as_string map_def))

(********************************)
and split_vars (want_input_vars:bool) (vars:'a list) (bindings:bindings_list_t): 
               'a list = 
  List.fold_right2 (fun var binding ret_vars ->
    match binding with
    | Binding_Present(_)  -> if want_input_vars then ret_vars else var::ret_vars
    | Binding_Not_Present -> if want_input_vars then var::ret_vars else ret_vars
  ) vars bindings []
  
(********************************)

and to_m3_map_access 
    ((map_definition, map_term, bindings):map_ref_t)
    (vars:var_t list option) :
      M3.mapacc_t * todo_list_t =
  let (mapn, basevars) = (decode_map_term map_term) in
  let mapvars = 
    match vars with
      | Some(input_vars) -> 
          if List.length basevars = List.length input_vars then input_vars
          else failwith ("BUG: CalcToM3: map access '"^
                         (term_as_string map_term)^
                         "' with incorrect arity: "^
                         (list_to_string fst input_vars))
      | None -> basevars
   in
  let input_var_list = (split_vars true mapvars bindings) in
  let output_var_list = (split_vars false mapvars bindings) in
  let (init_stmt, todos) = 
      (*  Doing something smarter with the initializers... in particular, it 
          might be a good idea to see if any of the initialzers can be further 
          decompiled or pruned away.  For now, a reasonable heuristic is to use
          the presence of input variables *)
    if (List.length input_var_list) > 0
    then
      to_m3_initializer 
      (apply_variable_substitution_to_term
        (ListAsSet.no_duplicates (List.combine basevars mapvars))
        map_definition)
      (input_var_list@output_var_list)
      mapn
    else (M3.mk_c 0.0, [])
  in
    ((mapn, 
      (fst (List.split input_var_list)), 
      (fst (List.split output_var_list)), 
      (init_stmt, ())
    ), todos)

(********************************)

and to_m3 
  (t: readable_term_t) 
  (inner_bindings:map_ref_t Map.Make(String).t) : 
  M3.calc_t * todo_list_t =
  
   let calc_lf_to_m3 lf =
      match lf with
         AtomicConstraint(op,  t1, t2) ->
            let (lhs, lhs_todos) = (to_m3 t1 inner_bindings) in
            let (rhs, rhs_todos) = (to_m3 t2 inner_bindings) in
              ((match op with 
                  Eq -> M3.mk_eq
                | Le -> M3.mk_leq
                | Lt -> M3.mk_lt
                | _ -> failwith ("CalcToM3.to_m3: TODO: cmp_op")
              ) lhs rhs, lhs_todos@rhs_todos)
       | _ -> failwith ("CalcToM3.to_m3: TODO constraint '"^
                   (relcalc_as_string
                     (make_relcalc (RA_Leaf(lf))))^"' in '"^
                   (term_as_string
                     (make_term t))^"'")
   in
   let rec calc_to_m3 calc : M3.calc_t * todo_list_t =
      match calc with
         RA_Leaf(lf) -> calc_lf_to_m3 lf
       | RA_MultiNatJoin([lf]) ->  (calc_to_m3 lf) 
       | RA_MultiNatJoin(lf::rest) ->
          let (lhs, lhs_todos) = (calc_to_m3 lf) in
          let (rhs, rhs_todos) = 
            (calc_to_m3 (RA_MultiNatJoin(rest))) 
          in
            ((M3.mk_prod lhs rhs), lhs_todos@rhs_todos)
       | RA_MultiNatJoin([]) -> failwith "This shouldn't happen"
       | RA_MultiUnion(_) -> failwith ("BUG: non-monomial delta term")
       | RA_Neg(_) -> failwith ("BUG: negation in delta term")
       (*| _                    -> 
          failwith ("Compiler.to_m3: TODO calc: "^
            (relcalc_as_string (make_relcalc calc)))*)
   in
   let lf_to_m3 (lf: readable_term_lf_t) =
      match lf with
       | AggSum(t,RA_MultiNatJoin([])) -> (*if true*)
            (to_m3 t inner_bindings)
       | AggSum(t,phi)             -> 
            let (lhs, lhs_todos) = (calc_to_m3 phi) in
            let (rhs, rhs_todos) = (to_m3 t inner_bindings) in
              ((M3.mk_if lhs rhs), lhs_todos@rhs_todos)
       | External(mapn, map_vars)      -> 
          begin try
              let (access_term, todos) = 
                (to_m3_map_access 
                  (StringMap.find mapn inner_bindings)
                  (Some(map_vars)))
              in
                (M3.mk_ma access_term, todos)
          with Not_found -> 
              failwith ("Unable to find map '"^mapn^"' in {"^
                (StringMap.fold 
                  (fun k v accum -> accum^", "^k) 
                  inner_bindings "")^"}\n")
          end

       | Var(vn,vt)            -> (M3.mk_v vn, [])
       | Const(Int c)          -> (M3.mk_c (float_of_int c), [])
       | Const(Double c)       -> (M3.mk_c c, [])
       | Const(Long _)         -> failwith "Compiler.to_m3: TODO Long"
       | Const(String c)       -> (M3.mk_c (float_of_int (Hashtbl.hash c)), [])
       | Const(Boolean(false)) -> (M3.mk_c 0., [])
       | Const(Boolean(true))  -> (M3.mk_c 1., [])

   in
   match t with
      RVal(lf)      -> lf_to_m3 lf
    | RNeg(t1)      -> 
        let (rhs, todos) = (to_m3 t1 inner_bindings) in
        (M3.mk_prod (M3.mk_c (-1.0)) rhs, todos)
    | RProd(t1::[]) -> (to_m3 t1 inner_bindings)
    | RProd(t1::l)  -> 
        let (lhs, lhs_todos) = (to_m3 t1 inner_bindings) in
        let (rhs, rhs_todos) = (to_m3 (RProd l) inner_bindings) in
        (M3.mk_prod lhs rhs, lhs_todos@rhs_todos)
    | RProd([])     -> 
        (M3.mk_c 1.0, [])
        (* impossible case, though *)
    | RSum(t1::[])  -> 
        (to_m3 t1 inner_bindings)
    | RSum(t1::l)   -> 
        let (lhs, lhs_todos) = (to_m3 t1 inner_bindings) in
        let (rhs, rhs_todos) = (to_m3 (RSum l) inner_bindings) in
        (M3.mk_sum lhs rhs, lhs_todos@rhs_todos)
    | RSum([])      -> 
        (M3.mk_c 0.0, []) 
        (* impossible case, though *)

module M3InProgress = struct
  type mapping_params = (string * int list * int list)
  type map_mapping = mapping_params StringMap.t
  
  type possible_mapping = 
  | Mapping of mapping_params
  | NoMapping
  
  type trigger_map = (string * ((M3.var_t list) * (M3.stmt_t list))) list
  
  (* insertion triggers * deletion triggers * mappings * map definitions *)
  type t = trigger_map * trigger_map * map_mapping * 
           (string * map_ref_t) list
  
  type insertion = (map_ref_t * M3.trig_t list)
  
  let add_to_trigger_map rel vars stmts tmap =
    if List.mem_assoc rel tmap then
      let (tvars, tstmts) = List.assoc rel tmap in
      let joint_stmts = 
        (* We assume that we receive statements through build in the order that
           the statements should be executed in; This is rarely relevant but it
           is an atomicity guarantee made by M3.  The order with which we store
           relations is irrelevant, but within each relation's trigger, the
           statement order must be preserved *)
        (if tvars <> vars then
            List.map (M3Common.rename_vars vars tvars) stmts
          else stmts) @ tstmts
      in (rel, (tvars, joint_stmts))::(List.remove_assoc rel tmap)
    else (rel, (vars, stmts))::tmap

  let init: t = ([], [], StringMap.empty, [])
    
  let build ((curr_ins, curr_del, curr_mapping, curr_refs):t)   
            ((descriptor, triggers):insertion): t =
    let (query_term, map_term, map_bindings) = descriptor in
    let (map_name, map_vars) = decode_map_term map_term in
    let mapping = 
      List.fold_left (fun result (cmp_term, cmp_map_term, cmp_bindings) ->
        if result = NoMapping then
          let (cmp_name, cmp_vars) = decode_map_term cmp_map_term in
          try 
            if (List.length map_vars) <> (List.length cmp_vars) then
              raise (TermsNotEquivalent("Mismatched parameter list sizes"))
            else
            let var_mappings = equate_terms query_term cmp_term in
            (* We get 2 different mappings; Check to see they're consistent *)
            if not (List.for_all2 (fun (a,_) (b,_) -> (a = b) ||
                (* It shouldn't happen that a doesn't have a mapping in b, but
                   if it does, that just means the variable is unused in the
                   map definition *)
                  (StringMap.mem a var_mappings) || 
                    ((StringMap.find a var_mappings) = b))
                map_vars cmp_vars)
            then raise (TermsNotEquivalent("Mismatched parameter list s"))
            else
            let index_of (needle:var_t) (haystack:var_t list) = 
              let (index, _) =
                (List.fold_left (fun (found, index) cmp -> 
                    ((if cmp = needle then index else found), index + 1))
                  (-1, 1) haystack)
              in
              if index = -1 then 
                raise (TermsNotEquivalent("Variable Not Found: "^(fst needle)^
                         " in "^(list_to_string fst haystack)))
                                   (*shouldn't happen*)
              else index
            in
            let compute_mapping map_io_vars cmp_io_vars translation =
              List.fold_right (fun (var,var_type) mapping ->
                  (index_of (if StringMap.mem var translation 
                             then (StringMap.find var translation,var_type)
                             else (var,var_type)) cmp_io_vars)::mapping)
                map_io_vars []
            in
              Mapping(
                cmp_name,
                (compute_mapping (split_vars true map_vars map_bindings) 
                                 (split_vars true cmp_vars cmp_bindings)
                                 var_mappings),
                (compute_mapping (split_vars false map_vars map_bindings) 
                                 (split_vars false cmp_vars cmp_bindings)
                                 var_mappings))
          with TermsNotEquivalent(a) -> 
              Debug.print "TERM-COMPARISON" (fun () ->
                "Comparing "^map_name^" to existing "^cmp_name^"; "^a);
              NoMapping
        else result
      ) NoMapping (snd (List.split curr_refs))
    in
    let on_mapping_found (m:mapping_params) = 
      begin
        Debug.print "MAP-CALC" (fun () -> 
          let (sub_name,_,_) = m in
            (term_as_string map_term)^" (replaced by "^sub_name^") "^
            " := "^(term_as_string query_term));
        (curr_ins, (* an equivalent map exists. don't change anything *)
         curr_del,
         StringMap.add map_name m curr_mapping, (* just add a mapping *)
         curr_refs)
      end
    in
    let on_no_mapping () =
      begin
        Debug.print "MAP-CALC" (fun () -> 
          (term_as_string map_term)^
          " := "^(term_as_string query_term));
        let (insert_trigs, delete_trigs) =
          List.fold_left (fun (ins, del) (pm, rel, vars, stmts)  -> 
              match pm with 
              | M3.Insert -> ((add_to_trigger_map rel vars stmts ins), del)
              | M3.Delete -> (ins, (add_to_trigger_map rel vars stmts del)))
            (curr_ins, curr_del) triggers 
        in
        (insert_trigs, delete_trigs, 
         curr_mapping, 
         (map_name,descriptor)::curr_refs)
      end
    in
      if Debug.active "IGNORE-DUP-MAPS" then
        on_no_mapping ()
      else
        match mapping with
      | Mapping(m) -> on_mapping_found m
      | NoMapping  -> on_no_mapping ()
        
  
  let get_rel_schema ((ins_trigs,del_trigs,_,_):t): 
      (M3.var_t list) StringMap.t =
    let gather_schema (rel_name, (rel_vars, _)) accum  =
      StringMap.add rel_name rel_vars accum
    in
      List.fold_right gather_schema ins_trigs (
        List.fold_right gather_schema del_trigs 
          StringMap.empty)
  
  let get_maps ((_, _, mapping, maps):t) : M3.map_type_t list =
    List.map (fun (map_name, (map_defn, map_term, map_bindings)) ->
        let (_, map_vars) = decode_map_term map_term in
        (map_name, 
         List.map translate_var_type (split_vars true map_vars map_bindings),
         List.map translate_var_type (split_vars false map_vars map_bindings)))
      maps
  
  let get_triggers ((ins, del, mapping, _):t) : M3.trig_t list =
    let produce_triggers (pm:M3.pm_t) (tmap:trigger_map): M3.trig_t list =
      List.map (fun (rel_name, (rel_vars, triggers)) ->
          (pm, rel_name, rel_vars, 
            (List.map (fun trigger -> 
              (M3Common.rename_maps 
                (StringMap.map (fun (x,_,_)->x) mapping) trigger))
              triggers)))
        tmap
    in
      (produce_triggers M3.Insert ins) @ (produce_triggers M3.Delete del)
  
  let finalize (program:t) : M3.prog_t = 
    (get_maps program, get_triggers program)

  let get_map_refs ((_,_,mappings,refs):t) : map_ref_t StringMap.t =
    let mapped_map_terms: map_ref_t StringMap.t = 
      StringMap.map (fun (base_map,_,_) -> List.assoc base_map refs) mappings
    in
      List.fold_left (fun ref_map (map, ref) ->
          if StringMap.mem map ref_map then
            if ((StringMap.find map ref_map) <> ref) then
              let string_of_map (defn,term,_) = 
                (term_as_string term)^" := "^(term_as_string defn)
              in
              failwith ("BUG: duplicate map\n"^
                        (string_of_map (StringMap.find map ref_map))^"\n"^
                        (string_of_map ref))
            else ref_map
          else StringMap.add map ref ref_map)
        mapped_map_terms refs
      
  let rec compile 
              ?(top_down_depth = None)
              (schema:(string*(var_t list)) list)
              (map_ref:Compiler.map_ref_t)
              (accum:t) : t =
    Compiler.compile ~top_down_depth:top_down_depth
                     ModeOpenDomain
                     schema
                     map_ref
                     generate_m3
                     accum
    
  and generate_m3 (schema: (string*(var_t list)) list)
                  (map_ref: Compiler.map_ref_t)
                  (triggers: Compiler.trigger_definition_t list)
                  (accum: t): t =
    let map_ref_as_m3 = translate_map_ref map_ref in
    let (triggers_as_m3, todos) = 
      List.fold_left (fun (tlist,old_todos) 
                          (delete, reln, relvars, (params,bsvars), expr) ->
        
        (* eliminates loop vars by substituting unified map params *) 
        let sub_map_params (map_definition, map_term, map_bindings) params =
          let (map_name, map_vars) = (decode_map_term map_term) in
          ((apply_variable_substitution_to_term
              (List.combine map_vars params) map_definition), 
            (Calculus.map_term map_name params), 
            map_bindings)
        in
        let (target_access, init_todos) = 
          (to_m3_map_access (sub_map_params map_ref_as_m3 params)) None in
        let (update, update_todos) =
          to_m3 (readable_term expr) (get_map_refs accum) in
        let todos = old_todos @ init_todos @ update_todos in
        let update_trigger =
          ((if delete then M3.Delete else M3.Insert),
            reln, (translate_schema relvars),
            [(target_access, (update,()), ())])
        in
          
          Debug.print "MAP-DELTAS" (fun () -> 
              "ON "^(if delete then "-" else "+")^reln^
              (list_to_string (fun (a,_)->a) relvars)^
              ": "^(term_as_string (snd map_ref))^
              (list_to_string (fun (a,_)->a) params)^" += "^
              (term_as_string expr)^"\n   ->\n"^
              (M3Common.pretty_print_calc update)^"\n");
          
          if delete && Debug.active "DISABLE-DELETES" then (tlist, old_todos) 
          else (tlist @ [ update_trigger ], todos))
      ([], []) triggers
    in
      (build 
        (List.fold_left 
          (fun old_accum todo -> compile schema todo old_accum)
          accum todos)
        (map_ref_as_m3, triggers_as_m3))
end

let compile = M3InProgress.compile;;