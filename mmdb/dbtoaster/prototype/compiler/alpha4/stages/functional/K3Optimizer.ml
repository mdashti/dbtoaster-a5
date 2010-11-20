(*************************************
 * K3 normalization and optimization
 *************************************)

(* Lifting (aka K3 expression normalization):
 * -- conditionals:
 *   ++ the point of lifting is to enable optimization of pre, post code in
 *      the context of each branch.
 *   ++ we lift conditionals to the top of their dependency block, pushing
 *      parent code into both branches as necessary.
 *   ++ lifting increases code size, thus we may want a lowering transformation
 *      at the very end if no other optimizations have been applied to either
 *      branch.
 *
 * -- functions: overall goal is to simplify any partially evaluted function to
 *    a normalized form, of lambda x -> lambda y -> ... , where x,y are the
 *    remaining variables to be bound before evaluation can complete 
 *
 * -- collection functions:
 *   ++ we lift collection operations applied to partially evaluated functions,
 *   ++ two cases:
 *     -- partially evaluated collections, e.g.:
 *        map(lambda y -> ..., lambda x -> collection...)
 *        => lambda x -> map(lambda y -> ..., collection ...)
 *     -- partially evaluated apply-each
 *        map(lambda a -> lambda b c -> ..., collection(b;c))
 *        => lambda a -> map(lambda b c -> ..., collection(b;c))
 *   ++ transformation order: pe-coll first, then pe-appeach 
 *   ++ when can we not lift? see notes on lifting in typechecking:
 *     i.  collections of functions, e.g.
 *         map(lambda x ..., collection(lambda y -> ...))
 *   ++ cases not handled:
 *     i. partially evaluted init aggregate values
 *     ii. partially evaluted group-by functions
 *
 * -- regular functions:
 *   ++ we lift lambdas above partial function applications, e.g.:
 *      apply(lambda a -> lambda b -> ..., x)
 *      => lambda b -> apply (lambda a -> ..., x)
 * 
 * -- what about interaction of conditionals and lifting?
 *   ++ must respect data dependencies, i.e. conditionals using bindings cannot
 *      be lifted above the relevant lambda
 *   ++ otherwise everything else is fair game, provided we duplicate code as
 *      necessary.
 * 
 * -- expression normalization algorithm:
 *  ++ recursively turn every sub expression into the form:
 *    lambda ... ->
 *        independent ifs
 *        then (... dependent ifs ... collection ops (..., collection) ... )
 *        else (... dependent ifs ... collection ops (..., collection) ... )
 *    where the outer most lambdas are for any free variables in the body
 *    and the independent ifs are those if statements that depend only on these
 *    free variables. Dependent ifs are those whose predicates are bound by
 *    some enclosed expression.
 *
 *  ++ lifting lambdas:
 *    -- cannot lift lambda above apply without changing typing of
 *       surrounding code
 *      ++ we could inline the application instead, but this will blow up
 *         code size, or could lead to multiple recomputations of the
 *         argument. In K3, since applies used for accessing maps, this would
 *         mean multiple conversions of maps to our internal temporary
 *         collections.
 *      ++ we'll only eliminate lambdas (i.e. inline) for flat arguments.
 * 
 *    -- lifting algorithm:
 *      ++ this is not standard lambda lifting, which aims at optimizing
 *         closure construction, etc, rather it is to create a normalized
 *         form for partially evaluated K3. This ensures other optimizations
 *         can fully apply to the curried function's body.
 *      ++ in general, lift any remaining lambdas from all child expressions in
 *         left-to-right AST order
 *      ++ pattern match on:
 *        -- collection ops, yield lifted form.
 *           this will fully lift lambdas out of collection operation chains.
 *        -- project, singletons
 *        -- binops: lambdas down each branch get lifted outside the binop, e.g.
 *           (lambda x -> ...) * (lambda y -> ...)
 *           => lambda x -> lambda y -> ... * ...
 *        -- blocks: lambdas for each stmt get lifted
 *        -- lambda, assoc lambda: lambdas from bodies get lifted to create
 *           nested form
 *        -- apply: partial evaluations get lifted
 *          ++ we must be careful not to change application order of args
 *          ++ apply binds from left-to-right, thus nested lambdas from partials
 *             must stay inner-most (i.e. right-most) until lifted outside 
 *             the apply
 *        -- tuple collection ops: map expr and key lambdas get lifted
 *        -- persistent collections: cannot contain lambdas
 *        -- updates: lift from all children
 *
 *    -- let's defer this since the M3 generated will not contain opportunities
 *       to apply this immediately... BUT can it occur in an intermediate
 *       form after some other optimization we apply?
 *
 *  ++ lifting ifs: TODO
 *
 *)

