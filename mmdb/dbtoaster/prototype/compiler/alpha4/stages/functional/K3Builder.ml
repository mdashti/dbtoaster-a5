(**************************
 * K3 construction from M3
 ***************************)

module M3P = M3.Prepared
open M3
open M3Common
open K3.SR

(* Helpers *)

(* TODO: types *)
let args_of_vars vars = List.map (fun v -> v,TFloat) vars

let bind_for_apply_each vt e = Lambda(ATuple(vt), e)
let bind_for_aggregate vt (iv,it) e = AssocLambda(ATuple(vt),AVar(iv,it),e)

let map_to_expr mapn ins outs =
    (* TODO: value types *)
    begin match ins, outs with
    | ([],[]) -> SingletonPC(mapn,TFloat)
    | ([], x) -> OutPC(mapn,outs,TFloat)
    | (x, []) -> InPC(mapn,ins,TFloat)
    | (x,y)   -> PC(mapn,ins,outs,TFloat)
    end

let map_value_update_expr map_expr ine_l oute_l ve =
    begin match map_expr with
    | SingletonPC _ -> PCValueUpdate(map_expr, [], [], ve)
    | OutPC _ -> PCValueUpdate(map_expr, [], oute_l, ve)
    | InPC _ -> PCValueUpdate(map_expr, ine_l, [], ve)
    | PC _ -> PCValueUpdate(map_expr, ine_l, oute_l, ve)
    | _ -> failwith "invalid map expression for value update" 
    end

let map_update_expr map_expr e_l te =
    begin match map_expr with
    | OutPC _ -> PCUpdate(map_expr, [], te)
    | InPC _ -> PCUpdate(map_expr, [], te)
    | PC _ -> PCUpdate(map_expr, e_l, te)
    | _ -> failwith "invalid map expression for update"
    end

let map_access_to_expr map_expr init_expr singleton init_singleton out_patv =
    let aux sch t init_expr =
        (* TODO: use typechecker to compute type *)
        let ke = List.map (fun (v,t) -> Var(v,t)) sch in 
        let map_t = Collection(TTuple((List.map snd sch)@[t])) in
        let map_v,map_var = "slice",Var("slice", map_t) in
        let access_expr =
            if singleton then 
                IfThenElse(Member(map_var,ke), Lookup(map_var,ke), init_expr)
            else let p_ve = List.map (fun v -> 
                    let t = List.assoc v sch in (v,(Var(v,t)))) out_patv 
                 in Slice(map_var,sch,p_ve)
        in Lambda(AVar(map_v, map_t), access_expr)
    in
    let init_aux map_expr ins outs ie =
        let ine_l = List.map (fun (v,t) -> Var(v,t)) ins in
        let oute_l = List.map (fun (v,t) -> Var(v,t)) outs in
        let (iv_a, iv_e) =
            (* TODO: use typechecker to compute type *)
            let t = if init_singleton then TFloat else
                begin match map_expr with
                | InPC _ -> Collection(TTuple((List.map snd ins)@[TFloat]))
                | OutPC  _| PC _ -> Collection(TTuple((List.map snd outs)@[TFloat]))
                | _ -> failwith "invalid map type for initial values"
                end
            in AVar("init_val", t), Var("init_val", t)
        in
        (* Helper to update the db w/ a singleton init val *)
        let update_singleton_aux rv_f =
            let update_expr = 
                map_value_update_expr map_expr ine_l oute_l iv_e
            in Apply(Lambda(iv_a, Block([update_expr; rv_f iv_e])), ie)
        in
        (* Helper to build an index on a init val slice, and update the db *)
        let index_slice_aux rv_f =
            (* Note: assume CG will do indexing as necessary for PCUpdates *)
            let update_expr = map_update_expr map_expr ine_l iv_e
            in Block([update_expr; rv_f iv_e])
        in
        if singleton && init_singleton then
            (* ivc eval + value update + value rv *)
            update_singleton_aux (fun x -> x)

        else if init_singleton then
            (* ivc eval + value update + slice construction + slice rv *)
            update_singleton_aux (fun iv_e ->
                begin match map_expr with
                | OutPC _ | PC _ -> Singleton(Tuple(oute_l@[iv_e])) 
                | _ -> failwith "invalid map type for slice lookup"
                end)

        else if singleton then
            (* ivc eval + slice update + value lookup rv *)
            let ke = match map_expr with
                | InPC _ -> ine_l | OutPC _ -> oute_l  | PC _ -> oute_l
                | _ -> failwith "invalid map type for initial values" in
            let lookup_expr_f rv_e = Lookup(rv_e, ke)
            in Apply(Lambda(iv_a, index_slice_aux lookup_expr_f), ie)
        
        else
            (* ivc eval + slice update + slice rv *)
            Apply(Lambda(iv_a, index_slice_aux (fun x -> x)), ie)
    in
    begin match map_expr with
    | SingletonPC(id,t) -> map_expr
    | OutPC(id,outs,t) ->
        let init_expr = init_aux map_expr [] outs (Const(CFloat(0.0)))
        in Apply(aux outs t init_expr, map_expr)

    | InPC(id,ins,t) ->
        let init_expr = init_aux map_expr ins [] init_expr
        in Apply(aux ins t init_expr, map_expr)

    | PC(id,ins,outs,t) ->
        let init_expr = init_aux map_expr ins outs init_expr in
        let nested_t =
            (* TODO: use typechecker to compute type *)
            let ins_t = List.map snd ins in
            let outs_t = List.map snd outs
            in Collection(TTuple(ins_t@[Collection(TTuple(outs_t@[t]))]))
        in
        let in_el = List.map (fun (v,t) -> Var(v,t)) ins in
        let map_v,map_var = "m",Var("m", nested_t) in
        let out_access_fn = Apply(aux outs t init_expr, Lookup(map_var,in_el)) in
        let access_fn = Lambda(AVar(map_v, nested_t),
            IfThenElse(Member(map_var,in_el), out_access_fn, init_expr))
        in Apply(access_fn, map_expr)
        
    | _ -> failwith "invalid map for map access"
    end

