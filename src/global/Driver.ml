(**
   Command and control functionality; The main() function of the dbtoaster 
   binary
*)
let (inform, warn, error, bug) = Debug.Logger.functions_for_module ""

;;

(************ Language Names ************)
type language_t =
   | Auto | SQL | Calc  | MPlan | DistM3 | M3 | AnnotM3 | M3DM | K3 
   | IMP  | CPP | Scala | LMS   | Ocaml  | Interpreter

let languages =
   (* string     token         human-readable string         show in help?  *)
   [  "AUTO"         , (Auto       , "automatic"                      , false); 
      "SQL"          , (SQL        , "DBToaster SQL"                  , false);
      "CALC"         , (Calc       , "DBToaster Relational Calculus"  , true);
      "PLAN"         , (MPlan      , "Materialization Plan"           , false);
      "M3"           , (M3         , "M3 Program"                     , true);
      "DISTM3"       , (DistM3     , "Distributable M3 Program"       , false);
      "ANNOTM3"      , (AnnotM3    , "Annotated M3 Program"           , false);
      "M3DM"         , (M3DM       , "M3 Domain Maintenance Program"  , false);
      "K3"           , (K3         , "K3 Program"                     , false);
      "IMP"          , (IMP        , "Abstract Imperative Program"    , false);
      "SCALA"        , (Scala      , "Scala Code"                     , true);
      "LMS"          , (LMS        , "LMS-friendly Scala Code"        , false);
    (*"OCAML"        , (Ocaml      , "Ocaml Code"                     , false); *)
      "RUN"          , (Interpreter, "Ocaml Interpreter"              , false);
      "CPP"          , (CPP        , "C++ Code"                       , true);
   ]

let input_language  = ref Auto
let output_language = ref Auto

let parse_language lang = 
   if List.mem_assoc (String.uppercase lang) languages then
      let (l,_,_) = 
         (List.assoc (String.uppercase lang) languages)
      in l
   else 
      raise (Arg.Bad("Unknown language "^lang))
;;

(************ Output Formatting ************)
let (files:string list ref) = ref [];;
let output_file = ref "-";;
let output_filehandle = ref None;;
let binary_file = ref "";;
let compiler = ref ExternalCompiler.null_compiler;;

(* Creates the directories of path 'p', where the last element is a file *)
let rec mk_path p =
   if String.contains p '/' then (
      let dir_sep_idx = String.rindex p '/' in
      let dir = String.sub p 0 dir_sep_idx in
      if not (Sys.file_exists dir) then (
         mk_path dir;
         Unix.mkdir dir 0o750 )
      else if not (Sys.is_directory dir) then
            raise (Arg.Bad(dir^" already exists and is not a directory."))
   )
      
let output_static outfile_name outfile_handle s = 
   let fh = 
      match !outfile_handle with 
      | None -> 
         let fh = 
            if !outfile_name = "-" then stdout
            else (
               mk_path !outfile_name;
               open_out !outfile_name )
         in
            output_filehandle := Some(fh); fh
      | Some(fh) -> fh
   in
      output_string fh s
;;

let output_endline_static outfile_name outfile_handle s = output_static outfile_name outfile_handle (s^"\n");;
      
let output s = output_static output_file output_filehandle s;;

let output_endline s = output (s^"\n");;

let flush_output () = 
   match !output_filehandle with None -> ()
   | Some(fh) -> flush fh;;

(************ Optimizations ************)
let optimizations_by_level = 
   [  (** -O1 **) [
         "WEAK-EXPR-EQUIV";
         "K3-NO-OPTIMIZE";
         "COMPILE-WITHOUT-OPT";
         "DUMB-LIFT-DELTAS";
      ]; 
      (** -O2 **) [
      ];
      (** -O3 **) [
         "AGGRESSIVE-FACTORIZE";
         "AGGRESSIVE-UNIFICATION";
         "DELETE-ON-ZERO";
         "OPTIMIZE-PATTERNS";
      ];
      (** -O4 **) [
         "K3-NO-OPTIMIZE";
         "LMS-OPTIMIZE";
      ];
   ]
let optimizations = 
   ListAsSet.union (ListAsSet.multiunion optimizations_by_level) [
      "IGNORE-DELETES"; "HEURISTICS-ALWAYS-UPDATE";
      "HASH-STRINGS"; "EXPRESSIVE-TLQS"; "COMPILE-WITH-STATIC";
      "CALC-DONT-CREATE-ZEROES"; "HEURISTICS-ENABLE-INPUTVARS";
      
      (* This is generally more efficient, but doesn't respect side-effect-
         producing statements, and is unsafe *)
      "K3-OPTIMIZE-LIFT-UPDATES";
   ]
let opt_level = ref 2;;
let max_compile_depth = ref None;;

(************ Command Line Parsing ************)
let specs:(Arg.key * Arg.spec * Arg.doc) list  = Arg.align [ 
   (  "-l", 
      (Arg.String(fun x -> output_language := parse_language x)), 
      "lang   Set the compiler's output language to lang");
(*     Disabled in the release.  Use .suffix instead  
   (  "-i", 
      (Arg.String(fun x -> input_language := parse_language x)),
      "lang   Set the compiler's input language to lang"); *)
   (  "-d",
      (Arg.String(fun x -> Debug.activate (String.uppercase x))),
      "mode   Activate indicated debugging output mode");
   (  "-o",
      (Arg.Set_string(output_file)),
      "file   Direct the output of dbtoaster (default: stdout)" );
   (  "-c",
      (Arg.Set_string(binary_file)),
      "file   Invoke a second stage compiler on the source file");
   (  "-r",
      (Arg.Unit(fun () -> output_language := Interpreter)),
      "       Run the query in the internal interpreter");
   (  "--custom-prefix",
      (Arg.String(FreshVariable.set_prefix)),
      "pfx    Specify a prefix for generated symbols");
   (  "--debug",
      (Arg.Unit(fun () -> 
               output_language := Interpreter;
               Debug.activate "STEP-INTERPRETER";
               Debug.activate "LOG-INTERPRETER-UPDATES")),
      "       Run the interpreter in debugging mode");
   (  "--depth",
      (Arg.Int(fun d -> max_compile_depth := Some(d))),
      "       Set the compiler's maximum recursive depth");
   (  "--reeval",
      (Arg.Unit(fun () -> 
         max_compile_depth := Some(0);
         Debug.activate "EXPRESSIVE-TLQS"
      )),
      "       Generate a non-incremental query engine.");
   (  "--batch",
      (Arg.Unit(fun () -> Debug.activate "BATCH-UPDATES")),
      "       Generate a batch query engine.");
   (  "-I", 
      (Arg.String(ExternalCompiler.add_env "INCLUDE_HDR")),
      "dir    Add a directory to the second-stage compiler's include path");
   (  "-L", 
      (Arg.String(ExternalCompiler.add_env "INCLUDE_LIB")),
      "dir    Add a directory to the second-stage compiler's library path");
   (  "-g",
      (Arg.String(ExternalCompiler.add_flag)),
      "arg    Pass through an argument to the second-stage compiler");
   (  "-O1",
      (Arg.Unit(fun () -> opt_level := 1)),
      "       Produce less efficient code faster");
   (  "-O2",
      (Arg.Unit(fun () -> opt_level := 2)),
      "       A balance between efficient code and compilation speed");
   (  "-O3",
      (Arg.Unit(fun () -> opt_level := 3)),
      "       Produce the most efficient code possible");
   (  "-O4",
      (Arg.Unit(fun () -> opt_level := 4)),
      "       Produce the upper most efficient code possible using LMS");
   (  "-D", 
      (Arg.String(ExternalCompiler.add_flag ~switch:"-D")),
      "macro Define a macro when invoking the second-stage compiler");
   (  "-F",
      (Arg.String(fun opt -> 
         if not (List.mem opt optimizations) then
            raise (Arg.Bad("Invalid -F flag: "^opt))
         else
            Debug.activate opt)),
      "flag   Activate the specified optimization flag");
   (  "-?", 
      (Arg.Unit(fun () -> raise (Arg.Bad("")) )), 
      "       Display this list of options");
];;

Arg.parse specs (fun x -> files := !files @ [x]) (
   "dbtoaster [opts] sourcefile1 [sourcefile2 [...]]"^
   "\n---- Supported Languages ----"^
   (ListExtras.string_of_list ~sep:"" (fun (short,(_,title,show)) ->
      if not show then "" else 
         "\n  "^short^(String.make (15-(String.length short)) ' ')^title
   ) languages)^
   "\n---- Options ----"
)
          
;;
if List.length !files < 1 then (
   error "No Files Specified; Exiting"
)
;;

(************ Optimization Choices ************)
if (!opt_level < 0) || (!opt_level > List.length optimizations_by_level) then 
   bug ("Invalid -O flag :"^(string_of_int !opt_level))
else
   List.iter Debug.activate 
             (List.nth optimizations_by_level (!opt_level - 1))
;;

let imperative_opts:ImperativeCompiler.compiler_options ref = ref {
   ImperativeCompiler.desugar = not (Debug.active "IMP-NO-DESUGAR");
   ImperativeCompiler.profile = Debug.active "ENABLE-PROFILING";
};;

(************ Stage Planning ************)

