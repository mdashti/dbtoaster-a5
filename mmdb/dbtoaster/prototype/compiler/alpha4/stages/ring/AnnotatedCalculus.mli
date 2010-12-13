open Calculus

module PipedCalculus : sig

   type piped_term_t
   
   (* Constructors *)
   val make_term:
      term_t ->     (* Map term : see Calculus.map_term *)
      term_t ->     (* Map definition : the term defining the map *)
      var_t list -> (* Input variables *)
      piped_term_t
   
   val convert_bigsum:
      term_t ->         (* Map term : see Calculus.map_term *)
      term_t ->         (* Map definition : the term defining the map *)
      var_t list ->     (* Input variables *)
      term_mapping_t -> (* Bigsum theta *)
      var_t list ->     (* Bigsum variables *)
      piped_term_t
   
   (* Accessors *)
   val get_definition: piped_term_t -> term_t
   val get_map_term:   piped_term_t -> term_t
   val get_vars:       piped_term_t -> var_t list
   val get_ivars:      piped_term_t -> var_t list
   val get_ovars:      piped_term_t -> var_t list
   val get_map_name:   piped_term_t -> string
   val get_subterms:   piped_term_t -> piped_term_t list
   val get_subterm:    piped_term_t -> string -> piped_term_t
   
   (* Operators *)
   val bigsum_rewrite:
   
   val extract_submaps:
   
   val extract_base_relations:

end

module DeltaCalulus : sig
   
   type delta_term_t
      
   val simplified_delta_terms: 
      bool ->             (* operation == delete *)
      string ->           (* Relation name *)
      var_t list ->       (* Relation variables (== tuple) *)
      piped_term_t ->     (* Term to be deltaed *)
      (delta_term_t list) (* Delta terms *)
   
end