(* Collection operation transformations
 *
 *  ++ transformation ordering: what order do we normalize/optimize?
 *    1. lambdas first, since they may block condition lifting
 *    2. conditions second. Note this implies all normalization transformations
 *       before any optimizations.
 *    -- see below regarding lifting ifs and collection transformation
 *       algorithm traversal
 *
 *    3. collection ops w/ function composition
 *      ++ eliminate map-, then agg-chains, i.e.:
 *           map(f,map(g,c)) and agg(f,i,map(g,c))
 *        -- assuming f,g are simple/flat
 *      ++ push down aggregations i.e.:
 *           agg(f,i,map(lambda.map(g,c2),c1))
 *
 *      ++ what about map(f,gbagg(g,i,h,c)) ?
 *        -- we can compose f/g, i.e => gbagg(compose(f,g),i,h,c)
 *        -- this is like agg-chaining since it removes a map, yielding a
 *           strictly simpler expression
 *
 *      ++ and gbagg(f,i,g,map(h,c)) ?
 *        -- we can compose g/h, i.e. => gbagg(f,i,compose(g,h),c) 
 *
 *    4. pipelining/intermediates optimization, w/ inlining+arity transforms
 *      ++ nest map-chains when parent map function is non-selective
 *         i.e. map(f=lambda x.map(g=lambda y. ..,c2),map(h=lambda z. ..,c1))
 *         with non-selective h
 *        -- selective fn definition? any pruning conditions on the variable z,
 *           where a pruning condition is the predicate part of an IfThenElse0.
 *      ++ TODO: join ordering?
 *        -- note we are getting to join ordering here. for example if g is
 *           selective w.r.t y and separable w.r.t x, but h is not, we want
 *           map(g',c2) as the outer collection, where g' only operates on y.
 *        -- if both g and h are selective we may want to transform based on
 *           cardinalities.
 *        -- this is interesting, but generally gets onto decomposition of
 *           functions w.r.t a free variable. Let's do this later.
 *      ++ TODO: vectorization/batching?
 *
 *    -- why do pipelining transforms after pushing down aggregates? does the
 *       order of these two optimizations matter? DONE: see answer below.
 *      ++ eliminating chains is a no-brainer, since the code is strictly simpler
 *      ++ pipelining should also result in strictly simpler code
 *         (i.e. fewer maps), since we eliminate map-chains w/ composition
 *      ++ this is not the case with pushing aggs, since it duplicates the agg
 *         into applying on both the inner and outer collection
 *      ++ since pushing down aggs does not yield a strictly simpler form, are
 *         there opportunities to apply the previous transforms again after
 *         pushing aggs? do we need optimization to a fixpoint?
 *        -- at the very least, two aggs might lead to agg-chain optimizations
 *        -- why fixpoint, and not just recursive optimization? and do we want
 *           to optimize bottom-up or top-down or both?
 *        -- I think we can do top-down local fix-points, that is each
 *           sub-expression converges since:
 *           i. for maps, optimizations of substructures do not change the
 *              map function f. That is, if f is selective, or nested, or flat
 *              it will remain so.
 *              However the RHS collection can change, implying we should
 *              optimize the whole expr again, BUT only if there was some
 *              change.
 *              Overall the RHS collection gets simpler at each step, while f
 *              becomes more complex through composition. That is our transforms
 *              are monotonically increasing compositions on f. We never go the
 *              other way, where we break up/decompose f, since in general, we
 *              don't know how to decompose functions.
 *          ii. for aggs, we may make the RHS more complex by duplicating an
 *              agg there in the case of a nested RHS collection. We need to
 *              show that this doesn't continue unbounded. All other cases
 *              monotonically compose with f.
 *              This works for the following reason. Consider the transform:
 *                 agg(f,i,x=map(g=lambda.map(h,c2),c1))
 *                 => agg(f,i,x'=map(g'=lambda.agg(f,0,map(h,c2)),c1))
 *              This transformation changes an RHS map operation x->x' by
 *              pushing an aggregate into a nested map function g->g'.
 *              The key point is that c1 is unchanged here. That is, the
 *              transform only affects the function part of the nested map,
 *              which just as above, only makes a function more complex (g->g').
 *              Any subsequent transformations of the RHS map operation x would
 *              continue to simplify c1, at the expense of the inner function g',
 *              and we would never reverse the effects of this aggregate
 *              pushdown operation since we do not decompose functions.
 *      ++ this answers the above question. We simultaneously match for:
 *           i. simple map- and agg-chains
 *           ii. aggregate pushdowns
 *           iii. non-selective nested map-chains
 *         and apply transformations in a top-down local-fixpoint manner. 
 *
 *    -- do collection optimizations affect partial evaluation or conditions?
 *      ++ this determines the scope of the optimization transformation, i.e.
 *         can we do lambda and condition lifting entirely before structural
 *         recursion?
 *      ++ i don't think so for partial evals.
 *      ++ for conditionals, the question is can it introduce new independent
 *         conditions (that should be lifted to the top), and suboptimal
 *         dependent conditions (that should be lifted to their uppermost
 *         positions)?
 *        -- the answer is no: collection optimizations only affect collection
 *           operations, and compose/inline functions. Function composition and
 *           inlining only eliminates function applications, changes function
 *           arities, and performs variable->code substitutions, none of which
 *           introduces or eliminates conditionals... assuming the code
 *           which we substitute for variables has no conditionals. Even if
 *           this is the case, these conditions would be dependent ones,
 *           otherwise they would already have been lifted. Dependent conditions
 *           are only locally suboptimal, i.e. not so bad. I'll defer optimizing
 *           these local dependent conditions later...
 *        -- note this is also related to join optimizations, since we may
 *           have dependent IfThenElse0s inside maps that we could lift, with a
 *           no-op else condition. However so far I've been considering
 *           only functional 2-branch IfThenElse's.
 *        -- note that lifting dependent IfThenElses can complicate detection of
 *           nesting chains. This means our collection transformation algorithm
 *           has to work around dependent IfThenElses lifted to their
 *           dependency points.
 *        -- also, it is up to the inlining transformation to determine how
 *           to break the dependency (i.e. by code substitution, or  
 *           preserving the local binding by an enclosing function application
 *           with the composed function's body)
 *        -- furthermore there will be other AST nodes besides IfThenElses that
 *           our collection transformations will have to navigate through.
 *           Dependent IfThenElses that have been lifted to their dependent
 *           lambdas are not the major concern, since we choose to transform
 *           based on the presence of a RHS collection chain (i.e.
 *           collop(...,collop(...)) ), and whether the inner (RHS) collection
 *           op function is selective. Thus we do not care about the outer
 *           collection function. The collection transform algorithm will
 *           recursively descend down that branch, jumping over
 *           non-collection ops.
 *        -- ISSUE: the hard part is when the RHS collection op is masked, e.g.
 *           in both branches of an IfThenElse, where we would have to detect
 *           equivalent branches... we cannot optimize this for now.
 *        -- the only other expression that masks a collection op is a block,
 *           where the return value is a collection op. everything else is
 *           either semantically not a collection op, or cannot have any
 *           nested collection ops lifted.
 *  
 *      ++ the conclusion is: we can do all lambda and conditional lifting
 *         prior to collection optimizations.
 *
 *    -- what about inlining composed functions? do we defer this until after
 *       all collection transformations since these only monotonically compose?
 *      ++ the question is whether inlining can lead to further collection
 *         transformations...  
 *      ++ the collection transformation algorithm will have to navigate
 *         around other expressions anyway, so what additional transforms
 *         could there be that aren't already matched?
 *      ++ if the substituted body itself contains collection operations, these
 *         could be matched for further optimization, potentially customized
 *         at each invocation point
 *      ++ consider map(f,map(g=lambda x.map(h,c2),c1)). we would want to
 *         inline the function body of g into f to apply further collection
 *         optimizations when recurring into the new f's body.
 *      ++ thus whenever we compose, we inline as deeply as possible, 
 *         substituting all instances of the composed function body
 *        -- we can extend this later to be more efficient if needs be
 *      ++ however note that M3 programs do not contain deeply nested *RHS*
 *         collections since maps are at most two-levels.
 *)

(* Functional optimizations
 * -- function composition: I think this currently has the most scope for
 *    actually impacting our code.
 *   ++ map(f,map(g,c)) => compose(f = lambda, g = lambda) = ...
 *     -- should we separate the case when f is nested, or implement with a
 *        single function, and rely on inlining to simplify the nested case?
 *     -- I think we should have a simple compose function, and do the deeper
 *        transformations with inlining
 *   ++ agg(f,i,map(g,c)) => compose(f = assoc_lambda, g = lambda) = ...
 *   ++ map(f,gbagg(g,i,c)) => compose(f = lambda, g = assoc_lambda) = ...
 *
 *
 * -- inlining transforms
 *   ++ in general, if there is only a single usage of a var in a lambda, we
 *      should inline any applications of that lambda
 *   ++ how does inlining work side-by-side w/ function composition? i.e. after
 *      we compose functions, should we always inline? DONE: yes, for now,
 *      until we want to optimize multiple invocations.
 *   ++ see the notes above about dependency breaking. this is related to
 *      multiple invocations of the substituted body and efficiency
 *
 *   ++ the interesting compositions are for nested map chains and aggregate
 *      pushdown on an RHS nested map
 *
 *     -- overall, the major simplification is that there are no arity changes
 *        any more for nested maps or aggregates. Instead we do tuple binding
 *        for substitutions wherever necessary. 
 *
 *     -- map(f=lambda x.map(g=lambda y.gb,c2),map(h=lambda z. hb, c1))
 *        => map(f'=lambda z.app(f=lambda x.map(g=lambda y.gb,c2),hb),c1)
 *        => map(f'=lambda z.sub[x->hb](map(g=lambda y.gb,c2)),c1)
 *        => map(f'=lambda z.map(g'=lambda y.sub[x->hb](gb),sub[x->hb](c2)),c1)
 *       ++ note the nested function g has its body transformed, but not its
 *          signature (it is still g' : y -> _)
 *       ++ this case does not change any internal collection depth, and
 *          still requires an outer flattening to yield a collection of tuples
 *
 *     -- the function arity complications previsouly came from our use of
 *        nested lambdas as multivariate functions. the examples below hide
 *        this since we are not considering tuples above, which would lead to
 *        different types for x,z, and would require the substitution to
 *        perform tuple binding rather than just using the tuple hb...
 *       ++ how can we inline while performing tuple binding as necessary?
 *       ++ the key step is in changing from a function application of the
 *          body hb above, into a code substitution of x->hb. Here x will be
 *          an arg type, and if it is a tuple arg, we must substitute each
 *          field of x with the appropriate field from hb.
 *
 *     --  I previously did this for a 3-way join to a 3-way product.
 *         Let's recreate that case.
 *        map(f=lambda v.map(g=lambda w.gb,c1),
 *            map(h=lambda x.map(i=lambda y.ib, c2), map(j=lambda z.jb, c0)))
 *        => map(f=lambda v.map(g=lambda w.gb,c1),
 *            map(h'=lambda z.app(lambda x.map(i=lambda y.ib, c2), jb), c0))
 *        => map(f=lambda v.map(g=lambda w.gb,c1),
 *            map(h'=lambda z.map(i=lambda y.sub[x->jb](ib), sub[x->jb](c2)), c0))
 *        => map(f'=lambda z.app(lambda v.map(g=lambda w.gb,c1),
 *            map(i=lambda y.sub[x->jb](ib), sub[x->jb](c2))), c0)
 *        => map(f'=lambda z.map(g'=lambda w.sub[v->mc2](gb),sub[v->mc2](c1)),c0)
 *           where mc1 = map(i=lambda y.sub[x->jb](ib), sub[x->jb](c2))
 *
 *       ++ above, if there is no flatten prior to map(h,...) in the original
 *          expression, the variable v is bound to a collection of tuples.
 *       ++ note that types are still consistent through substitution, that is
 *          v is replaced with a map yieled a collection of tuples
 *       ++ the interesting part is the outer map function f no longer takes
 *          a collection arg but a tuple arg, but at the expense of a map
 *          operation added to the function g.
 *       ++ what does the code look like after applying sub[v->mc2](gb) ? is
 *          there a normalized form we should use here (i.e. lambda's at the
 *          top, rather than at every occurrence?). Remember that the goal is
 *          to pipeline here, and remove any intermediate data structure
 *          construction, such as would occur when binding mc1 to v in a
 *          function application.
 *       ++ the substitution will achieve this since presumably gb does some
 *          form of tuple construction containing a collection, for example
 *          gb=map(lambda a.tuple(a,w),v)
 *          => map(lambda a.tuple(a,w), map(...))
 *          => map(lambda y.compose(tuple(a,w),sub[x->jb](ib)), sub[x->jb](c2))
 *          => map(lambda y.sub[a->sub[x->jb](ib)](tuple(a,w)), sub[x->jb](c2))
 *       ++ do we really want to defer subsitutions as seen above? what would
 *          we gain from this? it may be useful for backtracking on inlining
 *          decisions, but there's no point to this for now since we only
 *          apply the above in a 3-way product scenario
 *
 *     -- does the above inlining/substitution affect the collection depth of
 *        the program, and require additional flattening? DONE: yes, but in
 *        a typesafe way, and we *want* this to remove intermediates
 *       ++ see comments in the case of a 3-way join. the key part is the
 *          form of the code when we add a map operation to a previously flat
 *          function.
 *
 *     -- agg(f=aclambda v,w.fb,i,map(g=lambda x.map(h=lambda y.hb,c2),c1))
 *        => agg(f=aclambda v,w.fb,i,
 *             map(g=lambda x.(agg(f=aclambda v,w.fb,0,map(h=lambda y.hb,c2))),c1))
 *        => agg(f=aclambda v,w.fb,i,
 *             map(g=lambda x.(agg(f'=aclambda y,w.sub[v->hb](fb),0,c2)),c1))
 *        => agg(f''=aclambda x,w.sub[v->mc2](fb),i,c1)
 *           where mc2=agg(f'=aclambda y,w.sub[v->hb](fb),0,c2)
 *
 *       ++ note we explicitly need to check for a nested rhs to dup the agg,
 *          otherwise just composing the outer rhs map function yields: 
 *        => agg(f'=aclambda x.w.app(lambda v.fb,map(h=lambda y.hb,c2)),i,c1)
 *        => agg(f'=aclambda x.w.sub[v->map(h=lambda y.hb,c2)](fb),i,c1)
 *
 *          where there is only one instance of an agg, and thus no partial
 *          aggregation going on
 *
 *       ++ do we want to pipeline aggregation, or simply compute binding for
 *          v->mc2 once? since mc2 performs data reduction, its intermediates
 *          would be smaller than its inputs.
 *       ++ note there has to be a flatten enclosing the map here, otherwise
 *          we're expected to aggregate double collections, whereas the only
 *          current associative function we have is sum.
 *       ++ TODO: overall we still have to decide how we want to handle flatten,
 *          i.e. whether we want to change map and its function f to have ext
 *          semantics, or explicitly add flatten constructs where necessary
 *         -- I'm in favour of the latter.
 *       ++ TODO: in this case, this rule has to explicitly be defined in terms
 *          of flatten, and we also need to reconsider the other transforms to
 *          handle flattens   
 *
 *     -- note the above substitutions can also perform dead code elimination,
 *        where if a substituted variable is not used, the code to be subbed
 *        is removed from the program, which may be effective for nested 
 *        subbing as in the 3-way join.
 *)


open M3
open K3.SR

let var_counter = ref 0
let gen_var_sym() = incr var_counter; "var"^(string_of_int (!var_counter))

(* accessors *)
let get_fun_parts e = match e with
    | Lambda(x,b) -> x,b | _ -> failwith "invalid function"

let get_assoc_fun_parts e = match e with
    | AssocLambda(x,y,b) -> x,y,b
    | _ -> failwith "invalid assoc function"

let get_arg_vars a = match a with
    | AVar(v,_) -> [v]
    | ATuple(vt_l) -> List.map fst vt_l

let get_arg_vars_w_types a = match a with
    | AVar(v,t) -> [v,t]
    | ATuple(vt_l) -> vt_l

let get_fun_vars e = get_arg_vars (fst (get_fun_parts e))

let get_bindings e = match e with
    | Lambda(x,_) -> get_arg_vars x
    | AssocLambda(x,y,_) -> (get_arg_vars x)@(get_arg_vars y)
    | _ -> []

let get_if_parts e = match e with
    | IfThenElse(pe,te,ee) -> pe,te,ee
    | _ -> failwith "invalid IfThenElse"

(* TODO: for all these collection accessors, extract an rhs collection if it's
 * masked by an IfThenElse yet the underlying collection beneath both branches
 * is the same. *)
let unmask cexpr = cexpr

let get_map_parts e = match e with
    | Map(fn,c) -> fn,(unmask c)
    | _ -> failwith "invalid map expression"

let get_agg_parts e = match e with
    | Aggregate(agg_f, init, agg_c) -> agg_f, init, (unmask agg_c)
    | _ -> failwith "invalid aggregate expression"  

let get_gb_agg_parts e = match e with
    | GroupByAggregate(agg_f, init, gb_f, agg_c) ->
        agg_f, init, gb_f, (unmask agg_c)
    | _ -> failwith "invalid group by aggregation"


let get_free_vars e bindings =
    let add_binding bindings e = match e with
        | Lambda(arg_e,_) -> bindings@(get_arg_vars arg_e)
        | AssocLambda(arg1_e,arg2_e,_) ->
            bindings@(get_arg_vars arg1_e)@(get_arg_vars arg2_e)
        | _ -> bindings
    in
    let is_free_var bindings bu_acc e = match e with
        | Var(id,_) -> if not(List.mem id bindings) then [id] else []
        | _ -> List.flatten (List.flatten bu_acc)
    in fold_expr is_free_var add_binding bindings [] e

(* substitute *)
let substitute_args renamings arg =
    let sub_aux (v,t) =
        if List.mem_assoc v renamings
        then (snd(List.assoc v renamings),t) else (v,t)
    in
    begin match arg with
    | AVar(v,t) -> let x,y = sub_aux (v,t) in AVar(x,y)
    | ATuple(vt_l) -> ATuple(List.map sub_aux vt_l)
    end

let substitute (arg_to_sub, sub_expr) expr =
    let vars_to_sub = match arg_to_sub with
        | AVar(v,_) -> [v,sub_expr]
        | ATuple(vt_l) ->
            begin match sub_expr with
            | Tuple(t) -> List.map2 (fun (v,_) e -> v,e) vt_l t
            | IfThenElse(p,Tuple(tt),Tuple(et)) ->
                let tef = List.combine tt et in
                List.map2 (fun (v,_) (t,e) -> v,IfThenElse(p,t,e)) vt_l tef
            | _ -> failwith ("invalid tuple binding: "^(string_of_expr sub_expr)) 
            end
    in
    (* Remove vars from substitutions when descending through lambdas
     * binding the same variable. Don't descend further if there are no
     * substitutions left. *)
    let remove_var subs e =
        let avl = match e with
        | Lambda(arg,body) -> get_arg_vars arg
        | AssocLambda(arg1,arg2,body) -> (get_arg_vars arg1)@(get_arg_vars arg2)
        | _ -> []
        in if avl = [] then subs
           else List.filter (fun (v,_) -> not(List.mem v avl)) subs
    in
    let sub_aux subs parts e = match e with
        | Var(id,t) ->
            (* sub if possible *)
            if List.mem_assoc id subs then List.assoc id subs else e
        | _ -> rebuild_expr e parts
    in fold_expr sub_aux remove_var vars_to_sub (Const (CFloat(0.0))) expr

(* Lambda and assoc lambda composition *)
let compose f g =
    let f_args, f_body = get_fun_parts f in
    let g_args, g_body = get_fun_parts g
    in Lambda(g_args, substitute (f_args, g_body) f_body)
    
let compose_assoc assoc_f g =
    let f_arg1, f_arg2, f_body = get_assoc_fun_parts assoc_f in
    let g_args, g_body = get_fun_parts g in
    let collisions =
       let f2_vars = get_arg_vars_w_types f_arg2 in
       let g_vars = get_arg_vars_w_types g_args in
       List.filter (fun (v,t) -> List.mem_assoc v f2_vars) g_vars
    in
    let renamings =
        List.map (fun (v,t) -> (v,(t,gen_var_sym()))) collisions in
    let new_args = substitute_args renamings f_arg2 in
    let new_f_body =
        let non_coll_f_body = List.fold_left (fun acc (v,(t,nv)) ->
          substitute (AVar(v,t), Var(nv,t)) acc) f_body renamings
        in substitute (f_arg1, g_body) non_coll_f_body
    in AssocLambda(g_args, new_args, new_f_body)
(*
    let new_args = substitute_args renamings g_args in
    let new_g_body = List.fold_left (fun acc (v,(t,nv)) ->
        substitute (AVar(v,t), Var(nv,t)) acc) g_body renamings in 
    let new_body = substitute (f_arg1, new_g_body) f_body
    in AssocLambda(new_args, f_arg2, new_body)
*)

(* selective_expr:
 * -- returns if expr is an aggregate, or a map with a selective lambda (i.e. a
 *    lambda contains a predicate dependent on the function argument)
 *)
let selective_expr expr =
    let vars = match expr with Map(f,_) -> get_fun_vars f | _ -> [] in
    let aux _ part_selvars e =
        let rv = 
           let selvars = List.flatten part_selvars in
           (List.mem true (List.map fst selvars),
            List.flatten (List.map snd selvars))
        in 
        match e with
        | Var(id,_) -> (false, [id])
        | Aggregate _ -> (true, [])
        | GroupByAggregate _ -> (true, [])
        (* For Maps we only care if this map_f is selective. If the collection
         * is not, then transformation of this Map will perform optimization *)
        | Map _ -> List.hd (List.hd part_selvars) 
        | IfThenElse0 _ ->
	        let (subsel,subvars) = rv in
	        let sel = (Util.ListAsSet.inter subvars vars) <> []
	        in if subsel || sel then (true, []) else (false, subvars)  
	    | _ -> rv
    in fst (fold_expr aux (fun x _ -> x) None (false,[]) expr)

(* TODO: better nested map detection *)
let nested_map map_f = match map_f with
    | Lambda(_,Map _) -> true
    | _ -> false

let rec inline_collection_functions substitutions expr =
  let recur = inline_collection_functions in
  let rebind subs vt arg =
    let ns = if List.mem_assoc vt subs then List.remove_assoc vt subs else subs
    in (vt,arg)::ns
  in
  begin match expr with
  | Apply(Lambda(AVar(v, ((Collection _) as t)), body), arg) ->
    descend_expr (recur (rebind substitutions (v,t) 
                           (descend_expr (recur substitutions) arg))
                 ) body
  | Var(v,t) -> if List.mem_assoc (v,t) substitutions
                then List.assoc (v,t) substitutions else expr
  | _ -> descend_expr (recur substitutions) expr
  end

(* Performs dependency tests at lambda-if boundaries *)
(* Avoids spinning on reordering at if-chains
 * -- if-reordering-spinning can be an arbitrarily deep problem, thus
 *    no pattern can match it (i.e. if we prevent an n-level reorder spin,
 *    we can still spin on a n+1-level if-chain)
 * -- the correct way to detect this is based on dependency sets of
 *    if-stmts, and only lift nested ifs when they have a strictly simpler
 *    dependency set.
 * -- a dependency set is the intersection of the bound variables, and
 *    variables used in the if's predicate. Thus we need to pass along
 *    bound variables, i.e. trigger vars and variables bound by lambdas.
 *)
let rec lift_ifs bindings expr =
    let lift_branches e =
        let rec expand_children acc_branches rem_branches
                                (branch : expr_t list) acc_branch : expr_t =
            let recex = expand_children acc_branches rem_branches in
            begin match branch with
            | [] -> expand_branch (acc_branches@[acc_branch]) rem_branches
            | h::t ->
                begin match h with
                | IfThenElse(pe,te,ee) ->  
	                let pe,te,ee = get_if_parts h in
	                let tev = recex t (acc_branch@[te]) in
	                let eev = recex t (acc_branch@[ee])
	                in IfThenElse(pe,tev,eev)
                | _ -> recex t (acc_branch@[h])
                end
            end
        and expand_branch (acc_branches : expr_t list list)
                          (rem_branches : expr_t list list) : expr_t =
            match rem_branches with
            | [] -> rebuild_expr e acc_branches
            | h::t -> expand_children acc_branches t h []
        in expand_branch [] (get_branches e) 
    in
    (* returns existing bindings (i.e. those passed to lift-ifs) used by e *)
    let get_dependencies e = 
        let vars = get_free_vars e [] in Util.ListAsSet.inter vars bindings
    in
    (* returns if d1 is a strict subset of d2 *)  
    let simpler_dependencies pe pe2 =
        let d1 = get_dependencies pe in
        let d2 = get_dependencies pe2 in
        (Util.ListAsSet.subset d1 d2) && not(Util.ListAsSet.subset d2 d1)
    in
    (* if expression is dependent on arg, returns new bindings, otherwise nothing *)
    let arg_uses arg_l e =
        let vars = get_free_vars e [] in
        let bindings = List.flatten (List.map get_arg_vars arg_l) in
        if Util.ListAsSet.inter bindings vars = []
        then Util.ListAsSet.no_duplicates bindings else [] 
    in
    (* returns expression * new bindings *)
    let simplify e =
        begin match e with
        | Lambda(arg_e, IfThenElse(pe,te,ee)) ->
            (* if pe is not dependent on arg_e, lift, otherwise nop *)
            let new_bindings = arg_uses [arg_e] pe in
            let new_e =
                if new_bindings = [] then e
                else IfThenElse(pe, Lambda(arg_e, te), Lambda(arg_e, ee))
            in (new_e, new_bindings)

        | AssocLambda(arg1_e,arg2_e,IfThenElse(pe,te,ee)) ->
            let new_bindings = arg_uses [arg1_e; arg2_e] pe in
            let new_e =
                if new_bindings = [] then e
                else IfThenElse(pe, AssocLambda(arg1_e,arg2_e,te),
                                    AssocLambda(arg1_e,arg2_e,te))
            in (new_e, new_bindings)

        (* For if-chains, we just want the next level to have the same
         * predicate. *)
        | IfThenElse(pe,te,ee) ->
            begin match (te,ee) with
            | IfThenElse(pe2,te2,ee2), IfThenElse(pe3,te3,ee3) when pe2=pe3 ->
                if pe = pe2 then (IfThenElse(pe,te2,ee3), [])
                else if simpler_dependencies pe2 pe then
                    let new_sub_e2 = IfThenElse(pe, te2, ee2) in
                    let new_sub_e3 = IfThenElse(pe, te3, ee3) 
                    in (IfThenElse(pe2, new_sub_e2, new_sub_e3), [])
                else (descend_expr (lift_ifs bindings) e,[])
            | _ -> (descend_expr (lift_ifs bindings) e,[])
            end
        | _ ->
            let new_bindings = get_bindings e in
            let r = lift_branches expr in
            (* if children have no ifs, descend and try w/ grandchildren *)
            if r <> expr then (r, [])
            else (descend_expr (lift_ifs (bindings@new_bindings)) expr, new_bindings) 
        end
    in
    let fixpoint old_expr (new_expr, new_bindings) =
        if old_expr = new_expr then new_expr
        else lift_ifs (bindings@new_bindings) new_expr
    in fixpoint expr (simplify expr)     


(* TODO: pairwith2, deep flattens *)
let rec simplify_collections expr =
    let recur = simplify_collections in
    let simplify expr =
    begin match expr with
    | Map(map_f, Singleton(e)) -> Singleton(Apply(map_f, e))
    | Flatten(Singleton(c)) -> c
    | Map(map_f, Flatten c) ->
        let mapf_arg, _ = get_map_parts map_f in
        let mapf_arg_t = match fst (get_fun_parts mapf_arg) with
            | AVar(_,t) -> t
            | ATuple(vt_l) -> TTuple(List.map snd vt_l)
        in
        let v,v_t = gen_var_sym(), Collection(Collection(mapf_arg_t))
        in Flatten(Map(Lambda(AVar(v,v_t), Map(map_f, Var(v,v_t))), c))

    | Map(map_f, (Map(_,_) as rmap)) when not(selective_expr rmap) ->
        let rmap_f, rmap_c = get_map_parts rmap in
        let new_map_f = compose map_f rmap_f
        in Map(new_map_f, rmap_c)

    | Aggregate((AssocLambda _ as agg_f),init, (Map _ as rmap)) ->

        (* v,w,fb *)
        let aggf_arg1, aggf_arg2, aggf_body = get_assoc_fun_parts agg_f in

        (* g,c1 *)
        let rmap_f, rmap_c = get_map_parts rmap in
        if nested_map rmap_f then
            
            (* create duplicate aggregate for nested colln *)
            (* TODO: handle decomposition errors, or move retrieval into 
             * nested_map function. *)
            (* x, map(h,c2) *)
            let rmapf_args, rmapf_body = get_fun_parts rmap_f in
            
            (* h,c2 *)
            let nmap_f, nmap_body = get_map_parts rmapf_body in
            
            (* y, hb *)
            let nmapf_args, nmapf_body = get_fun_parts nmap_f in
            
            let dup_agg_f =
                let dup_body = substitute (aggf_arg1, nmapf_body) aggf_body in
                AssocLambda(nmapf_args,aggf_arg2,dup_body) in
            let dup_init = Const(CFloat(0.0)) in

            (* mc2 *)
            let new_rmapf_body =
                recur (Aggregate(dup_agg_f, dup_init, nmap_body))
            in
            let new_rmapf = Lambda(rmapf_args, new_rmapf_body) in
            let new_agg_f = compose_assoc agg_f new_rmapf
            in Aggregate(new_agg_f, init, rmap_c)
        else
            let new_agg_f = compose_assoc agg_f rmap_f
            in Aggregate(new_agg_f, init, rmap_c)

    | GroupByAggregate((AssocLambda _ as agg_f),i,gb_f, (Map _ as rmap)) ->
        (* TODO: group by function optimizations *)
        (* For now, simply compose rhs map fn with group-by fn. Presumably
         * there are some nested optimizations of such group-bys we can perform
         * just as with aggregates above. *)
        let rmap_f, rmap_c = get_map_parts rmap in
        let new_agg_f = compose_assoc agg_f rmap_f in
        let new_gb_f = compose gb_f rmap_f
        in GroupByAggregate(new_agg_f,i,new_gb_f,rmap_c) 

    | _ -> descend_expr recur expr

    end
    in 
    (* Fixpoint *)
    let fixpoint expr new_expr =
        if new_expr = expr then expr else recur new_expr
    in fixpoint expr (simplify expr)