let suffix_regexp = Str.regexp ".*\\.\\([^.]*\\)$" in
   if !input_language == Auto then (
      let first_file = (List.hd !files) in
      if Str.string_match suffix_regexp first_file 0 then 
         input_language := (
            let suffix = (Str.matched_group 1 first_file) in
            match String.lowercase suffix with
               | "sql" -> SQL
               | "m3"  -> M3
               | "k3"  -> K3
               | _     -> SQL
         )
      else (* If you can't autodetect it from the suffix, fall back to SQL *)
         input_language := SQL
   );
   if !output_language = Auto then (
      let default_language = if (!binary_file) = "" then Interpreter else CPP in
      output_language := 
         if !output_file = "-" then default_language else
         if Str.string_match suffix_regexp !output_file 0
         then let suffix = (Str.matched_group 1 !output_file) in
            begin match suffix with
             | "sql"   -> SQL
             | "m3"    -> M3
             | "k3"    -> K3
             | "cpp"
             | "hpp"
             | "h"     -> CPP
             | "scala" -> Scala
             | _       -> K3
            end
         else default_language
   )            
;;

Debug.print "LOG-DRIVER" (fun () ->
   let language_map = List.map (fun (_,(key,name,_)) ->
      (key, name)
   ) languages in
      "Input Language: "^(List.assoc !input_language language_map)^"\n"^
      "Output Language: "^(List.assoc !output_language language_map)
)

type stage_t = 
   | StageParseSQL
 | SQLMarker
   | StagePrintSQL
   | StageSQLToCalc
   | StageParseCalc
 | CalcMarker
   | StagePrintCalc
   | StagePrintSchema
   | StageCompileCalc
 | PlanMarker
   | StagePrintPlan
   | StagePlanToM3
   | StageParseM3
 | M3Marker
   | StageM3DomainMaintenance
   | StageM3ToDistM3
   | StageM3ToAnnotM3
   | StagePrintM3
   | StagePrintM3DomainMaintenance
   | StageM3ToK3
   | StageM3DMToK3
   | StageParseK3
 | K3Marker
   | StageOptimizeK3
   | StageOptimizeLMS
   | StagePrintK3
   | StageK3ToTargetLanguage
 | FunctionalTargetMarker
   | StageImpToTargetLanguage
   | StagePrintImp
 | ImperativeTargetMarker
   | StageRunInterpreter
   | StageOutputSource
   | StageCompileSource

let output_stages = 
   [  StagePrintSQL; StagePrintSchema; StagePrintCalc; StagePrintPlan;
      StagePrintM3; StagePrintM3DomainMaintenance; StagePrintK3; StagePrintImp;
      StageOutputSource;  ]
let input_stages = 
   [  StageParseSQL; StageParseCalc; StageParseM3; StageParseK3  ]
let optional_stages =
   [  StageM3ToDistM3; StageM3ToAnnotM3; StageRunInterpreter; 
      StageCompileSource  ]

(* The following list (core_stages) MUST be kept in order of desired execution.

   The list of active stages is created with the user's choice of input and 
   output formats determining which stages are unnecessary: This includes all 
   stages before the stage that would normally be used to generate the desired 
   input format (e.g., StageSQLToCalc if Calculus is the input format), and all 
   stages after the stage that produces the desired output format. *)
let core_stages = 
   [  SQLMarker;   (* -> *) StageSQLToCalc; 
      CalcMarker;  (* -> *) StageCompileCalc; 
      PlanMarker;  (* -> *) StagePlanToM3;
      M3Marker;    (* -> *) StageM3DomainMaintenance; StageM3ToK3; 
                            StageM3DMToK3;
      K3Marker;    (* -> *) StageOptimizeK3; StageOptimizeLMS; StageK3ToTargetLanguage;
      FunctionalTargetMarker; StageImpToTargetLanguage; 
      ImperativeTargetMarker; 
   ]

let stages_from (stage:stage_t): stage_t list =
   ListExtras.sublist (ListExtras.index_of stage core_stages) (-1) core_stages
let stages_to   (stage:stage_t): stage_t list =
   ListExtras.sublist 0 ((ListExtras.index_of stage core_stages)+1) core_stages

let compile_stages final_stage target_compiler =
   compiler := target_compiler;
   StageOutputSource::(stages_to final_stage);;
let functional_stages = compile_stages FunctionalTargetMarker;;
let imperative_stages = compile_stages ImperativeTargetMarker;;

let active_stages = ref (ListAsSet.inter
   ((match !input_language with
      | Auto     -> bug "input language still auto"; []
      | SQL      -> StageParseSQL::(stages_from SQLMarker)
      | Calc     -> StageParseCalc::(stages_from CalcMarker)
      | M3       -> StageParseM3::(stages_from M3Marker)
      | K3       -> StageParseK3::(stages_from K3Marker)
      | _        -> error "Unsupported input language"; []
    )@output_stages@optional_stages)
   ((match !output_language with
      | Auto     -> bug "output language still auto"; []
      | SQL      -> StagePrintSQL::(stages_to SQLMarker)
      | Calc     -> StagePrintCalc::(stages_to CalcMarker)
      | MPlan    -> StagePrintPlan::(stages_to PlanMarker)
      | M3       -> StagePrintM3::(stages_to M3Marker)
      | DistM3   -> StagePrintM3::StageM3ToDistM3::(stages_to M3Marker)
      | AnnotM3  -> StageM3ToAnnotM3::(stages_to M3Marker)
      | M3DM     -> StagePrintM3DomainMaintenance::
                     (stages_to StageM3DomainMaintenance)
      | K3       -> StagePrintK3::StageOptimizeK3::(stages_to K3Marker)
      | IMP      -> StagePrintImp::(stages_to FunctionalTargetMarker)
      | Scala    -> functional_stages ExternalCompiler.scala_compiler
      | LMS      -> Debug.deactivate "LMS-OPTIMIZE"; StageOutputSource::(stages_to FunctionalTargetMarker)
      | Ocaml    -> functional_stages ExternalCompiler.ocaml_compiler
      | CPP      -> imperative_stages ExternalCompiler.cpp_compiler
         (* CPP is defined as a functional stage because the IMP implementation
            desperately needs to be redone before we can actually use it as an 
            reasonable intermediate representation.  For now, we avoid the
            imperative stage and produce C++ code directly after the 
            functional stage. *)
      | Interpreter
              -> StageRunInterpreter::(stages_to FunctionalTargetMarker)
(*    | _     -> error "Unsupported output language"*)
    )@input_stages))
;;
let stage_is_active s = List.mem s !active_stages;;
let activate_stage s  = active_stages := ListAsSet.union !active_stages [s];;
Debug.exec "LOG-SQL"    (fun () -> activate_stage StagePrintSQL);;
Debug.exec "LOG-CALC"   (fun () -> activate_stage StagePrintCalc);;
Debug.exec "LOG-SCHEMA" (fun () -> activate_stage StagePrintSchema);;
Debug.exec "LOG-PLAN"   (fun () -> activate_stage StagePrintPlan);;
Debug.exec "LOG-M3"     (fun () -> activate_stage StagePrintM3);;
Debug.exec "LOG-M3DM"   (fun () -> activate_stage 
                                   StagePrintM3DomainMaintenance);;
Debug.exec "LOG-K3"     (fun () -> activate_stage StagePrintK3);;
Debug.exec "LOG-PARSER" (fun () -> let _ = Parsing.set_trace true in ());;
Debug.exec "DEBUG-DM"   (fun () -> 
      Debug.activate "DEBUG-DM-IVC"; 
      Debug.activate (*"K3-NO-OPTIMIZE"*)"K3-NO-OPTIMIZE-LIFT-UPDATES";
      Debug.activate "DEBUG-DM-WITH-M3";
  if not (Debug.active "DEBUG-DM-NO-LEFT") then
      Debug.activate "DEBUG-DM-LEFT"
  else
      Debug.activate "M3TOK3-GENERATE-INIT"
);;

(* If we're compiling to a binary (i.e., the second-stage compiler is being
   invoked), then we need to store the compiler output in a temporary file.
   Here, we assume that the user does not wish to see the compilation results.
*)
if !binary_file <> "" then (
   activate_stage StageCompileSource;
   if !output_file = "-" then (
      let (fname, stream) = 
         Filename.open_temp_file ~mode:[Open_wronly; Open_trunc]
                                 "dbtoaster_"
                                 (!compiler).ExternalCompiler.extension
      in
         output_file := fname;
         output_filehandle := Some(stream);
         at_exit (fun () -> Unix.unlink fname)
   )
)

(************ Globals Used Across All Stages ************)
(**Program generated from the SQL files in the input.  Generated in 
   StageParseSQL *)
let sql_program:Sql.file_t ref = ref Sql.empty_file;;

(**Schema of the database, including adaptor and related information.  Generated
   by either StageSQLToCalc (based on sql_program) or in StageParseM3 *)
let db_schema:Schema.t = Schema.empty_db ();;

(**Calculus representation of the input queries.  Generated by StageSQLToCalc
   Each query is labeled with a string identifier.  Note that a single SQL 
   query may map to multiple calculus queries, since each aggregated column in
   the output must be generated as a separate query (this can be eliminated in
   the future by adding support for tuple values to the calculus) *)
let calc_queries:(string * Calculus.expr_t) list ref = ref [];;

(**The materialization plan.  This is typically an intermediate stage after
   the deltas have been generated, but before the triggers have been gathered
   together into an M3 program. *)
let materialization_plan:(Plan.plan_t ref) = ref [];;

(**Representation of the input queries after compilation/materialization.  This
   is the expression that needs to be evaluated to get the query result (in 
   general, each of these will be a single map access) *)
let toplevel_queries:(string * Calculus.expr_t) list ref = ref [];;

(**An initial representation of the compiled program in the M3 language.  This 
   representaiton is equivalent to materialization_plan, but is organized by 
   trigger rather than by datastructure.  The m3 program also contains the
   db_schema and the toplevel_queries fields above. *)
let m3_program:(M3.prog_t ref) = ref (M3.empty_prog ());;
 
(**Representation of the Domain Maintenance Triggers (DMT). It contains a list 
   of triggers which has the same type as the M3 triggers. For each event it 
   contains a list of expressions which shows the computations which are needed 
   for domain maintenance. In this expressions, the domain of the variables for 
   each map is represented by relation.
*)
let dm_program:(M3DM.prog_t ref) = ref( M3DM.empty_prog () );;