let rec calc_to_singleton_expr calc : expr_t =
    let recur f c1 c2 =
        f (calc_to_singleton_expr c1) (calc_to_singleton_expr c2) in 
    begin match (M3P.get_calc calc) with
        | M3.Const(i)   -> Const(i)
        | M3.Var(x)     -> Var(x, TFloat) (* TODO: var type *)

        | M3.MapAccess(mapn, inv, outv, init_aggecalc) ->
            (* Note: no need for lambda construction since all in vars are
             * bound. *)
            (* TODO: schema+value types *)
            let s_l = List.map (List.map (fun v -> (v,TFloat))) [inv; outv] in
            let (ins,outs) = (List.hd s_l, List.hd (List.tl s_l)) in
            let singleton_init_code = 
               (M3P.get_singleton (M3P.get_ecalc init_aggecalc)) ||
               (M3P.get_full_agg (M3P.get_agg_meta init_aggecalc))
            in
            let init_expr = m3rhs_to_expr outv init_aggecalc in
            let map_expr = map_to_expr mapn ins outs in
            map_access_to_expr map_expr init_expr true singleton_init_code []

        | M3.Add (c1, c2) -> recur (fun x y -> Add(x,y))  c1 c2 
        | M3.Mult(c1, c2) -> recur (fun x y -> Mult(x,y)) c1 c2
        | M3.Lt  (c1, c2) -> recur (fun x y -> Lt(x,y))   c1 c2
        | M3.Leq (c1, c2) -> recur (fun x y -> Leq(x,y))  c1 c2
        | M3.Eq  (c1, c2) -> recur (fun x y -> Eq(x,y))   c1 c2
        | M3.IfThenElse0(c1, c2) -> recur (fun x y -> IfThenElse0(x,y)) c1 c2
    end

and op_to_expr op c c1 c2 : expr_t =
    let aux ecalc = (calc_schema ecalc, M3P.get_singleton ecalc) in
    let (outv1, c1_sing) = aux c1 in
    let (outv2, c2_sing) = aux c2 in
    let (schema, c_sing, c_prod) =
        calc_schema c, M3P.get_singleton c, M3P.get_product c
    in match (c_sing, c1_sing, c2_sing) with
        | (true, false, _) | (true, _, false) | (false, true, true) ->
            failwith "invalid parent singleton"
        
        | (true, _, _) -> calc_to_singleton_expr c

        | (_, true, false) | (_, false, true) ->
            (* TODO: types *)
            let inline = calc_to_singleton_expr (if c1_sing then c1 else c2) in
            let (v,v_t,l,r,cschema) =
                if c1_sing then "v2",TFloat,inline,Var("v2",TFloat),outv2
                else "v1",TFloat,Var("v1",TFloat),inline,outv1 in
            let fn = bind_for_apply_each
                ((args_of_vars cschema)@[v,v_t]) (op schema l r)
            in Map(fn, calc_to_expr (if c1_sing then c2 else c1))
        
        | (_, false, false) ->
            (* TODO: types *)
            (* Note: there is no difference to the nesting whether this op
             * is a product or a join *)
            let (l,r) = (Var("v1",TFloat), Var("v2",TFloat)) in
            let nested = bind_for_apply_each
                ((args_of_vars outv2)@["v2",TFloat]) (op schema l r) in 
            let inner = bind_for_apply_each ((args_of_vars outv1)@["v1",TFloat])
                (Map(nested, calc_to_expr c2)) 
            in Flatten(Map(inner, calc_to_expr c1))

