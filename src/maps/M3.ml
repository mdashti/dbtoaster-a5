(** 
   The fourth representation in the calculus compiler pipeline
   (SQL -> Calc -> Plan -> M3). 
   
   An M3 program is a reshuffling of the triggers in a Plan, so that they're 
   organized by triggering event.  This is stored in addition to some user-
   defined metadata:
      -  A set of named queries that define what the user is interested in.
      -  A set of datastructures that will be used in the course of executing
         queries and triggers.
      -  The triggers themselves
      -  The schema of the database
*)

open Ring
open Arithmetic
open Type
open Calculus
open Plan

(**
   An M3 trigger: A (referenced) set of statements that are executed when a
   spefied event occurs.
*)
type 'expr trigger_base_t = {
   (** The triggering event *)
   event      : Schema.event_t;        
   (** The set of statements to execute *) 
   statements : ('expr Plan.stmt_base_t) list ref 
}

type trigger_t = expr_t trigger_base_t

(**
   One of the datastructures that appears in an M3 program.
*)
type map_t = 
   | DSView  of Plan.ds_t     (** An incrementally maintained view *)
   | DSTable of Schema.rel_t  (** A static base relation *)

(**
   An M3 program: the base type of the M3 module
*)
type prog_t = {

   queries   : (string * expr_t) list ref; (**
      Queries that form the API of the datastructure that we are creating.  
      Mostly these will just be a lookup of one or more datastructures.  For 
      debugging binaries generated by DBToaster, these queries will be executed 
      at the end of compilation to produce the output.
   *)
   
   maps      : map_t list ref; (**
      The set of datastructures (Maps) that we store.  These include:
      Views: Mutable datastructures representing the result of a query.  Views
             may appear on the left-hand side of a trigger statement, and are
             referenced in queries using '[External[...][...]]'
      Tables: Immutable datastructures loaded in at the start of processing.
              Tables may not be updated once processing has started, and are
              referenced in queries using [Rel(...)]
   *)
   
   triggers  : trigger_t list ref; (**
      Triggers for each event that can be handled by this program.  These
      use event times as defined in Schema, and statements (as defined in Plan)
      of the form [External[...][...]] ([:=] OR [+=]) CalculusExpression.  When 
      the triggerring event occurs, the specified CalculusExpression will be 
      evaluated (with the trigger's parameters in-scope), and used to update the
      specified view (which again, is sliced with the trigger's parameters in-
      scope).  
      
      The calculus expression may only contain [Rel(...)] terms referencing 
      [TableRel]s.
      
      Every possible trigger that can occur in this program *must* be defined,
      even if it has no accompanying statements.  This means both an Insert
      and a Delete trigger for every [StreamRel].
   *)

   db        : Schema.t (**
      The schema of the overall database.  
      Restriction: For each StreamRel in the db schema, there must be insert
      and delete triggers.  For each TableRel in the db schema, there must be
      a corresponding DSTable() in maps. 
   *)
}


(************************* Stringifiers *************************)

(**
   [string_of_map ~is_query:(...) map]

   Generate the Calculusparser compatible declaration for the specified map.
   @param is_query (optional) True if the map should be declared as a toplevel 
                   query (default: false).
   @param map      A map
   @return         The (Calculusparser-compatible) declaration for [map]
*)
let string_of_map ?(is_query=false) (map:map_t): string = begin match map with
   | DSView(view) -> 
      "DECLARE "^
      (if is_query then "QUERY " else "")^
       "MAP "^(CalculusPrinter.string_of_expr ~show_type:true view.ds_name)^
      " := \n"^
      (CalculusPrinter.string_of_expr view.ds_definition)^";"
   | DSTable(rel) -> Schema.code_of_rel rel
   end

(**
   [string_of_trigger trigger]
   
   Generate the Calculusparser compatible declaration for the specified trigger.
   @param trigger  An M3 trigger
   @return         The (Calculusparser-compatible) declaration for [trigger]
*)
let string_of_trigger (trigger:trigger_t): string = 
   (Schema.string_of_event trigger.event)^" {"^
   (ListExtras.string_of_list ~sep:"" (fun stmt ->
      "\n   "^(Plan.string_of_statement stmt)^";"
   ) !(trigger.statements))^"\n}"

(**
   [string_of_m3 prog]
   
   Generate the Calculusparser compatible string representation of an M3 
   program.
   @param prog  An M3 program
   @return      The (Calculusparser-compatible) string representation of [prog]
*)
let string_of_m3 (prog:prog_t): string = 
   "-------------------- SOURCES --------------------\n"^
   (Schema.code_of_schema prog.db)^"\n\n"^
   "--------------------- MAPS ----------------------\n"^
   (* Skip Table maps -- these are already printed above in the schema *)
   (ListExtras.string_of_list ~sep:"\n\n" string_of_map (List.filter (fun x ->
      match x with DSTable(_) -> false | _ -> true) !(prog.maps)))^"\n\n"^
   "-------------------- QUERIES --------------------\n"^
   (ListExtras.string_of_list ~sep:"\n\n" (fun (qname,qdefn) ->
      "DECLARE QUERY "^qname^" :=\n"^(CalculusPrinter.string_of_expr qdefn)^";"
   ) !(prog.queries))^"\n\n"^
   "------------------- TRIGGERS --------------------\n"^
   (ListExtras.string_of_list ~sep:"\n\n" string_of_trigger !(prog.triggers))


(************************* Accessors/Mutators *************************)

(** 
   [get_trigger prog event]

   Obtain the trigger for the specified event from an M3 program.
   @param prog    An M3 program
   @param event   An event
   @return        The trigger for [event] in [prog].
*)
let get_trigger (prog:prog_t) (event:Schema.event_t): trigger_t =
   List.find (fun trig -> Schema.events_equal event trig.event) !(prog.triggers)
;;

(**
   [get_triggers prog]
   
   Obtain all triggers from the specified M3 program.
   @param prog   An M3 program
   @return       All the triggers in [prog]
*)
let get_triggers (prog:prog_t) : trigger_t list =
    !(prog.triggers)
;;

(** 
   [get_statement prog event target_map]

   Obtain the statement of the given name for the specified event 
   from an M3 program.
   @param prog    An M3 program
   @param event   An event
   @param name    A statement name
   @return        The trigger for [event] in [prog].
*)
let get_statement (prog:prog_t) (event:Schema.event_t) 
                  (name:string): stmt_t =
   let trigger = get_trigger prog event in
   List.find (fun stmt ->
      List.hd (externals_of_expr stmt.target_map) = name
   ) !(trigger.statements)

(**
   [add_rel prog ~source:(...) ~adaptor:(...) rel]
   
   Add a relation to the specified M3 program.  Empty (no-op) triggers for 
   events generated by the relation will also be added if the relation is a
   streaming relation, and the relation will be added as a datastructure if it
   is a table relation.
   @param prog    An M3 program 
   @param source  The source that tuples in [rel] are read from
   @param adaptor The adaptor for parsing out tuples in [rel]
   @param rel     The relation to add to [prog]
*)
let add_rel (prog:prog_t) ?(source = Schema.NoSource)
                          ?(adaptor = ("", []))
                          (rel:Schema.rel_t): unit = 
   Schema.add_rel prog.db ~source:source ~adaptor:adaptor rel;
   let (rname,_,t) = rel in 
   if t = Schema.TableRel then
      prog.maps     := (DSTable(rel)) :: !(prog.maps)
   else
      prog.triggers := { event = (Schema.InsertEvent(rel)); statements=ref [] }
                    :: { event = (Schema.DeleteEvent(rel)); statements=ref [] }
                    :: { event = (Schema.BatchUpdate(rname)); statements=ref [] }
                    :: !(prog.triggers)
;;

(**
   [add_query prog name expr]
   
   Add a toplevel query to the specified M3 program.
   @param prog An M3 program
   @param name The name of the toplevel query to add
   @param expr An expression defining how the query is to be evaluated (this is
               typically just a reference to an external).
*)   
let add_query (prog:prog_t) (name:string) (expr:expr_t): unit =
   prog.queries := !(prog.queries) @ [(name, expr)]
;;

(**
   [add_view prog view]
   
   Define a new view datastructure in the specified M3 program.
   @param prog An M3 program
   @param view The view definition to add to [prog]
*)
let add_view (prog:prog_t) (view:Plan.ds_t): unit =
   prog.maps := !(prog.maps) @ [DSView(view)]
;;

(**
   [add_stmt prog event stmt]
   
   Add a statement to the specified M3 program.  The statement is rewritten to
   use the schema of the existing event (which must have been created by 
   calling [add_rel], or an equivalent operation first).
   @param prog    An M3 program
   @param event   The event that should trigger execution of [stmt]
   @param stmt    The statement to add to [prog]
   @raise Not_found If [event] has not been defined in [prog]
*)
let add_stmt (prog:prog_t) (event:Schema.event_t)
                           (stmt: stmt_t): unit =
   let (relv) = Schema.event_vars event in
   try
      let trigger = get_trigger prog event in
      let trig_relv = Schema.event_vars trigger.event in
      (* We need to ensure that we're not clobbering any existing variable names
         with these rewrites.  This includes not just the update expression, 
         but also any IVC computations present in the target map reference *)
      let safe_mapping = 
         (find_safe_var_mapping 
            (find_safe_var_mapping 
               (List.combine relv trig_relv) 
               stmt.update_expr)
            stmt.target_map)
      in
      trigger.statements := !(trigger.statements) @ [{
         target_map = rename_vars safe_mapping stmt.target_map;
         update_type = stmt.update_type;
         update_expr  = rename_vars safe_mapping stmt.update_expr
      }]
   with Not_found -> 
      failwith "Adding statement for an event that has not been established"
;;

(************************* Initializers *************************)

(**[default_triggers ()]
   
   The default list of triggers to store in a blank M3 program.  This includes
   all non-relation triggers
*)
let default_triggers () = 
   List.map (fun x -> { event = x; statements = ref [] })
   [  Schema.SystemInitializedEvent ]
;;

(**[init db]
   
   Initialize an M3 program from a database schema
   @param db   The database schema to initialize the program with
   @return     An empty M3 program initialized for use with schema [db]
*)
let init (db:Schema.t): prog_t = 
   let (db_tables, db_streams) = 
      List.partition (fun (_,_,t) -> t = Schema.TableRel)
                     (Schema.rels db)
   in
   {  queries = ref [];
      maps    = ref (List.map (fun x -> DSTable(x)) db_tables);
      triggers = 
         ref ((List.map (fun x -> { event = x; statements = ref [] })
            (List.flatten 
               (List.map (fun (rname, rvars, rtype) -> 
                     [  Schema.InsertEvent(rname, rvars, rtype); 
                        Schema.DeleteEvent(rname, rvars, rtype);
                        Schema.BatchUpdate(rname)  ])
                     db_streams))) @
               (default_triggers ()));
      db = db
   }
;;
 
(**[finalize prog]
   Remove empty triggers and corresponding StreamRels from the program.
*)
let finalize (prog: prog_t): prog_t =
   let non_empty_triggers = 
      List.filter (fun trigger -> 
         match trigger.event with 
            | Schema.InsertEvent(_, _, _) 
            | Schema.DeleteEvent(_, _, _)
            | Schema.BatchUpdate(_) -> !(trigger.statements) <> []
            | _ -> true
      ) (get_triggers prog)
   in 
   let non_empty_db = 
      let used_relations = ListAsSet.multiunion (
         List.map (function
            | DSView(view) -> rels_of_expr view.ds_definition
            | _ -> []            
         ) !(prog.maps)
      )
      in   
      List.flatten (List.map (fun (s, relations) -> 
         let non_empty_relations = 
            List.filter(fun (_, (reln, _, _)) -> 
               List.mem reln used_relations 
            ) relations
         in
         if (non_empty_relations <> []) then 
            [ (s, non_empty_relations) ]
         else []   
      ) !(prog.db))    
   in
   prog.triggers := non_empty_triggers;
   prog.db       := non_empty_db;
   prog   

(**[empty_prog ()]
   
   Initialize an empty M3 program with an empty schema.
*)
let empty_prog (): prog_t = 
   {  queries = ref []; maps = ref []; triggers = ref (default_triggers ()); 
      db = Schema.empty_db () }
;;

(**[sort_prog prog]
  
   Reorder statements such that all update statements precede replace 
   statements and update statements are first used on the left hand side 
   and then incremented. Dependencies between statements are encoded 
   in the form of a graph. Topological sort is used to create a new 
   order of statements.    
 *)
let sort_prog (prog:prog_t):prog_t =
   List.iter (fun (trigger: trigger_t) ->
      (* Filter out local trigger statements, these should always come first *)
      let (local_stmts, trigger_stmts) =
         List.partition (fun stmt -> deltarels_of_expr stmt.update_expr <> []) 
                        !(trigger.statements) 
      in
      let local_externals = List.flatten (List.map (fun stmt -> 
         externals_of_expr stmt.target_map) local_stmts)
      in
      (* The fact that all update statements must precede *)
      (* replace statements is represented within the graph *)
      let replace_stmts = 
         List.filter (fun stmt -> stmt.update_type = Plan.ReplaceStmt) 
                     trigger_stmts
      in
      (* The list of names of all maps that are being re-evaluated *) 
      let replace_target_names = 
         List.map (fun stmt -> List.hd (externals_of_expr stmt.target_map)) 
                  replace_stmts 
      in
      (* Create a graph to encode dependencies between maps *)

      let graph = List.map (fun stmt ->
         let (target_name,_,_,_,target_ivc) = expand_ds_name stmt.target_map in
         let ivc_names = match target_ivc with
            | None -> []
            | Some(unwrapped_ivc) -> externals_of_expr unwrapped_ivc
         in
         (* When computing dependencies ignore local maps *)
         let update_names = 
            ListAsSet.diff 
               (ListAsSet.union ivc_names (externals_of_expr stmt.update_expr))
               local_externals
         in
            Debug.print "LOG-M3-SORT" (fun () -> 
               "'"^target_name^"' depends on: "^
               (ListExtras.ocaml_of_list (fun x -> x) update_names)
            );
            if (stmt.update_type = Plan.UpdateStmt)
            then (target_name, ListAsSet.union update_names 
                                               replace_target_names)
            else (target_name, ListAsSet.inter update_names
                                               replace_target_names)
      ) trigger_stmts in  
      
      (* Topologically sort the graph and create a new order of statements *)
      let new_stmt_order =  
         List.fold_left (fun stmt_order name ->
            try
               let next_stmt = get_statement prog trigger.event name in
                  (stmt_order @ [next_stmt])
            with Not_found -> stmt_order 
         ) [] (ListExtras.toposort graph) 
      in
         trigger.statements := local_stmts @ new_stmt_order;
   ) (get_triggers prog);
   prog

(**[plan_to_m3 db plan]
   
   Translate a compiler plan into an M3 program.  This involves grouping each
   datastructure's maintenance triggers by the triggering event. Update 
   statements are placed before replace statements for correctness; the total
   order of each type is preserved.
   @param db   The database schema
   @param plan A compiler plan
   @return     The M3 program representation of [plan]
*)
let plan_to_m3 (db:Schema.t) (plan:Plan.plan_t):prog_t =
   let prog = init db in
   List.iter (fun (ds:Plan.compiled_ds_t) -> 
      add_view prog ds.description;
      List.iter (fun (event, stmt) ->
         add_stmt prog event stmt
      ) (ds.triggers)
   ) plan;
   finalize (sort_prog prog)
;;