(**The K3 program's representation.  This can either be loaded in directly 
   (via StageParseK3) or will be generated by combining m3_program and 
   dm_program.  It contains db_schema and toplevel_queries, as above, and a
   set of triggers, each of which causes the execution of a k3 expression. 
   The K3 program also includes a list of map patterns.
   *)
let k3_program:(K3.prog_t ref) = ref (Schema.empty_db (), ([],[]),[],[]);;

(**If we're running in interpreter mode, we'll need to compile the query into
   an ocaml-executable form.  This is where that executable ``code'' goes. 
   In addition to the code itself, we keep around the map and patterns from the
   k3 program that generated this so that we can properly initialize the 
   database *)
let interpreter_program:
   (K3.map_t list * Patterns.pattern_map * K3Interpreter.K3CG.code_t) ref = 
      ref ([], [], K3Interpreter.K3CG.const(Constants.CInt(0)));;

(**If we're compiling to an imperative language, we have one final stage before
   producing source code: The imperative stage is a flattening of the K3
   representation of the program.  No optimization happens at this stage, but
   because this transformation is likely to be common to all imperative 
   languages, we use this intermediate stage to make the final target language
   compilers as trivial as possible. *)
let imperative_program:(ImperativeCompiler.Target.imp_prog_t ref)
   = ref (ImperativeCompiler.Target.empty_prog ());;

(* String representation of the source code being produced *)
let source_code:string list ref = ref [];;

(************ SQL Stages ************)

if stage_is_active StageParseSQL then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: ParseSQL");
   try 
      List.iter (fun f ->
         let lexbuff = ParsingExtras.lexbuf_for_file_or_stdin f in
         let sql_parsed_file = Sqlparser.dbtoasterSqlFile Sqllexer.tokenize 
                                                          lexbuff 
         in
         sql_program := Sql.merge_files !sql_program sql_parsed_file
      ) !files
   with 
      | Sql.SQLParseError(msg, pos) ->
         error ~exc:true ("Syntax error: "^msg^" "^(
                          ParsingExtras.format_error_at_position pos))
      | Sql.SqlException("",msg) ->
         error ~exc:true ("Sql Error: "^msg)
      | Sql.SqlException(detail,msg) ->
         error ~exc:true ~detail:(fun () -> detail) ("Sql Error: "^msg)
      | Parsing.Parse_error ->
         error ("Sql Parse Error.  (try using '-d log-parser' to track the "^
                "error)")
      | Sys_error(msg) ->
         error msg
      | Sql.InvalidSql(m,d,s) -> 
         let (msg,detail) = Sql.string_of_invalid_sql(m,d,s) in
         error ~exc:true ~detail:(fun () -> detail) msg
   
)
;;
if stage_is_active StagePrintSQL then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintSQL");
   let (tables, queries) = !sql_program in
      output_endline (
         (ListExtras.string_of_list ~sep:"\n" Sql.string_of_table tables)^
         "\n\n"^
         (ListExtras.string_of_list ~sep:"\n" Sql.string_of_select queries)
      )
)
;;

(************ Calculus Stages ************)
let query_id = ref 0;;

if stage_is_active StageSQLToCalc then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: SQLToCalc");
   let (tables, queries) = !sql_program in
      (* Convert the tables into a more friendly format that we'll use 
         throughout the rest of the program.  (Sql should be able to use this
         format directly.  TODO: Recode Sql to do so) *)
      SqlToCalculus.extract_sql_schema db_schema tables;
      
      (* Then convert the queries into calculus. Most of this code lives in
         calculus/SqlToCalculus, but we still need to iterate over all of the
         queries that we were given, and do some target renaming to ensure that
         each of the root level queries has a unique name. *)
      let rename_query = 
         if (List.length queries > 1) then (fun q -> 
            (* If there's more than 1 query name, then make it unique by
               prepending QUERY_[#]_ to the target name *)
            query_id := !query_id + 1;
            "QUERY_"^(string_of_int !query_id)^"_"^q
         ) else (fun q -> q)
      in
      try 
         calc_queries := List.flatten (List.map 
            (fun q -> List.map 
               (fun (tgt_name, tgt_calc) -> (rename_query tgt_name, tgt_calc)) 
               (SqlToCalculus.calc_of_query tables q))
            queries);         
      with 
         | Sql.SqlException("",msg) ->
            error ~exc:true ("Sql Error: "^msg)
         | Sql.SqlException(detail,msg) ->
            error ~exc:true ~detail:(fun () -> detail) ("Sql Error: "^msg)
         | Sql.InvalidSql(m,d,s) -> 
            let (msg,detail) = Sql.string_of_invalid_sql(m,d,s) in
            error ~exc:true ~detail:(fun () -> detail) msg

)
;;
if stage_is_active StageParseCalc then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: ParseCalculus");
   try 
      List.iter (fun f ->
         let lexbuff = 
            Lexing.from_channel (if f <> "-" then (open_in f) else stdin) 
         in let (db_schema0, calc_queries0) =
               (Calculusparser.statementList Calculuslexer.tokenize lexbuff)
         in db_schema := !db_schema0;
            calc_queries := calc_queries0@(!calc_queries)
      ) !files
   with 
      | Parsing.Parse_error ->
         error ("Calculus Parse Error.  (try using '-d log-parser' " ^ 
                "to track the error)")
      | Sys_error(msg) ->
         error msg
   
)
;;
if stage_is_active StagePrintSchema then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintSchema");
   output_endline (Schema.string_of_schema db_schema)
)
;;
if stage_is_active StagePrintCalc then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintCalc");
   let opt = 
      if Debug.active "PRINT-RAW-CALC" then (fun x -> x)
      else (fun expr -> 
         let schema = Calculus.schema_of_expr expr in
            CalculusTransforms.optimize_expr schema expr)
   in
   try
      output_endline (
         (ListExtras.string_of_list ~sep:"\n" 
            (fun (name, calc) -> name^": \n"^
               (CalculusPrinter.string_of_expr (opt calc)))
            !calc_queries)
      )
   with 
   | Calculus.CalculusException(expr, msg) ->
      bug ~exc:true
          ~detail:(fun () -> CalculusPrinter.string_of_expr expr) 
          msg
   | Functions.InvalidFunctionArguments(msg) ->
      error msg
)
;;
if stage_is_active StageCompileCalc then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: CompileCalc");

   (* Compile things and save the accessor expressions *)
   try 
      let mp, tlq = Compiler.compile ~max_depth:!max_compile_depth 
                                     db_schema
                                     !calc_queries 
      in
         materialization_plan := mp;
         toplevel_queries := tlq
   with
   | Calculus.CalculusException(expr, msg) ->
      bug ~exc:true
          ~detail:(fun () -> CalculusPrinter.string_of_expr expr) 
          msg
   | Calculus.CalcRing.NotAValException(expr) ->
      bug ~exc:true
          ~detail:(fun () -> CalculusPrinter.string_of_expr expr)
          "Not A Value"
   | Failure(msg) ->
      bug ~exc:true
          ~detail:(fun () -> ListExtras.string_of_list ~sep:"\n" 
                                (fun (_,x) -> CalculusPrinter.string_of_expr x)
                                !calc_queries)
          msg
   | Functions.InvalidFunctionArguments(msg) ->
      error msg
)
;;
if Debug.active "TIME-CALCOPT" then (
   CalculusTransforms.dump_timings ()
)
;;
if stage_is_active StagePrintPlan then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintPlan");
   output_endline (Plan.string_of_plan !materialization_plan)
)
;;

(************ M3 Stages ************)
if stage_is_active StagePlanToM3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PlanToM3");
   m3_program := M3.plan_to_m3 db_schema !materialization_plan;
   List.iter (fun (qname,qexpr) ->
      M3.add_query !(m3_program) qname qexpr
   ) !toplevel_queries
)
;;
if stage_is_active StageParseM3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: ParseM3");
   if List.length !files > 1 then
      error "Multiple M3 files not supported yet"
   else 
   let f = List.hd !files in
   let lexbuff = Lexing.from_channel 
      (if f <> "-" then (open_in f) else stdin)
   in 
      try 
         m3_program := 
               Calculusparser.mapProgram Calculuslexer.tokenize lexbuff   
      with
         | Calculus.CalculusException(expr, msg) ->
            error ~exc:true
                  ~detail:(fun () -> CalculusPrinter.string_of_expr expr) 
                  msg)
