(* 
  This module provides utility operations for converting between Calculus
  expressions and M3.
*)

(* 
  A worklist.
  This should really be done within the compiler, but Calculus doesn't really
  have a notion of map initialization; we add this after the fact while we build
  the M3.  Because the only thing we're given to build the initializer is the
  query defining the map, we can get some speedup by compiling portions (the 
  non-comparison portions) of the defining query. Consequently, the M3 
  translation code can produce additional compilation work.
*)
type todo_list_t = Compiler.map_ref_t list * string list

(*
  Variable bindings are used to distinguish between Input and Output Variables.
  Specifically, the compiler identifies (for every map) which variables have 
  been bound, either within the map, or outside of the map (see 
  find_binding_term).  A variable can either be bound from the inside within a
  map (in which case it's an output variable), or it can be unbound within the
  calculus expression defining the map (in which case it's an input variable).
  
  Three datastructures are used in conjunction with this functionality:

    A map_key_binding_t is the binding state of a single map key.  If the key
      is bound, it also includes a reference to the variable identifier it is
      bound to.
      
    A bindings_list_t is an ordered list of map bindings; A variable's position
      in this list corresponds to its position in the map's representation in 
      the Calculus expression produced by the compiler (see map_ref_t)
    
    A map_ref_t is a fully specified map lookup in internal Calculus terms.  
      It contains three parts:
        * Map Definition: A Calculus.term_t representing the calculus expression
          that defines the map.
        * Map Term: A Calculus.term_t containing a single RVal(External()) that
          represents the map's name and a list of its contained variables.
        * bindings: A bindings_list_t containing an ordered list of all variable
          bindings within the map term.  The order of variables in "bindings" 
          corresponds to the order of variables in "Map Term".  Note that this
          form roughly corresponds to the code produced by the compiler for
          each map.
*)
type map_key_binding_t = 
    Binding_Present of Calculus.var_t
  | Binding_Not_Present
type bindings_list_t = map_key_binding_t list
type map_ref_t = (Calculus.term_t * Calculus.term_t * bindings_list_t) 

(* 
  Given a Calculus expression representing the contents of a particular map
  produce the initialization expression for that map; For now this is done
  naively, with no recursive compilation of subexpressions where possible.
  
  In the process of computing this expression, also identify which maps are 
  referenced inside the expression. (see todo_list_t, above)
*)
val to_m3_initializer: (string * Calculus.var_t list) list -> 
                       Calculus.term_t -> Calculus.var_t list -> string ->
                       (M3.calc_t * todo_list_t)

(*
  Given a descriptor of a map reference in calculus terms, convert it to an M3
  mapacc_t Map access descriptor.  (see map_ref_t, above)
  
  In the process of computing this expression, also identify which maps are 
  referenced inside the expression. (see relation_set_t, above)
*)
val to_m3_map_access:
  (string * Calculus.var_t list) list ->
  map_ref_t ->
  Calculus.var_t list option ->
  (M3.mapacc_t * todo_list_t)

(* 
  Given a Calculus expression representing a particular trigger, convert it to
  an equivalent M3 expression. 
  
  Also takes a String->map_ref_t map; to_m3 expects an entry in this map for 
  every Map referenced as an external in the calculus expression.  The entry
  should contain the complete map_ref_t (see above) Calculus representation of
  a map lookup for that map.

  In the process of computing this expression, also identify which maps are 
  referenced inside the expression. (see relation_set_t, above)
*)
val to_m3:
  (string * Calculus.var_t list) list ->
  Calculus.readable_term_t ->
  map_ref_t Map.Make(String).t ->
  (M3.calc_t * todo_list_t)

(*
  Given a Calculus expression (representing a map's Map Definition) and a 
  Calculus variable, identify whether or not the variable is bound within
  the term.  This is used when constructing a bindings_list_t (see above)
*)
val find_binding_term: 
  Calculus.var_t ->
  Calculus.readable_term_t ->
  bool

(*
  Basic type translators
*)
val translate_var: Calculus.var_t -> M3.var_t

val translate_schema: Calculus.var_t list -> M3.var_t list

(*
  Translate the compiler's notion of a map definition:
    (map_definition, map_term) 
  into a full M3 map definition (a map_ref_t).  This effectively boils down to 
  identifying output variables in the map definition and storing them as a
  bindings_list_t
*)
val translate_map_ref: Compiler.map_ref_t -> map_ref_t

(* 
  Functions for iteratively constructing an M3.prog_t.  Start with init_m3_prog
  and add maps using build_m3_prog.  This process serves two purposes.  First,
  when building a program for one query, duplicate maps will be eliminated.
  More importantly, this makes it possible for the output of one compilation
  run to be easily merged with the output of other compilation runs.
*)
module M3InProgress : sig
  type t
  type insertion = (map_ref_t * M3.trig_t list)
  
  val init: t
  val build: t -> insertion -> t
  
  val get_maps: t -> M3.map_type_t list
  val get_triggers: t -> M3.trig_t list
  val finalize: t -> M3.prog_t
  
  (* generate_m3 can be passed in to Compiler.compile to produce 
     an M3ProgInProgress.t  Call finalize on it to get an M3.prog_t
  *) 
  val generate_m3: (string*(Calculus.var_t list)) list ->
                   Compiler.map_ref_t -> 
                   Compiler.trigger_definition_t list ->
                   t -> t
end

val compile : ?top_down_depth:(int option) -> 
              (string*(Calculus.var_t list)) list ->
              Compiler.map_ref_t -> M3InProgress.t -> M3InProgress.t
val nonincremental : (string*(Calculus.var_t list)) list ->
                     Compiler.map_ref_t -> M3InProgress.t -> M3InProgress.t
