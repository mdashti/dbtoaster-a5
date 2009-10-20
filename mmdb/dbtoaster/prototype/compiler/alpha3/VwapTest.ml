open Algebra;;

(* Name functions used in the unit test for simpler refactoring *)
module C = Compiler.MessageCompiler
let compile_step = Compiler.compile_delta_for_rel
let compile_main = C.compile_readable_messages

let pos = false
let neg = true;;

(*
let vwap =
RVal(AggSum(RProd[RVal(Var("p0", TInt)); RVal(Var("v0", TInt))],
  RA_MultiNatJoin[
    RA_Leaf(Rel("B", [("p0", TInt); ("v0", TInt)]));
    RA_Leaf(AtomicConstraint(Le, RVal(Const (Int 0)),
      RSum[RProd[RVal(Const (Int 25));
                 RVal(AggSum(RVal(Var("v1", TInt)),
                     RA_Leaf(Rel("B", [("p1", TInt); ("v1", TInt)]))))];
           RVal(AggSum(RVal(Var("v2", TInt)),
               RA_MultiNatJoin[RA_Leaf(Rel("B", [("p2", TInt); ("v2", TInt)]));
                               RA_Leaf(AtomicConstraint(Lt,
                                   RVal(Var("p0", TInt)),
                                   RVal(Var("p2", TInt))))]))]))
]));;
*)


let q0 =
RVal(AggSum(RProd[RVal(Var("p0", TInt)); RVal(Var("v0", TInt))],
   RA_MultiNatJoin[
      RA_Leaf(Rel("B", [("p0", TInt); ("v0", TInt)]));
      RA_Leaf(AtomicConstraint
          (Eq, RVal(Var("p0", TInt)), RVal(Var("loop_p", TInt))))
   ]))
;;

let vwap2 =
make_term(
RVal(AggSum(q0,
   RA_Leaf(AtomicConstraint(Le, RVal(Const (Int 0)),
      RSum[RProd[RVal(Const (Int 25));
                 RVal(AggSum(RVal(Var("v1", TInt)),
                             RA_Leaf(Rel("B", [("p1", TInt); ("v1", TInt)]))))];
           RVal(AggSum(RVal(Var("v2", TInt)),
                       RA_MultiNatJoin[RA_Leaf(Rel("B",
                                           [("p2", TInt); ("v2", TInt)]));
                                       RA_Leaf(AtomicConstraint(Lt,
                                          RVal(Var("loop_p", TInt)),
                                          RVal(Var("p2", TInt))))]))]))
))
);;


let s0 = "(25*AggSum(v1, B(p1, v1)))+AggSum(v2, B(p2, v2) and loop_p<p2)";;
let s1 = "("^s0^"+(25*v)+(v*(if loop_p<p then 1 else 0)))";;

let delta_cond =
List.map (fun (x,y) -> (x, term_as_string y []))
(simplify (term_delta pos "B" [("p", TInt); ("v", TInt)] vwap2)
    [("p", TInt); ("v", TInt); ("loop_p", TInt)] [])
=
[([],
  "(if 0<="^s1^" then ((if p=loop_p then p else 0)*v) else 0)");
 ([],
  "(if 0<="^s1^" and ("^s0^")<0 then AggSum((loop_p*v0), B(loop_p, v0)) else 0)");
 ([],
  "(-1*(if "^s1^"<0 and 0<=("^s0^") then AggSum((loop_p*v0), B(loop_p, v0)) else 0))")]
;;



let c_new = "((25*vwapB1[])+vwapB2[loop_p]+(25*x_vwapB_V)+(x_vwapB_V*(if loop_p<x_vwapB_P then 1 else 0)))";;

let c_old = "((25*vwapB1[])+vwapB2[loop_p])";;

let vwap_test =
compile_main [("B", [("P", TInt); ("V", TInt)])] "vwap" []
    [("loop_p", TInt)] pos vwap2
=
["+B(x_vwapB_P, x_vwapB_V): vwap[] += bigsum_{loop_p} (if 0<="^c_new^" then ((if x_vwapB_P=loop_p then x_vwapB_P else 0)*x_vwapB_V) else 0)";
 "+B(x_vwapB_P, x_vwapB_V): vwap[] += bigsum_{loop_p} (if 0<="^c_new^" and "^c_old^"<0 then vwapB3[loop_p] else 0)";
 "+B(x_vwapB_P, x_vwapB_V): vwap[] += bigsum_{loop_p} (-1*(if "^c_new^"<0 and 0<="^c_old^" then vwapB3[loop_p] else 0))";
 "+B(x_vwapB1B_P, x_vwapB1B_V): vwapB1[] += x_vwapB1B_V";
 "+B(x_vwapB2B_P, x_vwapB2B_V): foreach loop_p do vwapB2[loop_p] += (x_vwapB2B_V*(if loop_p<x_vwapB2B_P then 1 else 0))";
 "+B(x_vwapB3B_P, x_vwapB3B_V): vwapB3[x_vwapB3B_P] += (x_vwapB3B_P*x_vwapB3B_V)"]
;;

 