;;
if stage_is_active StageM3ToDistM3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: M3ToDistM3");
   
   m3_program := DistributedM3.distributed_m3_of_m3 !m3_program
)
;;
if stage_is_active StageM3ToAnnotM3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: M3ToAnnotM3");
   
   let create_hashtbl pairs =
      let hashtbl = Hashtbl.create (List.length pairs) in
      List.iter (fun (k, v) -> Hashtbl.add hashtbl k v) pairs;
      hashtbl
   in

   let tpch1_part_table = 
      create_hashtbl [
         ("SUM_QTY",                          None);
         ("SUM_QTYLINEITEM1_DELTA",           None);
         ("SUM_BASE_PRICE",                   None);
         ("SUM_BASE_PRICELINEITEM1_DELTA",    None);
         ("SUM_DISC_PRICE",                   None);
         ("SUM_DISC_PRICELINEITEM1_DELTA",    None);
         ("SUM_CHARGE",                       None);
         ("SUM_CHARGELINEITEM1_DELTA",        None);
         ("AVG_QTY",                          None);
         ("AVG_QTYLINEITEM1_DOMAIN1_1_DELTA", None);
         ("AVG_QTYLINEITEM1",                 None);
         ("AVG_QTYLINEITEM1_L1_1",            None);
         ("AVG_PRICE",                        None);
         ("AVG_PRICELINEITEM1",               None);
         ("AVG_DISC",                         None);
         ("AVG_DISCLINEITEM1",                None);
         ("AVG_DISCLINEITEM4_DELTA",          None);
         ("COUNT_ORDER",                      None)
      ]
   in
   let tpch2_part_table = 
      create_hashtbl [ 
         ("COUNT",                              Some([3]));  (* PK *)
         ("COUNTPARTSUPP1_DOMAIN1_1_DELTA",     Some([0]));  (* PK *)
         ("COUNTPARTSUPP1_P_1",                 Some([0]));  (* PK *)
         ("COUNTPARTSUPP1_L2_2_DELTA",          Some([0]));  (* PK *) (* 1:SK *)
         ("COUNTPARTSUPP1_L2_2",                Some([0]));  (* SK *)
         ("COUNTPARTSUPP1_L2_2SUPPLIER1_DELTA", Some([0]));  (* SK *) 
         ("COUNTPARTSUPP1_L2_2SUPPLIER1",       Some([]));   (* N,R *)
         ("COUNTPARTSUPP4_P_2",                 Some([0]));  (* SK *)
         ("COUNTPARTSUPP4_P_2SUPPLIER1_DELTA",  Some([0]));  (* SK *)
         ("COUNTPARTSUPP4_P_2SUPPLIER1",        Some([]));   (* N,R *)
         ("COUNTSUPPLIER1",                     Some([0]));  (* PK *)
         ("COUNTSUPPLIER1SUPPLIER1_P_1",        Some([0]));  (* PK *) (* 2:SK *)
         ("COUNTSUPPLIER1SUPPLIER1_P_1PART1",   Some([0]));  (* PK *) (* 1:SK *)
         ("COUNTPART1_DELTA",                   Some([0]));  (* PK *)
         ("COUNTPART1",                         Some([5]));  (* PK *)
         ("COUNTPART1_L2_1",                    Some([0]));  (* PK *)
      ]
   in 
   let tpch3_part_table = 
      create_hashtbl [ 
         ("QUERY3",                   Some([0])); 
         ("QUERY3LINEITEM1_DELTA",    Some([0]));
         ("QUERY3LINEITEM1",          Some([0]));
         ("QUERY3LINEITEM1CUSTOMER1", Some([0]));
         ("QUERY3ORDERS1_DELTA",      Some([0]));
         ("QUERY3ORDERS1_P_1",        Some([0]));    (* CK *)
         ("QUERY3ORDERS1_P_2",        Some([0]));
         ("QUERY3CUSTOMER1_DELTA",    Some([0]));
         ("QUERY3CUSTOMER1",          Some([0]))     (* CK *) 
      ]
   in
   let tpch4_part_table = 
      create_hashtbl [
         ("ORDER_COUNT",                               None);
         ("ORDER_COUNTLINEITEM1_DOMAIN1_1_DELTA", Some([0]));  (* OK *)
         ("ORDER_COUNTLINEITEM1",                 Some([0]));  (* OK *)
         ("ORDER_COUNTORDERS1_DELTA",             Some([0]));  (* OK *)
         ("ORDER_COUNTORDERS1_E1_1",              Some([0]));  (* OK *)
      ]
   in
   let tpch5_part_table = 
      create_hashtbl [
         ("REVENUE",                                     None);
         ("REVENUESUPPLIER1_DELTA",                 Some([0])); (* SK *)
         ("REVENUESUPPLIER1_P_2",                   Some([1])); (* SK *)
         ("REVENUESUPPLIER1_P_2LINEITEM1",          Some([1])); (* OK *)
         ("REVENUESUPPLIER1_P_2LINEITEM1CUSTOMER1", Some([0])); (* OK *)
         ("REVENUESUPPLIER1_P_2ORDERS1_P_1",        Some([0])); (* CK *)
         ("REVENUESUPPLIER1_P_2ORDERS1_P_2",        Some([0])); (* OK *)
         ("REVENUESUPPLIER1_P_2CUSTOMER1",          Some([1])); (* SK *)
         ("REVENUELINEITEM1_DELTA",                 Some([0])); (* OK *)
         ("REVENUELINEITEM1",                       Some([0])); (* OK *)
         ("REVENUELINEITEM1ORDERS1",                Some([0])); (* CK *)
         ("REVENUELINEITEM1CUSTOMER1_P_3",          Some([0])); (* SK *)
         ("REVENUEORDERS1_DELTA",                   Some([0])); (* OK *)
         ("REVENUEORDERS1",                         Some([1])); (* OK *)
         ("REVENUEORDERS1CUSTOMER1_P_2",            Some([0])); (* OK *)
         ("REVENUECUSTOMER1_DELTA",                 Some([0])); (* CK *)
         ("REVENUECUSTOMER1_P_1",                   Some([]));  (* ** *)
         ("REVENUECUSTOMER1_P_2",                   Some([0])); (* CK *)

      ]
   in
   let tpch6_part_table = 
      create_hashtbl [ 
         ("REVENUE",                None); 
         ("REVENUELINEITEM1_DELTA", None)
      ]
   in
   let tpch7_part_table = 
      create_hashtbl [ 
         ("REVENUE",                              None); 
         ("REVENUECUSTOMER1_DELTA",               Some([0])); (* CK *)
         ("REVENUECUSTOMER1",                     Some([0])); (* CK *) 
         ("REVENUECUSTOMER1ORDERS1",              Some([0])); (* OK *)
         ("REVENUECUSTOMER1ORDERS1SUPPLIER1_P_1", Some([0])); (* OK *)
         ("REVENUECUSTOMER1LINEITEM1_P_1",        Some([0])); (* SK *) 
         ("REVENUECUSTOMER1LINEITEM1_P_2",        Some([0])); (* OK *)
         ("REVENUECUSTOMER1SUPPLIER1_P_1",        Some([1])); (* CK *)
         ("REVENUECUSTOMER1SUPPLIER1_P_2",        Some([]));  (* ** *)
         ("REVENUEORDERS1_DELTA",                 Some([0])); (* OK*)
         ("REVENUEORDERS1",                       Some([0])); (* OK *)
         ("REVENUEORDERS1LINEITEM1",              Some([1])); (* CK *) (* 0:SK *)
         ("REVENUEORDERS1SUPPLIER1_P_2",          Some([0])); (* CK *)
         ("REVENUELINEITEM1_DOMAIN1_1_DELTA",     Some([]));  (* ** *)
         ("REVENUELINEITEM1_DELTA",               Some([0])); (* OK *)
         ("REVENUELINEITEM1",                     Some([1])); (* OK *)
         ("REVENUELINEITEM1SUPPLIER1",            Some([0])); (* OK *)
         ("REVENUESUPPLIER1_DELTA",               Some([0])); (* SK *)
         ("REVENUESUPPLIER1",                     Some([0])); (* SK *)
      ]
   in
   let tpch8_part_table = 
      create_hashtbl [ 
         ("MKT_SHARE",                                       None); 
         ("MKT_SHAREORDERS1_DOMAIN1_1_DELTA",                None);  
         ("MKT_SHAREORDERS1",                                None);
         ("MKT_SHAREORDERS1CUSTOMER1_DELTA",             Some([0])); (* CK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_1",               Some([]));  (* ** *) 
         ("MKT_SHAREORDERS1CUSTOMER1_P_2",               Some([0])); (* CK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_2LINEITEM1_P_3",  Some([0])); (* OK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_2SUPPLIER1_P_2",  Some([1])); (* CK *) (* 0:SK *) 
         ("MKT_SHAREORDERS1CUSTOMER1_P_2SUPPLIER1_P_2ORDERS1",      Some([0])); (* OK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_2SUPPLIER1_P_2ORDERS1PART1", Some([0])); (* OK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_2SUPPLIER1_P_2PART1",        Some([2])); (* CK *)  (* 0:PK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_2PART1",          Some([1])); (* CK *) (* 0:PK *)
         ("MKT_SHAREORDERS1CUSTOMER1_P_2PART1ORDERS1",   Some([0])); (* OK *)
         ("MKT_SHAREORDERS1LINEITEM1_DELTA",             Some([0])); (* OK *)
         ("MKT_SHAREORDERS1LINEITEM1_P_1",               Some([0])); (* OK *)
         ("MKT_SHAREORDERS1LINEITEM1_P_2",               Some([0])); (* PK *)
         ("MKT_SHAREORDERS1LINEITEM1_P_3",               Some([0])); (* SK *)
         ("MKT_SHAREORDERS1SUPPLIER1_DELTA",             Some([0])); (* SK *)
         ("MKT_SHAREORDERS1SUPPLIER1_P_1",               Some([0])); (* SK *)
         ("MKT_SHAREORDERS1SUPPLIER1_P_1PART1",          Some([0])); (* PK *)
         ("MKT_SHAREORDERS1SUPPLIER1_P_2",               Some([]));  (* ** *)
         ("MKT_SHAREORDERS1PART1_DELTA",                 Some([0])); (* PK *)
         ("MKT_SHAREORDERS1PART1",                       Some([0])); (* PK *)
         ("MKT_SHAREORDERS1_L1_1_L1_2_DELTA",            Some([0])); (* OK *)
         ("MKT_SHAREORDERS1_L1_1_L1_2_P_1",              Some([0])); (* OK *)
         ("MKT_SHAREORDERS1_L1_1_L1_2_P_1LINEITEM1_P_2", Some([0])); (* SK *)
         ("MKT_SHAREORDERS1_L1_1_L1_2_P_1SUPPLIER1_P_2", Some([])); 
         ("MKT_SHAREORDERS1_L1_1_L1_2_P_1PART1",         Some([0])); (* OK *)
         ("MKT_SHAREORDERS1_L1_1_L1_2_P_2",              Some([0])); (* CK *)
         ("MKT_SHAREORDERS4_DELTA",                      Some([0])); (* OK *)
         ("MKT_SHAREORDERS4_P_2",                        Some([0])); (* OK *)
         ("MKT_SHAREPART1",                                   None);
         ("MKT_SHAREPART1CUSTOMER1_P_2",                 Some([0])); (* CK *)
         ("MKT_SHAREPART1CUSTOMER1_P_2LINEITEM1_P_3",    Some([0])); (* OK *)
         ("MKT_SHAREPART1CUSTOMER1_P_2SUPPLIER1_P_2",    Some([1])); (* CK *)
         ("MKT_SHAREPART1CUSTOMER1_P_2SUPPLIER1_P_2PART1", Some([2])); (* CK *) (* 0:PK *)
         ("MKT_SHAREPART1CUSTOMER1_P_2PART1",            Some([1])); (* CK *) (* 0:PK *)
         ("MKT_SHAREPART1LINEITEM1_P_1",                 Some([0])); (* OK *)
         ("MKT_SHAREPART1SUPPLIER1_P_1",                 Some([0])); (* SK *)
         ("MKT_SHAREPART1SUPPLIER1_P_1PART1",            Some([0])); (* PK *)
         ("MKT_SHAREPART1PART1",                         Some([0])); (* PK *)
         ("MKT_SHAREPART1_L2_1_L1_1",                         None); 
         ("MKT_SHAREPART1_L2_1_L1_1CUSTOMER1_P_2",       Some([0])); (* CK *)
         ("MKT_SHAREPART1_L2_1_L1_1CUSTOMER1_P_2PART1",  Some([1])); (* CK *) (* 0:PK *)
         ("MKT_SHAREPART1_L2_1_L1_1PART1",               Some([0])); (* PK *)
      ]
   in
   let tpch9_part_table = 
      create_hashtbl [ 
         ("SUM_PROFIT",                           None); 
         ("SUM_PROFITORDERS11_DOMAIN1_1_DELTA",   None); 
         ("SUM_PROFITORDERS11_DELTA",             Some([0])); (* OK *)
         ("SUM_PROFITORDERS11",                   Some([0])); (* OK *)
         ("SUM_PROFITORDERS11PARTSUPP1_P_3",      Some([0])); (* OK *)
         ("SUM_PROFITORDERS11SUPPLIER1_P_1",      Some([0])); (* OK *)
         ("SUM_PROFITORDERS11SUPPLIER1_P_1PART1", Some([0])); (* OK *)
         ("SUM_PROFITORDERS11PART1",              Some([0])); (* OK *)
         ("SUM_PROFITORDERS13",                   Some([0])); (* OK *)
         ("SUM_PROFITORDERS13PARTSUPP1_P_3",      Some([0])); (* OK *)
         ("SUM_PROFITORDERS13SUPPLIER1_P_1",      Some([0])); (* OK *)
         ("SUM_PROFITORDERS13SUPPLIER1_P_1PART1", Some([0])); (* OK *)
         ("SUM_PROFITORDERS13PART1",              Some([0])); (* OK *) 
         ("SUM_PROFITPARTSUPP11_DELTA",           Some([0])); (* PK *)
         ("SUM_PROFITPARTSUPP11_P_3",             Some([0])); (* PK *)
         ("SUM_PROFITPARTSUPP13_DELTA",           Some([0])); (* PK *)
         ("SUM_PROFITPARTSUPP13_P_3",             Some([0])); (* PK *)
         ("SUM_PROFITLINEITEM11_DELTA",           Some([0])); (* OK *)
         ("SUM_PROFITLINEITEM11_P_1",             Some([0])); (* PK *)
         ("SUM_PROFITLINEITEM11_P_2",             Some([0])); (* SK *)
         ("SUM_PROFITLINEITEM11_P_3",             Some([0])); (* PK *)
         ("SUM_PROFITLINEITEM11_P_4",             Some([0])); (* OK *)
         ("SUM_PROFITLINEITEM13_DELTA",           Some([0])); (* OK *)
         ("SUM_PROFITLINEITEM13_P_3",             Some([0])); (* PK *)
         ("SUM_PROFITSUPPLIER11_DELTA",           Some([0])); (* SK *)
         ("SUM_PROFITSUPPLIER11_P_1",             Some([0])); (* SK *)
         ("SUM_PROFITSUPPLIER11_P_1PART1",        Some([0])); (* PK *)
         ("SUM_PROFITSUPPLIER11_P_2",             Some([]));  (* ** *)
         ("SUM_PROFITSUPPLIER13_P_1",             Some([0])); (* SK *)
         ("SUM_PROFITSUPPLIER13_P_1PART1",        Some([0])); (* PK *)
         ("SUM_PROFITPART11_DELTA",               Some([0])); (* PK *)
         ("SUM_PROFITPART11",                     Some([0])); (* PK *)
         ("SUM_PROFITPART13",                     Some([0])); (* PK *)
      ]
   in
   let tpch10_part_table = 
      create_hashtbl [ 
         ("REVENUE",                       Some([0])); (* CK *)
         ("REVENUELINEITEM1_DELTA",        Some([0])); (* OK *)
         ("REVENUELINEITEM1",              Some([6])); (* OK *)
         ("REVENUELINEITEM1CUSTOMER1_P_1", Some([0])); (* OK *)
         ("REVENUEORDERS1_DELTA",          Some([0])); (* OK *)
         ("REVENUEORDERS1_P_1",            Some([0])); (* OK *)
         ("REVENUEORDERS1_P_2",            Some([0])); (* CK *)
         ("REVENUECUSTOMER1_DELTA",        Some([0])); (* CK *)
         ("REVENUECUSTOMER1_P_1",          Some([0])); (* CK *)
         ("REVENUECUSTOMER1_P_2",          Some([]));  (* ** *)
      ]
   in
   let tpch11_part_table = 
      create_hashtbl [ 
         ("QUERY11",                              Some([0])); (* PK *)
         ("QUERY11PARTSUPP1_L1_1",                     None);
         ("QUERY11PARTSUPP1_L1_1SUPPLIER1_DELTA", Some([0])); (* SK *)
         ("QUERY11PARTSUPP1_L1_1SUPPLIER1_P_1",   Some([]));  (* ** *)
         ("QUERY11PARTSUPP1_L1_1SUPPLIER1_P_2",   Some([0])); (* SK *)
         ("QUERY11PARTSUPP1_L1_1PARTSUPP1_DELTA", Some([0])); (* SK *)
         ("QUERY11PARTSUPP1_L1_1PARTSUPP1",       Some([0])); (* SK *)
         ("QUERY11PARTSUPP1_E2_1",                Some([0])); (* PK *)
         ("QUERY11PARTSUPP1_E2_1SUPPLIER1_P_2",   Some([1])); (* PK *) (* 0:SK *)
         ("QUERY11PARTSUPP1_E2_1PARTSUPP1_DELTA", Some([1])); (* PK *) (* 0:SK *)
         ("QUERY11PARTSUPP1_L3_1",                Some([0])); (* PK *) 
         ("QUERY11PARTSUPP1_L3_1SUPPLIER1_P_2",   Some([1])); (* PK *) (* 0:SK *)
         ("QUERY11PARTSUPP1_L3_1PARTSUPP1_DELTA", Some([1])); (* PK *) (* 0:SK *)
      ]
   in
   let tpch12_part_table = 
      create_hashtbl [ 
         ("HIGH_LINE_COUNT",                     None); 
         ("HIGH_LINE_COUNTLINEITEM1_DELTA", Some([0]));     (* OK *) 
         ("HIGH_LINE_COUNTLINEITEM1",       Some([0]));     (* OK *)
         ("HIGH_LINE_COUNTLINEITEM2_DELTA", Some([0]));     (* OK *) 
         ("HIGH_LINE_COUNTLINEITEM3",       Some([0]));     (* OK *)
         ("HIGH_LINE_COUNTORDERS1_DELTA",   Some([0]));     (* OK *)
         ("HIGH_LINE_COUNTORDERS1",         Some([0]));     (* OK *) 
         ("HIGH_LINE_COUNTORDERS2",         Some([0]));     (* OK *) 
         ("HIGH_LINE_COUNTORDERS3_DELTA",   Some([0]));     (* OK *) 
         ("LOW_LINE_COUNT",                      None);
         ("LOW_LINE_COUNTLINEITEM1",        Some([0]));     (* OK *)
         ("LOW_LINE_COUNTORDERS1_DELTA",    Some([0]));     (* OK *) 
      ]
   in
   let tpch13_part_table =   (* There is a problem in the frontend that generates two CKs *)
      create_hashtbl [ 
         ("CUSTDIST",                                 None); 
         ("CUSTDISTORDERS1_DOMAIN1_1_DELTA",     Some([0])); (* CK *)
         ("CUSTDISTORDERS3_L1_2_DELTA",          Some([0])); (* CK *)
         ("CUSTDISTORDERS3_L1_2",                Some([0])); (* CK *)
         ("CUSTDISTORDERS3_L1_2CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("CUSTDISTCUSTOMER1_DOMAIN1_1_DELTA",   Some([0])); (* CK *)
         ("CUSTDISTCUSTOMER1_L1_1",              Some([0])); (* CK *)
         ("CUSTDISTCUSTOMER3_L1_2_DELTA",        Some([0])); (* CK *)
         ("CUSTDISTCUSTOMER3_L1_2",              Some([0])); (* CK *)
         ("CUSTDISTCUSTOMER3_L1_2ORDERS1_DELTA", Some([0])); (* CK *)
      ]
   in
   let tpch14_part_table = 
      create_hashtbl [ 
         ("PROMO_REVENUE",                                   None); 
         ("PROMO_REVENUELINEITEM1_L1_1_L1_1",                None);
         ("PROMO_REVENUELINEITEM1_L1_1_L1_1PART1_DELTA",     Some([0])); (* PK *)
         ("PROMO_REVENUELINEITEM1_L1_1_L1_1PART1",           Some([0])); (* PK *)
         ("PROMO_REVENUELINEITEM1_L1_1_L1_1LINEITEM1_DELTA", Some([0])); (* PK *)
         ("PROMO_REVENUELINEITEM1_L1_1_L1_1LINEITEM1",       Some([0])); (* PK *)
         ("PROMO_REVENUELINEITEM2",                          None); 
         ("PROMO_REVENUELINEITEM2PART1_DELTA",               Some([0])); (* PK *)
         ("PROMO_REVENUELINEITEM2LINEITEM1",                 Some([0])); (* PK *)
      ]
   in
   let tpch15_part_table = 
      create_hashtbl [ 
         ("COUNT",                                   Some([0])); (* SK *)
         ("COUNTSUPPLIER1_DELTA",                    Some([0])); (* SK *)
         ("COUNTLINEITEM1",                          Some([0])); (* SK *)
         ("COUNTLINEITEM1_E2_1",                     Some([0])); (* SK *)
         ("COUNTLINEITEM1_E2_1LINEITEM1_DELTA",      Some([0])); (* SK *) 
         ("COUNTLINEITEM1_L3_1",                     Some([0])); (* SK *)
         ("COUNTLINEITEM1_L3_1LINEITEM1_DELTA",      Some([0])); (* SK *)
         ("COUNTLINEITEM1_L4_1_E1_1",                Some([0])); (* SK *)
         ("COUNTLINEITEM1_L4_1_E1_1LINEITEM1_DELTA", Some([0])); (* SK *)
         ("COUNTLINEITEM1_L4_1_L2_1",                Some([0])); (* SK *)
         ("COUNTLINEITEM1_L4_1_L2_1LINEITEM1_DELTA", Some([0])); (* SK *)
      ]
   in
   let tpch16_part_table = 
      create_hashtbl [ 
         ("SUPPLIER_CNT",                                None); 
         ("SUPPLIER_CNTSUPPLIER1_DOMAIN1_1_DELTA",  Some([0])); (* SK *)
         ("SUPPLIER_CNTPART1_DOMAIN1_1_DELTA",           None); 
         ("SUPPLIER_CNTPART1_E1_1",                 Some([0])); (* SK *)
         ("SUPPLIER_CNTPART1_E1_1PARTSUPP1",        Some([0])); (* PK *)
         ("SUPPLIER_CNTPART1_E1_33_DELTA",          Some([0])); (* PK *)
         ("SUPPLIER_CNTPART1_E1_33",                Some([0])); (* PK *) (* 1:SK *)
         ("SUPPLIER_CNTPARTSUPP1_DOMAIN1_1_DELTA",  Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_1_L2_1",        Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_2",             Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_2PART1_DELTA",  Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_4",             Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_4PART1_DELTA",  Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_6",             Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_6PART1_DELTA",  Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_8",             Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_8PART1_DELTA",  Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_10",            Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_10PART1_DELTA", Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_12",            Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_12PART1_DELTA", Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_14",            Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_14PART1_DELTA", Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_16",            Some([0])); (* SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_16PART1_DELTA", Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_18_DELTA",      Some([0])); (* PK *) (* 1:SK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_18",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_20",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_22",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_24",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_26",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_28",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_30",            Some([0])); (* PK *)
         ("SUPPLIER_CNTPARTSUPP1_E1_32",            Some([0])); (* PK *)
      ]
   in
   let tpch17_part_table = 
      create_hashtbl [ 
         ("AVG_YEARLY",                               None); 
         ("AVG_YEARLYPART1_DELTA",               Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_DOMAIN1_3_DELTA", Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_P_3",             Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_P_3PART1_DELTA",  Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_P_4",             Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_L1_1_L1_1",       Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_L1_2",            Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM1_L1_4_DELTA",      Some([0])); (* PK *)
         ("AVG_YEARLYLINEITEM5_DELTA",           Some([0])); (* PK *)
      ]
   in
   let tpch17a_part_table = 
      create_hashtbl [ 
         ("QUERY17",                               None); 
         ("QUERY17PART1_DELTA",               Some([0])); (* PK *)
         ("QUERY17LINEITEM1_DOMAIN1_1_DELTA", Some([0])); (* PK *)
         ("QUERY17LINEITEM1_P_1",             Some([0])); (* PK *)
         ("QUERY17LINEITEM1_P_2",             Some([0])); (* PK *)
         ("QUERY17LINEITEM1_L1_1",            Some([0])); (* PK *)
         ("QUERY17LINEITEM1_L1_3_DELTA",      Some([0])); (* PK *)
         ("QUERY17LINEITEM2_DELTA",           Some([0])); (* PK *)
      ]
   in   
   let tpch18_part_table = 
      create_hashtbl [ 
         ("QUERY18",                          Some([2])); (* OK *) (* 1:CK *)
         ("QUERY18LINEITEM1_DOMAIN1_1_DELTA", Some([0])); (* OK *)
         ("QUERY18LINEITEM1_P_1",             Some([2])); (* OK *) (* 1:CK *)
         ("QUERY18LINEITEM1_P_1CUSTOMER1",    Some([0])); (* OK *) (* 1:CK *)
         ("QUERY18LINEITEM1_L1_2_DELTA",      Some([0])); (* OK *)
         ("QUERY18ORDERS1_DELTA",             Some([0])); (* OK *) (* 1:CK *)
         ("QUERY18ORDERS1_P_1",               Some([0])); (* CK *)
         ("QUERY18CUSTOMER1_DELTA",           Some([0])); (* CK *)
         ("QUERY18CUSTOMER1",                 Some([0])); (* OK *) (* 1:CK *)
         ("QUERY18CUSTOMER1_L1_1",            Some([0])); (* OK *)
      ]
   in
   let tpch19_part_table = 
      create_hashtbl [ 
         ("REVENUE",                     None); 
         ("REVENUEPART1_DELTA",     Some([0])); (* PK *)
         ("REVENUEPART1",           Some([0])); (* PK *)
         ("REVENUELINEITEM1_DELTA", Some([0])); (* PK *)
         ("REVENUELINEITEM1",       Some([0])); (* PK *)
      ]
   in
   let tpch20_part_table = 
      create_hashtbl [ 
         ("COUNT",                                    None); (* Alternative: 0:S_NAME   1:S_ADDRESS *) 
         ("COUNTPART1",                          Some([0])); (* SK *)
         ("COUNTLINEITEM1_DOMAIN1_2_DELTA",      Some([0])); (* SK *)
         ("COUNTLINEITEM1_E1_1_L1_3_DELTA",      Some([0])); (* PK *) (* 1:SK *)
         ("COUNTPARTSUPP1_DOMAIN1_2_DELTA",      Some([0])); (* SK *)
         ("COUNTPARTSUPP1_P_2",                  Some([0])); (* SK *)
         ("COUNTPARTSUPP1_P_2SUPPLIER1",         Some([])); (* ** *)
         ("COUNTPARTSUPP1_E1_2_DELTA",           Some([0])); (* PK *) (* 1: SK *)
         ("COUNTSUPPLIER1_DELTA",                Some([0])); (* SK *)
         ("COUNTSUPPLIER1",                      Some([])); (* ** *)
         ("COUNTSUPPLIER1_E1_1",                 Some([0])); (* PK *) (* 1:SK *)
         ("COUNTSUPPLIER1_E1_1_L1_1",            Some([0])); (* PK *) (* 1:SK *)
         ("COUNTSUPPLIER1_E1_1_E2_1",            Some([0])); (* PK *)
         ("COUNTSUPPLIER1_E1_1_E2_1PART1_DELTA", Some([0])); (* PK *)
      ]
   in
   let tpch21_part_table = 
      create_hashtbl [ 
         ("NUMWAIT",                                None); (* Alternative: 0:S_NAME *)
         ("NUMWAITORDERS1_DELTA",              Some([0])); (* OK *)
         ("NUMWAITORDERS1",                    Some([2])); (* OK *) (* 0:SK *)
         ("NUMWAITORDERS1LINEITEM1",           Some([0])); (* SK *)
         ("NUMWAITLINEITEM1_DOMAIN1_3_DELTA",  Some([0])); (* OK *)
         ("NUMWAITLINEITEM1_P_3",              Some([2])); (* OK *) (* 0:SK *)
         ("NUMWAITLINEITEM1_P_3SUPPLIER1_P_2", Some([]));  (* ** *)
         ("NUMWAITLINEITEM1_P_4",              Some([0])); (* OK *)
         ("NUMWAITLINEITEM1_P_4ORDERS1_DELTA", Some([0])); (* OK *)
         ("NUMWAITLINEITEM1_E3_2_DELTA",       Some([0])); (* OK *) (* 1:SK *)
         ("NUMWAITLINEITEM4_DOMAIN2_1_DELTA",  Some([0])); (* OK *) 
         ("NUMWAITLINEITEM4_L2_2_DELTA",       Some([0])); (* OK *) (* 1:SK *)
         ("NUMWAITLINEITEM7_P_3",              Some([0])); (* SK *) 
         ("NUMWAITLINEITEM11_DOMAIN3_1_DELTA", Some([0])); (* OK *) (* 0:PK 1:SK *)
         ("NUMWAITSUPPLIER1_DELTA",            Some([0])); (* SK *)
         ("NUMWAITSUPPLIER1_P_1",              Some([]));  (* ** *)
         ("NUMWAITSUPPLIER1_P_2",              Some([0])); (* OK *) (* 1:SK *)
         ("NUMWAITSUPPLIER1_P_2LINEITEM1",     Some([0])); (* OK *)
         ("NUMWAITSUPPLIER1_L2_1",             Some([0])); (* OK *) (* 1:SK *)
         ("NUMWAITSUPPLIER1_E3_1",             Some([0])); (* OK *) (* 1:SK *)
      ]
   in
   let tpch22_part_table = 
      create_hashtbl [ 
         ("NUMCUST",                                   None); 
         ("NUMCUSTORDERS1_DOMAIN1_1_DELTA",       Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER1",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER1CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER1_L2_1_L1_1",                None); 
         ("NUMCUSTCUSTOMER1_L2_1_L1_1CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_2",                None); 
         ("NUMCUSTCUSTOMER1_L2_1_L1_2CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_3",                None); 
         ("NUMCUSTCUSTOMER1_L2_1_L1_3CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_4",                None); 
         ("NUMCUSTCUSTOMER1_L2_1_L1_4CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_5",                None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_5CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_6",                None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_6CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_7",                None);
         ("NUMCUSTCUSTOMER1_L2_1_L1_7CUSTOMER1_DELTA", None);
         ("NUMCUSTCUSTOMER1_L2_2",                     None);
         ("NUMCUSTCUSTOMER1_L2_2CUSTOMER1_DELTA",      None);
         ("NUMCUSTCUSTOMER1_L2_4",                     None);
         ("NUMCUSTCUSTOMER1_L2_4CUSTOMER1_DELTA",      None);
         ("NUMCUSTCUSTOMER1_L2_6",                     None);
         ("NUMCUSTCUSTOMER1_L2_6CUSTOMER1_DELTA",      None);
         ("NUMCUSTCUSTOMER1_L2_8",                     None);
         ("NUMCUSTCUSTOMER1_L2_8CUSTOMER1_DELTA",      None);
         ("NUMCUSTCUSTOMER1_L2_10",                    None);
         ("NUMCUSTCUSTOMER1_L2_10CUSTOMER1_DELTA",     None);
         ("NUMCUSTCUSTOMER1_L2_12",                    None);
         ("NUMCUSTCUSTOMER1_L2_12CUSTOMER1_DELTA",     None);
         ("NUMCUSTCUSTOMER1_L2_14",                    None);
         ("NUMCUSTCUSTOMER1_L2_14CUSTOMER1_DELTA",     None);
         ("NUMCUSTCUSTOMER1_L3_1",                Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER2",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER2CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER3",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER3CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER4",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER4CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER5",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER5CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER6",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER6CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER7",                     Some([0])); (* CK *)
         ("NUMCUSTCUSTOMER7CUSTOMER1_DELTA",      Some([0])); (* CK *)
         ("TOTALACCTBAL",                              None);
         ("TOTALACCTBALCUSTOMER1",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER1CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER2",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER2CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER3",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER3CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER4",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER4CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER5",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER5CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER6",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER6CUSTOMER1_DELTA", Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER7",                Some([0])); (* CK *)
         ("TOTALACCTBALCUSTOMER7CUSTOMER1_DELTA", Some([0])); (* CK *)
      ]
   in
   let ssb4_part_table = 
      create_hashtbl [ 
         ("SSB4",                                              None); 
         ("SSB4SUPPLIER1_DELTA",                          Some([0])); (* SK *)
         ("SSB4SUPPLIER1_P_1",                            Some([0])); (* SK *)  
         ("SSB4SUPPLIER1_P_1PART1",                       Some([0])); (* PK *)  (* SK *)
         ("SSB4SUPPLIER1_P_1PART1ORDERS1_P_2",            Some([0])); (* OK *)  
         ("SSB4SUPPLIER1_P_1PART1CUSTOMER1_P_1",          Some([0])); (* CK *) (* 1:PK 2:SK *)  
         ("SSB4SUPPLIER1_P_1PART1CUSTOMER1_P_1LINEITEM1", Some([0])); (* OK *)  
         ("SSB4SUPPLIER1_P_1ORDERS1_P_2",                 Some([0])); (* OK *)  
         ("SSB4SUPPLIER1_P_1CUSTOMER1_P_1",               Some([0])); (* CK *) (* SK *)
         ("SSB4PART1_DELTA",                              Some([0])); (* PK *)  
         ("SSB4PART1",                                    Some([0])); (* PK *)  
         ("SSB4PART1ORDERS1_P_2",                         Some([0])); (* OK *)  
         ("SSB4PART1CUSTOMER1_P_1",                       Some([0])); (* CK *) (* 1:PK *)
         ("SSB4LINEITEM1_DELTA",                          Some([0])); (* OK *)  
         ("SSB4LINEITEM1_P_1",                            Some([0])); (* OK *)  
         ("SSB4LINEITEM1_P_2",                            Some([0])); (* PK *)  
         ("SSB4LINEITEM1_P_3",                            Some([0])); (* SK *)  
         ("SSB4ORDERS1_DELTA",                            Some([0])); (* OK *)  
         ("SSB4ORDERS1_P_1",                              Some([0])); (* CK *)  
         ("SSB4ORDERS1_P_2",                              Some([0])); (* OK *)  
         ("SSB4CUSTOMER1_DELTA",                          Some([0])); (* CK *)  
         ("SSB4CUSTOMER1_P_1",                            Some([0])); (* CK *)  
         ("SSB4CUSTOMER1_P_2",                            Some([])); (* ** *)  
      ]
   in
   let part_table_context =
      create_hashtbl [
         ("test/queries/tpch/query1.sql", tpch1_part_table);
         ("test/queries/tpch/query2.sql", tpch2_part_table);
         ("test/queries/tpch/query3.sql", tpch3_part_table);
         ("test/queries/tpch/query4.sql", tpch4_part_table);
         ("test/queries/tpch/query5.sql", tpch5_part_table);
         ("test/queries/tpch/query6.sql", tpch6_part_table);
         ("test/queries/tpch/query7.sql", tpch7_part_table);
         ("test/queries/tpch/query8.sql", tpch8_part_table);
         ("test/queries/tpch/query9.sql", tpch9_part_table);
         ("test/queries/tpch/query10.sql", tpch10_part_table);
         ("test/queries/tpch/query11.sql", tpch11_part_table);
         ("test/queries/tpch/query12.sql", tpch12_part_table);
         ("test/queries/tpch/query13.sql", tpch13_part_table);
         ("test/queries/tpch/query14.sql", tpch14_part_table);
         ("test/queries/tpch/query15.sql", tpch15_part_table);
         ("test/queries/tpch/query16.sql", tpch16_part_table);
         ("test/queries/tpch/query17.sql", tpch17_part_table);
         ("test/queries/tpch/query17a.sql", tpch17a_part_table);
         ("test/queries/tpch/query18.sql", tpch18_part_table);
         ("test/queries/tpch/query19.sql", tpch19_part_table);
         ("test/queries/tpch/query20.sql", tpch20_part_table);
         ("test/queries/tpch/query21.sql", tpch21_part_table);
         ("test/queries/tpch/query22.sql", tpch22_part_table);
         ("test/queries/tpch/ssb4.sql", ssb4_part_table);         
      ]
   in
                                 
   let part_table = 
      try Hashtbl.find part_table_context (List.hd !files) 
      with Not_found -> create_hashtbl []
   in

   Debug.activate("PRINT-ANNOTATED-M3");

   let annotated_m3_program = 
      AnnotatedM3.lift_prog part_table (!m3_program) 
   in
      output_endline (
         AnnotatedM3.string_of_prog part_table annotated_m3_program)
)
;;
if stage_is_active StagePrintM3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintM3");
   output_endline (M3.string_of_m3 !m3_program)
)
;;

(************ M3 Domain Maintenance Stages ************)
if stage_is_active StageM3DomainMaintenance then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: M3DomainMaintenance");
   dm_program := M3DM.m3_to_m3dm (!m3_program);
)
;;
if stage_is_active StagePrintM3DomainMaintenance then (
   Debug.print "LOG-DRIVER" 
               (fun () -> "Running Stage: PrintM3DomainMaintenance");
   output_endline (M3DM.string_of_m3DM !dm_program)
)
;;

(************ K3 Stages ************)

if stage_is_active StageM3ToK3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: M3ToK3");
   if not (Debug.active "DEBUG-DM") then Debug.activate "M3TOK3-GENERATE-INIT";
   try
      let gen_init = (Debug.active "M3TOK3-GENERATE-INIT") in
      k3_program := M3ToK3.m3_to_k3 ~generate_init:gen_init !m3_program; 
      let (_,(_, pats), _, _) = !k3_program in
         Debug.print "LOG-PATTERNS" 
            (fun () -> Patterns.patterns_to_nice_string pats)
   with 
      | Calculus.CalculusException(calc, msg) ->
         bug ~exc:true ~detail:(fun () -> CalculusPrinter.string_of_expr calc)
             msg
      | M3ToK3.M3ToK3Failure(Some(calc), _, msg) ->
         bug ~exc:true ~detail:(fun () -> Calculus.string_of_expr calc) msg
      | M3ToK3.M3ToK3Failure(_, Some(k3), msg) ->
         bug ~exc:true ~detail:(fun () -> K3.string_of_expr k3) msg
      | M3ToK3.M3ToK3Failure(_, _, msg) ->
         bug ~exc:true ~detail:(fun () -> M3.string_of_m3 !m3_program) msg
      | K3Typechecker.K3TypecheckError(stack,msg) ->
         bug ~exc:true ~detail:(fun () -> 
                                K3Typechecker.string_of_k3_stack stack) msg
)
;;

if stage_is_active StageM3DMToK3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: M3DMToK3");
   if (Debug.active "DEBUG-DM") then
   begin
      let k3_printer = 
         if (Debug.active "NICE-K3") then K3.nice_code_of_prog 
                                     else K3.code_of_prog in
      let k3_queries = DMToK3.m3dm_to_k3 !k3_program !dm_program in
      Debug.print "LOG-DMTOK3" (fun () -> k3_printer k3_queries);
      k3_program := k3_queries
   end
)
;;

if stage_is_active StageParseK3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: ParseK3");
   if List.length !files > 1 then
      error "Multiple K3 files not supported yet"
   else 
   let f = List.hd !files in
   let lexbuff = Lexing.from_channel 
      (if f <> "-" then (open_in f) else stdin)
   in 
      k3_program := 
            K3parser.dbtoasterK3Program K3lexer.tokenize lexbuff;
      let (_,(_, pats), _, _) = !k3_program
      in
         Debug.print "LOG-PATTERNS" (fun () -> 
            Patterns.patterns_to_nice_string pats)
)
;;
if (stage_is_active StageOptimizeK3) then (
   if not (Debug.active "K3-NO-OPTIMIZE") then (
      Debug.print "LOG-DRIVER" (fun () -> "Running Stage: OptimizeK3");
      let optimizations = ref [] in
      if not (Debug.active "K3-NO-CSE-OPT")
         then optimizations := K3Optimizer.CSE :: !optimizations;
      if not (Debug.active "K3-NO-BETA-OPT")
         then optimizations := K3Optimizer.Beta :: !optimizations;
      let (db,(maps,patterns),triggers,tlqs) = !k3_program in
      try 
         k3_program := (
            db,
            (maps, patterns),
            List.map (fun (event, stmts) ->
               let trigger_vars = Schema.event_vars event in (
                  event, 
                  if not(Debug.active "DEBUG-DM") || trigger_vars = [] then
                    List.map (
                      K3Optimizer.optimize ~optimizations:!optimizations
                      (List.map fst trigger_vars)  
                    ) stmts
                  else
                    List.map (
                           K3Optimizer.dm_optimize ~optimizations:!optimizations
                             (List.map fst trigger_vars)
                          ) stmts
               )
            ) triggers,
            tlqs
         )
      with 
         | K3Typechecker.K3TypecheckError(stack, msg) -> 
               bug ~exc:true ~detail:(fun () -> 
                      K3Typechecker.string_of_k3_stack stack) msg
   )
)
;;
if stage_is_active StagePrintK3 then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintK3");
   if Debug.active "ORIGINAL-K3" then
      output_endline (K3.code_of_prog !k3_program)
   else
      output_endline (K3.nice_code_of_prog !k3_program)
)
;;
module K3InterpreterCG = K3Compiler.Make(K3Interpreter.K3CG)
module K3ScalaCompiler = K3Compiler.Make(K3Scalagen.K3CG)
module K3LMSCompiler = K3Compiler.Make(K3Scalagen.K3CG_LMS)
module K3ScalaLMSOptCompiler = K3Compiler.Make(K3Scalagen.K3CG_ScalaLMSOpt)
;;
if (stage_is_active StageOptimizeLMS) then (
   if (Debug.active "LMS-OPTIMIZE") then (
      Debug.print "LOG-DRIVER" (fun () -> "Running Stage: OptimizeLMS");

      let lms_source_code = [K3LMSCompiler.compile_query_to_string !k3_program] in
      let outfile = ref (!output_file ^ "-lms.scala") in
      let outfile_handle = (
               mk_path !outfile;
               open_out !outfile ) in
      let outfile_handle_option = ref (Some(outfile_handle)) in
      List.iter (output_endline_static outfile outfile_handle_option) lms_source_code;
      flush outfile_handle;
      print_endline ("Compiling LMS-friendly code: " ^ (!output_file ^ "-lms.scala"));

      let a = Unix.fork () in
      match a with
         | 0 ->  ExternalCompiler.lms_compiler.ExternalCompiler.compile !outfile (!output_file ^ "-lmsopt")
         | -1 -> Printf.printf "%s" "error accured on fork for compiling LMS code\n"
         | _ -> let check_exit_status = (function
            | Unix.WEXITED r -> r
            | _ -> -1000) in
            let childid, returncode = Unix.wait () in
            Debug.print "LOG-SCALA" (fun () -> "Compiling LMS Code: parent process => " ^ (string_of_int (Unix.getpid ())));
            Debug.print "LOG-SCALA" (fun () -> "Compiling LMS Code: child " ^ (string_of_int childid) ^ " closed with status code " ^ (string_of_int (check_exit_status returncode)));

      print_endline ("Executing compiled LMS-friendly code: " ^ (!output_file ^ "-lmsopt.jar"));
      
      if Sys.file_exists (!output_file ^ "-lmscomp.scala") then
         Sys.remove (!output_file ^ "-lmscomp.scala");
      let syscall cmd = (
         let ic, oc = Unix.open_process cmd in
         let buf = Buffer.create 16 in
         (try
            while true do
              Buffer.add_channel buf ic 1
           done
          with End_of_file -> ());
         let _ = Unix.close_process (ic, oc) in
         (Buffer.contents buf)
      ) in

      let read_file filename = 
         let lines = ref [] in
         let chan = open_in filename in
         try
           while true; do
             lines := input_line chan :: !lines
           done; []
         with End_of_file ->
           close_in chan;
           List.rev !lines in
      let _ = syscall ("java -classpath lib/dbt_scala/scala-library.jar:lib/dbt_scala/scala-compiler.jar:lib/dbt_scala/scala-reflect.jar:lib/dbt_scala/dbtlib.jar:lib/dbt_scala/lms.jar:lib/dbt_scala/toasterbooster.jar:" ^
      (!output_file ^ "-lmsopt.jar") ^ " -Dscala.usejavacp=true scala.tools.nsc.MainGenericRunner org.dbtoaster.QueryGenerator " ^ (!output_file ^ "-lmscomp.scala")) in
      let lms_optimized_triggers = read_file (!output_file ^ "-lmscomp.scala") in
      Sys.remove (!output_file ^ "-lmscomp.scala");
      source_code := !source_code @ lms_optimized_triggers;
      if Sys.file_exists (!output_file ^ "-lms.scala") then
         Sys.remove (!output_file ^ "-lms.scala");
      if Sys.file_exists (!output_file ^ "-lmsopt.jar") then
         Sys.remove (!output_file ^ "-lmsopt.jar");
   )
)
;;
if stage_is_active StageK3ToTargetLanguage then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: K3ToTargetLanguage");
   match !output_language with
      | Interpreter -> (
         try 
            StandardAdaptors.initialize ();
            let (_, (maps, patterns), _, _) = !k3_program in
            interpreter_program := (
               maps, patterns, 
               K3InterpreterCG.compile_k3_to_code !k3_program
            )
         with 
         | K3Interpreter.InterpreterException(expr,msg) ->
            (begin match expr with 
               | Some(s) -> error ~exc:true 
                                  ~detail:(fun () -> K3.string_of_expr s)
                                  msg
               | None    -> error ~exc:true msg
            end)
         | K3Typechecker.K3TypecheckError(stack,msg) ->
            bug ~exc:true ~detail:(fun () -> 
               K3Typechecker.string_of_k3_stack stack) msg
         | Failure(msg) ->
            error ~exc:true msg
         | K3.AnnotationException(None, Some(t), msg) ->
            error ~exc:true ~detail:(fun () -> K3.string_of_type t) msg
         | K3.AnnotationException(_, _, msg) ->
            error ~exc:true msg
         
               
      )   
      | Ocaml       -> bug "Ocaml codegen not implemented yet"
      | LMS       -> 
         source_code := !source_code @ [K3LMSCompiler.compile_query_to_string !k3_program]
      | Scala       -> 
         source_code := !source_code @ [ (if (Debug.active "LMS-OPTIMIZE") then K3ScalaLMSOptCompiler.compile_query_to_string !k3_program else K3ScalaCompiler.compile_query_to_string !k3_program)]
         (* All imperative languages now produce IMP *)
      | IMP
      | CPP         -> 
         begin try 
            k3_program := K3.unique_vars_prog !k3_program;
            imperative_program := 
               ImperativeCompiler.Compiler.imp_of_k3 !imperative_opts 
                                                     !k3_program 
         with 
            | K3Typechecker.K3TypecheckError(stack,msg) ->
               bug ~exc:true ~detail:(fun () -> 
                  K3Typechecker.string_of_k3_stack stack) msg
         end

      | _ -> bug "Unexpected K3 target language"
)
;;
if stage_is_active StagePrintImp then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: PrintImp");
   let ((_,_,(imp_core, _)),_,_) = !imperative_program in
      List.iter (fun (_,(_,expr)) ->
         output_endline 
            ((ImperativeCompiler.Target.string_of_ext_imp expr)^"\n\n")
      ) imp_core            
)
;;