and calc_to_expr calc : expr_t =
    let tuple op schema c1 c2 =
        (* TODO: schema types *)
        Tuple((List.map (fun v -> (Var (v, TFloat))) schema)@[op c1 c2])
    in  
    begin match (M3P.get_calc calc) with
        | M3.Const(i)   -> Const(i)
        | M3.Var(x)     -> Var(x, TFloat) (* TODO: var type *)

        | M3.MapAccess(mapn, inv, outv, init_aggecalc) ->
            (* TODO: schema, value types *)
            let s_l = List.map (List.map (fun v -> (v,TFloat))) [inv; outv] in
            let (ins,outs) = (List.hd s_l, List.hd (List.tl s_l)) in
            let init_expr = m3rhs_to_expr outv init_aggecalc in
            let map_expr = map_to_expr mapn ins outs in
            let singleton_init_code = 
               (M3P.get_singleton (M3P.get_ecalc init_aggecalc)) ||
               (M3P.get_full_agg (M3P.get_agg_meta init_aggecalc)) in
            let patv = M3P.get_extensions (M3P.get_ecalc init_aggecalc)
            in map_access_to_expr map_expr init_expr
                (M3P.get_singleton calc) singleton_init_code patv

        | M3.Add (c1, c2) -> op_to_expr (tuple (fun c1 c2 -> Add (c1,c2))) calc c1 c2 
        | M3.Mult(c1, c2) -> op_to_expr (tuple (fun c1 c2 -> Mult(c1,c2))) calc c1 c2
        | M3.Eq  (c1, c2) -> op_to_expr (tuple (fun c1 c2 -> Eq  (c1,c2))) calc c1 c2
        | M3.Lt  (c1, c2) -> op_to_expr (tuple (fun c1 c2 -> Lt  (c1,c2))) calc c1 c2
        | M3.Leq (c1, c2) -> op_to_expr (tuple (fun c1 c2 -> Leq (c1,c2))) calc c1 c2
        | M3.IfThenElse0(c1, c2) ->
            let short_circuit_if = M3P.get_short_circuit calc in
            if short_circuit_if then
                 op_to_expr (tuple (fun c1 c2 -> IfThenElse0(c1,c2))) calc c1 c2
            else op_to_expr (tuple (fun c2 c1 -> IfThenElse0(c1,c2))) calc c2 c1
    end 

and m3rhs_to_expr lhs_outv paggcalc : expr_t =
   (* invokes calc_to_expr on calculus part of paggcalc.
    * based on aggregate metadata:
    * -- simply uses the collection
    * -- applies bigsums to collection.
    *    we want to apply structural recursion optimizations in this case.
    * -- projects to lhs vars 
    *)
    let ecalc = M3P.get_ecalc paggcalc in
    
    (* TODO: fix bug, rhs_outv is wrong here since it includes all vars
     * used in rhs, see rsgb.sql example *)
    let rhs_outv = calc_schema ecalc in
    
    (* TODO: simplify rhs, e.g. lift lambdas *)
    let rhs_expr = calc_to_expr ecalc in
    let init_val = Const(CFloat(0.0)) in
    let agg_fn = bind_for_aggregate
        ((args_of_vars rhs_outv)@["v",TFloat]) ("accv",TFloat)
        (Add(Var("v", TFloat), Var("accv", TFloat)))
    in
    if (M3P.get_singleton ecalc) || (rhs_outv = lhs_outv) then rhs_expr
    else if M3P.get_full_agg (M3P.get_agg_meta paggcalc) then
        (* TODO: simplify aggregate w/ struct rec *)
        Aggregate (agg_fn, init_val, rhs_expr) 
    else
        (* projection to lhs vars + aggregation *)
        let gb_fn =
            let lhs_tuple = Tuple(List.map (fun v -> Var(v,TFloat)) lhs_outv)
            in bind_for_apply_each ((args_of_vars rhs_outv)@["v",TFloat]) lhs_tuple 
        in GroupByAggregate(agg_fn, init_val, gb_fn, rhs_expr)
        

