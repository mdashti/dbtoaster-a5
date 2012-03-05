
open Types
open Plan
open UnitTest

let test_db = mk_db [
   ("R", ["A"; "B"]);
   ("S", ["B"; "C"]);
   ("T", ["C"; "D"]);
];;

let test_compile (name:string) (expr:string) 
        (datastructures: (string * string list * string * type_t *
                           (bool * string * string list * string list * string) 
                           list) list) =
   log_list_test ("Compiling "^name)
      Compiler.string_of_ds
      (compile test_db name expr)
      (List.map (fun (ds_name, ds_ovars, ds_defn, ds_type, ds_triggers) -> 
         let ds = {
            Plan.ds_name = 
               Plan.mk_ds_name ds_name ([],List.map var ds_ovars) ds_type;
            Plan.ds_definition = parse_calc ~opt:true ds_defn
         } in {  
            Plan.description = ds;
            Plan.ds_triggers = 
               List.map (fun (ins, reln, relv, update_ov, delta) -> 
               (  event ins reln relv, 
                  {  Plan.target_map = 
                        Plan.mk_ds_name ds_name ([],List.map var update_ov)
                                             ds_type;
                     Plan.update_type = Plan.UpdateStmt;
                     Plan.update_expr = parse_calc ~opt:true delta
                  })
            ) ds_triggers
         }
      ) datastructures)
;;

test_compile "RTest" "AggSum([], R(A,B))" [
   "RTest", [], "AggSum([], R(A,B))", TInt, [
      true,  "R", ["RTest_pRA"; "RTest_pRB"], [], "1"; 
      false, "R", ["RTest_mRA"; "RTest_mRB"], [], "-1"; 
   ]
]
;;
test_compile "RSTest" "AggSum([], R(A,B)*S(B,C))" [
   "RSTest", [], "AggSum([], R(A,B)*S(B,C))", TInt, [
      true,  "S", ["RSTest_pSB"; "RSTest_pSC"], [], 
         "RSTest_mS2(int)[][RSTest_pSB]"; 
      false, "S", ["RSTest_mSB"; "RSTest_mSC"], [], 
         "-1*RSTest_mS2(int)[][RSTest_mSB]"; 
      true,  "R", ["RSTest_pRA"; "RSTest_pRB"], [], 
         "RSTest_mR2(int)[][RSTest_pRB]"; 
      false, "R", ["RSTest_mRA"; "RSTest_mRB"], [], 
         "-1*RSTest_mR2(int)[][RSTest_mRB]"; 
   ];
   "RSTest_mS2", ["RSTest_mSB"], "AggSum([RSTest_mSB], R(A,RSTest_mSB))", 
                   TInt, [
      true,  "R", ["RSTest_mS2_pRA"; "RSTest_mS2_pRB"], 
         ["RSTest_mS2_pRB"], 
         "1";
      false, "R", ["RSTest_mS2_mRA"; "RSTest_mS2_mRB"], 
         ["RSTest_mS2_mRB"], 
         "-1"; 
   ];
   "RSTest_mR2", ["RSTest_mRB"], "AggSum([RSTest_mRB], S(RSTest_mRB,C))", 
                   TInt, [
      true,  "S", ["RSTest_mR2_pSB"; "RSTest_mR2_pSC"], 
         ["RSTest_mR2_pSB"], 
         "1";
      false, "S", ["RSTest_mR2_mSB"; "RSTest_mR2_mSC"], 
         ["RSTest_mR2_mSB"], 
         "-1";
   ];
]
;;
(*
Debug.activate "VISUAL-DIFF";;
Debug.activate "LOG-COMPILE-DETAIL";;
Debug.activate "LOG-CALCOPT-DETAIL";;
Debug.activate "PRINT-VERBOSE";;
Debug.activate "LOG-UNIFY-LIFTS";;
Debug.activate "LOG-FACTORIZE";;
*)
test_compile "RSABTest" "AggSum([], R(A,B)*S(B,C)*A*C)" [
   "RSABTest", [], "AggSum([], R(A,B)*S(B,C)*A*C)", TFloat, [
      true,  "S", ["RSABTest_pSB"; "RSABTest_pSC"], [], 
         "RSABTest_pSC*RSABTest_mS3(float)[][RSABTest_pSB]"; 
      false, "S", ["RSABTest_mSB"; "RSABTest_mSC"], [], 
         "-1*RSABTest_mSC*RSABTest_mS3(float)[][RSABTest_mSB]"; 
      true,  "R", ["RSABTest_pRA"; "RSABTest_pRB"], [], 
         "RSABTest_pRA*RSABTest_mR3(float)[][RSABTest_pRB]"; 
      false, "R", ["RSABTest_mRA"; "RSABTest_mRB"], [], 
         "-1*RSABTest_mRA*RSABTest_mR3(float)[][RSABTest_mRB]"; 
   ];
   "RSABTest_mS3", ["RSABTest_mSB"], "AggSum([RSABTest_mSB], 
                     R(A,RSABTest_mSB)*A)", TFloat, [
      true,  "R", ["RSABTest_mS3_pRA"; "RSABTest_mS3_pRB"], 
         ["RSABTest_mS3_pRB"],
         "RSABTest_mS3_pRA"; 
      false, "R", ["RSABTest_mS3_mRA"; "RSABTest_mS3_mRB"], 
         ["RSABTest_mS3_mRB"],
         "-1*RSABTest_mS3_mRA"; 
   ];
   "RSABTest_mR3", ["RSABTest_mRB"], "AggSum([RSABTest_mRB], 
                     S(RSABTest_mRB,C)*C)", TFloat, [
      true,  "S", ["RSABTest_mR3_pSB"; "RSABTest_mR3_pSC"], 
         ["RSABTest_mR3_pSB"],
         "RSABTest_mR3_pSC"; 
      false, "S", ["RSABTest_mR3_mSB"; "RSABTest_mR3_mSC"], 
         ["RSABTest_mR3_mSB"],
         "-1*RSABTest_mR3_mSC"; 
   ];
]