(************ Imperative Stages ************)

if stage_is_active StageImpToTargetLanguage then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: ImpToTargetLanguage");
   source_code := 
      !source_code @ (ImperativeCompiler.Compiler.compile_imp !imperative_opts
                                              !imperative_program)
)
;;

(************ Program Management Stages ************)
if stage_is_active StageRunInterpreter then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: RunInterpreter");
   try 
      let db_checker = 
         if Debug.active "DBCHECK-ON" 
         then Some(DBChecker.DBAccess.init !sql_program)
         else None 
      in
      let (maps,patterns,compiled) = !interpreter_program in
      let db = Database.NamedK3Database.make_empty_db maps patterns in
      let result = K3Interpreter.K3CG.eval db_checker compiled [] [] db in
      if result <> Values.K3Value.Unit then
         output_endline (  "UNEXPECTED RESULT: "^
                           (Values.K3Value.string_of_value result) )   
   with 
   | K3Interpreter.InterpreterException(expr,msg) ->
      (begin match expr with 
         | Some(s) -> error ~exc:true 
                            ~detail:(fun () -> K3.string_of_expr s) 
                            msg
         | None -> error ~exc:true msg
      end)
   | Failure(msg) ->
      bug ~exc:true msg
)
;;
if stage_is_active StageOutputSource then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: OutputSource");
   List.iter output_endline !source_code
)
;;
if stage_is_active StageCompileSource then (
   Debug.print "LOG-DRIVER" (fun () -> "Running Stage: CompileSource");
   flush_output ();
   mk_path !binary_file;
   try 
      (!compiler).ExternalCompiler.compile !output_file !binary_file
   with 
      | Unix.Unix_error(errtype, fname, fargs) ->
         error ~detail:(fun () -> 
            "While running "^fname^"("^fargs^")"
         ) ("Error while compiling: "^(Unix.error_message errtype))
)
;;