(**********************************
 * Incremental section
 **********************************)

(* Incremental evaluation types *)
 
(* Top-level statement, computes and applies (i.e. persists) map deltas.
 *
 * collection, increment statement
 *)
type statement = expr_t * expr_t

(* Trigger functions *) 
type trigger = M3.pm_t * M3.rel_id_t * M3.var_t list * statement list

type program = M3.map_type_t list * M3Common.Patterns.pattern_map * trigger list

(* Statement expression construction:
 * -- creates structural representations of the the incr and init value exprs,
 *    composes them in an update expression, merging in the case of delta slices.
 * -- invokes the update expression w/ existing values/slices, binding+looping
 *    persistent collection input vars, and applying updates.
*)
let collection_stmt trig_args m3stmt : statement =
    (* Helpers *)
    let schema vars = List.map (fun v -> (v,TFloat)) vars in
    let vars_expr vars = List.map (fun v -> Var(v,TFloat)) vars in
    let fn_arg_expr v t = (v,t),Var(v,t) in

    let ((mapn, lhs_inv, lhs_outv, init_aggcalc), incr_aggcalc, sm) = m3stmt in
    let ((incr_expr, incr_single),(init_expr,init_single)) =
        let expr_l = List.map (fun aggcalc ->
            let calc = M3P.get_ecalc aggcalc in
            let s = M3P.get_singleton calc ||
                    (M3P.get_full_agg (M3P.get_agg_meta aggcalc))
            in
            (* Note: we can only use calc_to_singleton_expr if there are
             * no loop or bigsum vars in calc *) 
            ((if M3P.get_singleton calc then calc_to_singleton_expr calc
              else m3rhs_to_expr lhs_outv aggcalc),s))
            [incr_aggcalc; init_aggcalc]
        in (List.hd expr_l, List.hd (List.tl expr_l))
    in
    
    let (ins,outs) = (schema lhs_inv, schema lhs_outv) in
    let (in_el, out_el) = (vars_expr lhs_inv, vars_expr lhs_outv) in 

    (* TODO: use typechecker to compute types here *)
    let out_tier_t = Collection(TTuple(List.map snd outs@[TFloat])) in

    let collection = map_to_expr mapn ins outs in

    (* Update expression, singleton initializer expression
     * -- update expression: increments the current var/slice by computing
     *    a delta. For slices, merges the delta slice w/ the current.
     * -- NOTE: returns the increment for the delta slice only, not the
     *    entire current slice. Thus each incremented entry must be updated
     *    in the persistent store, and not the slice as a whole. 
     * -- singleton initializer: for singleton deltas, directly computes
     *    the new value by combining (inline) the initial value and delta
     *)
    let (update_expr, sing_init_expr) =
        let zero_init = Const(CFloat(0.0)) in
        let singleton_aux init_e =
            let ca,ce = fn_arg_expr "current_v" TFloat in
            (Lambda(AVar(fst ca, snd ca),Add(ce,incr_expr)), init_e)
        in
        let slice_t = Collection(TTuple((List.map snd outs)@[TFloat])) in
        let slice_aux init_f =
            let ca,ce = fn_arg_expr "current_slice" slice_t in
            let ma,me = fn_arg_expr "dv" TFloat in
            (* merge fn: check if the delta exists in the current slice and
             * increment, otherwise compute an initial value and increment  *)
            let merge_body =
                let build_entry e = Tuple(out_el@[e]) in 
                IfThenElse(Member(ce,out_el),
                    build_entry (Add(Lookup(ce, out_el), me)),
                    build_entry (init_f me))
            in
            let merge_fn = bind_for_apply_each
                ((args_of_vars lhs_outv)@[ma]) merge_body in
            (* slice update: merge current slice with delta slice *)
            let merge_expr = Map(merge_fn, incr_expr)
            in (Lambda(AVar(fst ca, snd ca),merge_expr), zero_init)
        in
        match (incr_single, init_single) with
        | (true,true) -> singleton_aux (Add(incr_expr,init_expr))

        | (true,false) ->
            (* Note: we don't need to bind lhs_outv for init_expr since
             * incr_expr is a singleton, implying that lhs_outv are all
             * bound vars.
             * -- TODO: how can the init val be a slice then? if there are
             *    no loop out vars, and all in vars are bound, and all bigsums 
             *    are fully aggregated, this case should never occur. 
             *    Check this. *)
            (* Look up slice w/ out vars for init lhs expr *)
            singleton_aux (Add(Lookup(init_expr,out_el), incr_expr))

        | (false,true) -> slice_aux (fun me -> Add(init_expr,me))
        
        | (false,false) ->
            (* All lhs_outv are bound in the map function for the merge,
             * making loop lhs_outv available to the init expr. *)
            slice_aux (fun me -> Add(Lookup(init_expr, out_el), me))
    in
    
    (* Statement expression:
     * -- statement_expr is a side-effecting expression that updates a
     *    persistent collection, thus has type Unit *)

    let loop_in_aux (la,le) loop_fn_body =
        let patv = Util.ListAsSet.inter lhs_inv trig_args in
        let pat_ve = List.map (fun v -> (v,Var(v,TFloat))) patv in
        let in_coll = if (List.length patv) = (List.length lhs_inv)
            then Singleton(Lookup(collection, List.map snd pat_ve))
            else Slice(collection, ins, pat_ve) in
        let loop_fn =
            bind_for_apply_each ((args_of_vars lhs_inv)@[la]) loop_fn_body
        in Iterate(loop_fn, in_coll)
    in
    let loop_update_aux ins outs delta_slice =
        let ua,ue = fn_arg_expr "updated_v" TFloat in
        let update_body = map_value_update_expr collection ins outs ue in
        let loop_update_fn = bind_for_apply_each
            ((args_of_vars lhs_outv)@[ua]) update_body
        in Iterate(loop_update_fn, delta_slice)
    in
    let statement_expr =
        begin match lhs_inv, lhs_outv, incr_single with
        | ([],[],false) -> failwith "invalid slice update on a singleton map"

        | ([],[],_) ->
            let rhs_expr = (Apply(update_expr, collection))
            in map_value_update_expr collection [] [] rhs_expr

        | (x,[],false) -> failwith "invalid slice update on a singleton out tier"

        | (x,[],_) ->
            let la,le = fn_arg_expr "existing_v" TFloat in
            let rhs_expr = Apply(update_expr, le) 
            in loop_in_aux (la,le)
                 (map_value_update_expr collection in_el [] rhs_expr) 

        | ([],x,false) ->
            (* We explicitly loop, updating each incremented value in the rhs slice,
             * since the rhs_expr is only the delta slice and not a full merge with
             * the current slice.
             *)
            let rhs_expr = Apply(update_expr, collection)
            in loop_update_aux [] out_el rhs_expr

        | ([],x,_) ->
            let rhs_expr = 
                IfThenElse(Member(collection, out_el),
                Apply(update_expr, Lookup(collection, out_el)), sing_init_expr)
            in map_value_update_expr collection [] out_el rhs_expr

        | (x,y,false) ->
            (* Use a value update loop to persist the delta slice *)
            let la,le = fn_arg_expr "existing_slice" out_tier_t in
            let rhs_expr = Apply(update_expr, le) in
            let update_body = loop_update_aux in_el out_el rhs_expr
            in loop_in_aux (la,le) update_body

        | (x,y,_) ->
            let la,le = fn_arg_expr "existing_slice" out_tier_t in
            let rhs_expr = IfThenElse(Member(le, out_el),
                Apply(update_expr, Lookup(le, out_el)), sing_init_expr)
            in loop_in_aux (la,le)
                (map_value_update_expr collection in_el out_el rhs_expr)
        end
    in
    (collection, statement_expr)


let collection_trig m3trig : trigger =
    let (evt, rel, args, stmts) = m3trig
    in (evt, rel, args, List.map (collection_stmt args) stmts)

let collection_prog m3prog patterns : program =
    let (schema, triggers) = m3prog
    in (schema, patterns, List.map collection_trig triggers)

let m3_to_k3 (schema,m3prog):(K3.SR.trigger list) =
   let m3ptrigs,patterns = M3Compiler.prepare_triggers m3prog in
   let (_,_,trigs) = collection_prog (schema,m3ptrigs) patterns in
      trigs

let m3_to_k3_opt (schema,m3prog):(K3.SR.trigger list) =
   let optimize e trig_args = 
      (K3Optimizer.simplify_collections 
         (K3Optimizer.lift_ifs trig_args 
            (K3Optimizer.inline_collection_functions [] e)))
   in
   let rec fixpoint e trig_args =
      let new_e = optimize e trig_args in
         if e = new_e then e else fixpoint new_e trig_args 
   in
      List.map (fun (pm,rel,trig_args,stmtl) ->
         (pm, rel, trig_args, (
            (List.map (fun (lhs,rhs) -> (lhs, (fixpoint rhs trig_args))) stmtl)
         ))) (m3_to_k3 (schema,m3prog))