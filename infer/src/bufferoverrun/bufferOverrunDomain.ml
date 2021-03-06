(*
 * Copyright (c) 2016-present, Programming Research Laboratory (ROPAS)
 *                             Seoul National University, Korea
 * Copyright (c) 2017-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open AbsLoc
open! AbstractDomain.Types
module F = Format
module L = Logging
module Relation = BufferOverrunDomainRelation
module Trace = BufferOverrunTrace
module TraceSet = Trace.Set

module Val = struct
  type astate =
    { itv: Itv.astate
    ; sym: Relation.Sym.astate
    ; powloc: PowLoc.astate
    ; arrayblk: ArrayBlk.astate
    ; offset_sym: Relation.Sym.astate
    ; size_sym: Relation.Sym.astate
    ; traces: TraceSet.t
    ; represents_multiple_values: bool }

  type t = astate

  let bot : t =
    { itv= Itv.bot
    ; sym= Relation.Sym.bot
    ; powloc= PowLoc.bot
    ; arrayblk= ArrayBlk.bot
    ; offset_sym= Relation.Sym.bot
    ; size_sym= Relation.Sym.bot
    ; traces= TraceSet.empty
    ; represents_multiple_values= false }


  let pp fmt x =
    let relation_sym_pp fmt sym =
      if Option.is_some Config.bo_relational_domain then F.fprintf fmt ", %a" Relation.Sym.pp sym
    in
    let trace_pp fmt traces =
      if Config.bo_debug >= 1 then F.fprintf fmt ", %a" TraceSet.pp traces
    in
    let represents_multiple_values_str = if x.represents_multiple_values then "M" else "" in
    F.fprintf fmt "%s(%a%a, %a, %a%a%a%a)" represents_multiple_values_str Itv.pp x.itv
      relation_sym_pp x.sym PowLoc.pp x.powloc ArrayBlk.pp x.arrayblk relation_sym_pp x.offset_sym
      relation_sym_pp x.size_sym trace_pp x.traces


  let sets_represents_multiple_values : represents_multiple_values:bool -> t -> t =
   fun ~represents_multiple_values x -> {x with represents_multiple_values}


  let unknown_from : callee_pname:_ -> location:_ -> t =
   fun ~callee_pname ~location ->
    let traces = TraceSet.singleton (Trace.UnknownFrom (callee_pname, location)) in
    { itv= Itv.top
    ; sym= Relation.Sym.top
    ; powloc= PowLoc.unknown
    ; arrayblk= ArrayBlk.unknown
    ; offset_sym= Relation.Sym.top
    ; size_sym= Relation.Sym.top
    ; traces
    ; represents_multiple_values= false }


  let ( <= ) ~lhs ~rhs =
    if phys_equal lhs rhs then true
    else
      Itv.( <= ) ~lhs:lhs.itv ~rhs:rhs.itv
      && Relation.Sym.( <= ) ~lhs:lhs.sym ~rhs:rhs.sym
      && PowLoc.( <= ) ~lhs:lhs.powloc ~rhs:rhs.powloc
      && ArrayBlk.( <= ) ~lhs:lhs.arrayblk ~rhs:rhs.arrayblk
      && Relation.Sym.( <= ) ~lhs:lhs.offset_sym ~rhs:rhs.offset_sym
      && Relation.Sym.( <= ) ~lhs:lhs.size_sym ~rhs:rhs.size_sym
      && Bool.( <= ) lhs.represents_multiple_values rhs.represents_multiple_values


  let widen ~prev ~next ~num_iters =
    if phys_equal prev next then prev
    else
      { itv= Itv.widen ~prev:prev.itv ~next:next.itv ~num_iters
      ; sym= Relation.Sym.widen ~prev:prev.sym ~next:next.sym ~num_iters
      ; powloc= PowLoc.widen ~prev:prev.powloc ~next:next.powloc ~num_iters
      ; arrayblk= ArrayBlk.widen ~prev:prev.arrayblk ~next:next.arrayblk ~num_iters
      ; offset_sym= Relation.Sym.widen ~prev:prev.offset_sym ~next:next.offset_sym ~num_iters
      ; size_sym= Relation.Sym.widen ~prev:prev.size_sym ~next:next.size_sym ~num_iters
      ; traces= TraceSet.join prev.traces next.traces
      ; represents_multiple_values=
          prev.represents_multiple_values || next.represents_multiple_values }


  let join : t -> t -> t =
   fun x y ->
    if phys_equal x y then x
    else
      { itv= Itv.join x.itv y.itv
      ; sym= Relation.Sym.join x.sym y.sym
      ; powloc= PowLoc.join x.powloc y.powloc
      ; arrayblk= ArrayBlk.join x.arrayblk y.arrayblk
      ; offset_sym= Relation.Sym.join x.offset_sym y.offset_sym
      ; size_sym= Relation.Sym.join x.size_sym y.size_sym
      ; traces= TraceSet.join x.traces y.traces
      ; represents_multiple_values= x.represents_multiple_values || y.represents_multiple_values }


  let get_itv : t -> Itv.t = fun x -> x.itv

  let get_sym : t -> Relation.Sym.astate = fun x -> x.sym

  let get_sym_var : t -> Relation.Var.t option = fun x -> Relation.Sym.get_var x.sym

  let get_pow_loc : t -> PowLoc.t = fun x -> x.powloc

  let get_array_blk : t -> ArrayBlk.astate = fun x -> x.arrayblk

  let get_array_locs : t -> PowLoc.t = fun x -> ArrayBlk.get_pow_loc x.arrayblk

  let get_all_locs : t -> PowLoc.t = fun x -> PowLoc.join x.powloc (get_array_locs x)

  let get_offset_sym : t -> Relation.Sym.astate = fun x -> x.offset_sym

  let get_size_sym : t -> Relation.Sym.astate = fun x -> x.size_sym

  let get_traces : t -> TraceSet.t = fun x -> x.traces

  let of_itv ?(traces = TraceSet.empty) itv = {bot with itv; traces}

  let of_int n = of_itv (Itv.of_int n)

  let of_big_int n = of_itv (Itv.of_big_int n)

  let of_loc : Loc.t -> t = fun x -> {bot with powloc= PowLoc.singleton x}

  let of_pow_loc ~traces powloc = {bot with powloc; traces}

  let of_array_alloc :
      Allocsite.t -> stride:int option -> offset:Itv.t -> size:Itv.t -> traces:TraceSet.t -> t =
   fun allocsite ~stride ~offset ~size ~traces ->
    let stride = Option.value_map stride ~default:Itv.nat ~f:Itv.of_int in
    { bot with
      arrayblk= ArrayBlk.make allocsite ~offset ~size ~stride
    ; offset_sym= Relation.Sym.of_allocsite_offset allocsite
    ; size_sym= Relation.Sym.of_allocsite_size allocsite
    ; traces }


  let modify_itv : Itv.t -> t -> t = fun i x -> {x with itv= i}

  let make_sym :
         ?unsigned:bool
      -> Loc.t
      -> Typ.Procname.t
      -> Itv.SymbolTable.t
      -> Itv.SymbolPath.partial
      -> Counter.t
      -> Location.t
      -> t =
   fun ?(unsigned = false) loc pname symbol_table path new_sym_num location ->
    let represents_multiple_values = Itv.SymbolPath.represents_multiple_values path in
    { bot with
      itv= Itv.make_sym ~unsigned pname symbol_table (Itv.SymbolPath.normal path) new_sym_num
    ; sym= Relation.Sym.of_loc loc
    ; traces= TraceSet.singleton (Trace.SymAssign (loc, location))
    ; represents_multiple_values }


  let unknown_bit : t -> t = fun x -> {x with itv= Itv.top; sym= Relation.Sym.top}

  let neg : t -> t = fun x -> {x with itv= Itv.neg x.itv; sym= Relation.Sym.top}

  let lnot : t -> t = fun x -> {x with itv= Itv.lnot x.itv |> Itv.of_bool; sym= Relation.Sym.top}

  let lift_itv : (Itv.t -> Itv.t -> Itv.t) -> ?f_trace:_ -> t -> t -> t =
   fun f ?(f_trace = TraceSet.join) x y ->
    {bot with itv= f x.itv y.itv; traces= f_trace x.traces y.traces}


  let has_pointer : t -> bool = fun x -> not (PowLoc.is_bot x.powloc && ArrayBlk.is_bot x.arrayblk)

  let lift_cmp_itv : (Itv.t -> Itv.t -> Boolean.t) -> t -> t -> t =
   fun f x y ->
    let b = if has_pointer x || has_pointer y then Boolean.Top else f x.itv y.itv in
    let itv = Itv.of_bool b in
    {bot with itv; traces= TraceSet.join x.traces y.traces}


  let plus_a = lift_itv Itv.plus

  let minus_a = lift_itv Itv.minus

  let get_iterator_itv : t -> t = fun i -> {bot with itv= Itv.get_iterator_itv i.itv}

  let mult = lift_itv Itv.mult

  let div = lift_itv Itv.div

  let mod_sem = lift_itv Itv.mod_sem

  let shiftlt = lift_itv Itv.shiftlt

  let shiftrt = lift_itv Itv.shiftrt

  let band_sem = lift_itv Itv.band_sem

  let lt_sem : t -> t -> t = lift_cmp_itv Itv.lt_sem

  let gt_sem : t -> t -> t = lift_cmp_itv Itv.gt_sem

  let le_sem : t -> t -> t = lift_cmp_itv Itv.le_sem

  let ge_sem : t -> t -> t = lift_cmp_itv Itv.ge_sem

  let eq_sem : t -> t -> t = lift_cmp_itv Itv.eq_sem

  let ne_sem : t -> t -> t = lift_cmp_itv Itv.ne_sem

  let land_sem : t -> t -> t = lift_cmp_itv Itv.land_sem

  let lor_sem : t -> t -> t = lift_cmp_itv Itv.lor_sem

  (* TODO: get rid of those cases *)
  let warn_against_pruning_multiple_values : t -> t =
   fun x ->
    if x.represents_multiple_values && Config.write_html then
      L.d_printfln ~color:Pp.Red "Pruned %a that represents multiple values" pp x ;
    x


  let lift_prune1 : (Itv.t -> Itv.t) -> t -> t =
   fun f x -> warn_against_pruning_multiple_values {x with itv= f x.itv}


  let lift_prune2 :
         (Itv.t -> Itv.t -> Itv.t)
      -> (ArrayBlk.astate -> ArrayBlk.astate -> ArrayBlk.astate)
      -> t
      -> t
      -> t =
   fun f g x y ->
    warn_against_pruning_multiple_values
      { x with
        itv= f x.itv y.itv
      ; arrayblk= g x.arrayblk y.arrayblk
      ; traces= TraceSet.join x.traces y.traces }


  let prune_eq_zero : t -> t = lift_prune1 Itv.prune_eq_zero

  let prune_ne_zero : t -> t = lift_prune1 Itv.prune_ne_zero

  let prune_comp : Binop.t -> t -> t -> t =
   fun c -> lift_prune2 (Itv.prune_comp c) (ArrayBlk.prune_comp c)


  let prune_eq : t -> t -> t = lift_prune2 Itv.prune_eq ArrayBlk.prune_eq

  let prune_ne : t -> t -> t = lift_prune2 Itv.prune_ne ArrayBlk.prune_ne

  let is_pointer_to_non_array x = (not (PowLoc.is_bot x.powloc)) && ArrayBlk.is_bot x.arrayblk

  (* In the pointer arithmetics, it returns top, if we cannot
     precisely follow the physical memory model, e.g., (&x + 1). *)
  let lift_pi : (ArrayBlk.astate -> Itv.t -> ArrayBlk.astate) -> t -> t -> t =
   fun f x y ->
    let traces = TraceSet.join x.traces y.traces in
    if is_pointer_to_non_array x then {bot with itv= Itv.top; traces}
    else {bot with arrayblk= f x.arrayblk y.itv; traces}


  let plus_pi : t -> t -> t = fun x y -> lift_pi ArrayBlk.plus_offset x y

  let minus_pi : t -> t -> t = fun x y -> lift_pi ArrayBlk.minus_offset x y

  let minus_pp : t -> t -> t =
   fun x y ->
    let itv =
      if is_pointer_to_non_array x && is_pointer_to_non_array y then Itv.top
      else ArrayBlk.diff x.arrayblk y.arrayblk
    in
    {bot with itv; traces= TraceSet.join x.traces y.traces}


  let get_symbols : t -> Itv.SymbolSet.t =
   fun x -> Itv.SymbolSet.union (Itv.get_symbols x.itv) (ArrayBlk.get_symbols x.arrayblk)


  let normalize : t -> t =
   fun x -> {x with itv= Itv.normalize x.itv; arrayblk= ArrayBlk.normalize x.arrayblk}


  let subst : t -> Bounds.Bound.eval_sym * (Symb.Symbol.t -> TraceSet.t) -> Location.t -> t =
   fun x (eval_sym, trace_of_sym) location ->
    let symbols = get_symbols x in
    let traces_caller =
      Itv.SymbolSet.fold
        (fun symbol traces -> TraceSet.join (trace_of_sym symbol) traces)
        symbols TraceSet.empty
    in
    let traces = TraceSet.call location ~traces_caller ~traces_callee:x.traces in
    {x with itv= Itv.subst x.itv eval_sym; arrayblk= ArrayBlk.subst x.arrayblk eval_sym; traces}
    (* normalize bottom *)
    |> normalize


  let add_trace_elem : Trace.elem -> t -> t =
   fun elem x ->
    let traces = TraceSet.add_elem elem x.traces in
    {x with traces}


  let add_assign_trace_elem location x = add_trace_elem (Trace.Assign location) x

  let set_array_length : Location.t -> length:t -> t -> t =
   fun location ~length v ->
    { v with
      arrayblk= ArrayBlk.set_length length.itv v.arrayblk
    ; traces= TraceSet.add_elem (Trace.ArrDecl location) length.traces }


  let set_array_stride : Z.t -> t -> t =
   fun new_stride v ->
    let stride = ArrayBlk.strideof (get_array_blk v) in
    if Itv.eq_const new_stride stride then v
    else {v with arrayblk= ArrayBlk.set_stride new_stride v.arrayblk}


  module Itv = struct
    let m1_255 = of_itv Itv.m1_255

    let nat = of_itv Itv.nat

    let one = of_itv Itv.one

    let pos = of_itv Itv.pos

    let top = of_itv Itv.top

    let zero = of_itv Itv.zero
  end
end

module StackLocs = struct
  include AbstractDomain.FiniteSet (Loc)

  let bot = empty
end

module MemPure = struct
  include AbstractDomain.Map (Loc) (Val)

  let bot = empty

  let range : filter_loc:(Loc.t -> bool) -> astate -> Polynomials.NonNegativePolynomial.astate =
   fun ~filter_loc mem ->
    fold
      (fun loc v acc ->
        if filter_loc loc then
          v |> Val.get_itv |> Itv.range |> Itv.ItvRange.to_top_lifted_polynomial
          |> Polynomials.NonNegativePolynomial.mult acc
        else acc )
      mem Polynomials.NonNegativePolynomial.one
end

module AliasTarget = struct
  type t = Simple of Loc.t | Empty of Loc.t [@@deriving compare]

  let equal = [%compare.equal: t]

  let pp fmt = function Simple l -> Loc.pp fmt l | Empty l -> F.fprintf fmt "empty(%a)" Loc.pp l

  let of_empty l = Empty l

  let use l = function Simple l' | Empty l' -> Loc.equal l l'

  let loc_map x ~f =
    match x with
    | Simple l ->
        Option.map (f l) ~f:(fun l -> Simple l)
    | Empty l ->
        Option.map (f l) ~f:(fun l -> Empty l)


  type astate = t

  let ( <= ) ~lhs ~rhs = equal lhs rhs

  let join x y =
    assert (equal x y) ;
    x


  let widen ~prev ~next ~num_iters:_ = join prev next
end

(* Relations between values of logical variables(registers) and
   program variables

   "AliasTarget.Simple relation": Since Sil distinguishes logical and
   program variables, we need a relation for pruning values of program
   variables.  For example, a C statement "if(x){...}" is translated
   to "%r=load(x); if(%r){...}" in Sil.  At the load statement, we
   record the alias between the values of %r and x, then we can prune
   not only the value of %r, but also that of x inside the if branch.

   "AliasTarget.Empty relation": For pruning vector.size with
   vector::empty() results, we adopt a specific relation between %r
   and x, where %r=v.empty() and x=v.size.  So, if %r!=0, x is pruned
   by x=0.  On the other hand, if %r==0, x is pruned by x>=1.  *)
module AliasMap = struct
  include AbstractDomain.Map (Ident) (AliasTarget)

  let pp : F.formatter -> astate -> unit =
   fun fmt x ->
    if not (is_empty x) then
      let pp_sep fmt () = F.fprintf fmt ", @," in
      let pp1 fmt (k, v) = F.fprintf fmt "%a=%a" Ident.pp k AliasTarget.pp v in
      F.pp_print_list ~pp_sep pp1 fmt (bindings x)


  let load : Ident.t -> AliasTarget.astate -> astate -> astate = add

  let store : Loc.t -> astate -> astate =
   fun l m -> filter (fun _ y -> not (AliasTarget.use l y)) m


  let find : Ident.t -> astate -> AliasTarget.astate option = find_opt
end

module AliasRet = struct
  include AbstractDomain.Flat (AliasTarget)

  let pp : F.formatter -> astate -> unit = fun fmt x -> F.pp_print_string fmt "ret=" ; pp fmt x
end

module Alias = struct
  type astate = {map: AliasMap.astate; ret: AliasRet.astate}

  let ( <= ) ~lhs ~rhs =
    if phys_equal lhs rhs then true
    else AliasMap.( <= ) ~lhs:lhs.map ~rhs:rhs.map && AliasRet.( <= ) ~lhs:lhs.ret ~rhs:rhs.ret


  let join x y =
    if phys_equal x y then x else {map= AliasMap.join x.map y.map; ret= AliasRet.join x.ret y.ret}


  let widen ~prev ~next ~num_iters =
    if phys_equal prev next then prev
    else
      { map= AliasMap.widen ~prev:prev.map ~next:next.map ~num_iters
      ; ret= AliasRet.widen ~prev:prev.ret ~next:next.ret ~num_iters }


  let pp fmt x =
    F.fprintf fmt "@[<hov 2>{ %a%s%a }@]" AliasMap.pp x.map
      (if AliasMap.is_empty x.map then "" else ", ")
      AliasRet.pp x.ret


  let bot : astate = {map= AliasMap.empty; ret= AliasRet.empty}

  let lift_map : (AliasMap.astate -> AliasMap.astate) -> astate -> astate =
   fun f a -> {a with map= f a.map}


  let bind_map : (AliasMap.astate -> 'a) -> astate -> 'a = fun f a -> f a.map

  let find : Ident.t -> astate -> AliasTarget.astate option = fun x -> bind_map (AliasMap.find x)

  let find_ret : astate -> AliasTarget.astate option = fun x -> AliasRet.get x.ret

  let load : Ident.t -> AliasTarget.astate -> astate -> astate =
   fun id loc -> lift_map (AliasMap.load id loc)


  let store_simple : Loc.t -> Exp.t -> astate -> astate =
   fun loc e a ->
    let a = lift_map (AliasMap.store loc) a in
    match e with
    | Exp.Var l when Loc.is_return loc ->
        let update_ret retl = {a with ret= AliasRet.v retl} in
        Option.value_map (find l a) ~default:a ~f:update_ret
    | _ ->
        a


  let store_empty : Val.t -> Loc.t -> astate -> astate =
   fun formal loc a ->
    let a = lift_map (AliasMap.store loc) a in
    let locs = Val.get_all_locs formal in
    match PowLoc.is_singleton_or_more locs with
    | IContainer.Singleton loc ->
        {a with ret= AliasRet.v (AliasTarget.of_empty loc)}
    | _ ->
        a


  let remove_temp : Ident.t -> astate -> astate = fun temp -> lift_map (AliasMap.remove temp)
end

(* [PrunePairs] is a map from abstract locations to abstract values that represents pruned results
   in the latest pruning.  It uses [InvertedMap] because more pruning means smaller abstract
   states. *)
module PrunePairs = AbstractDomain.InvertedMap (Loc) (Val)

module LatestPrune = struct
  (* Latest p: The pruned pairs 'p' has pruning information (which
     abstract locations are updated by which abstract values) in the
     latest pruning.

     TrueBranch (x, p): After a pruning, the variable 'x' is assigned
     by 1.  There is no other memory updates after the latest pruning.

     FalseBranch (x, p): After a pruning, the variable 'x' is assigned
     by 0.  There is no other memory updates after the latest pruning.

     V (x, ptrue, pfalse): After two non-sequential prunings ('ptrue'
     and 'pfalse'), the variable 'x' is assigned by 1 and 0,
     respectively.  There is no other memory updates after the latest
     prunings.

     Top: No information about the latest pruning. *)
  type astate =
    | Latest of PrunePairs.astate
    | TrueBranch of Pvar.t * PrunePairs.astate
    | FalseBranch of Pvar.t * PrunePairs.astate
    | V of Pvar.t * PrunePairs.astate * PrunePairs.astate
    | Top

  let pvar_pp = Pvar.pp Pp.text

  let pp fmt = function
    | Top ->
        ()
    | Latest p ->
        F.fprintf fmt "LatestPrune: latest %a" PrunePairs.pp p
    | TrueBranch (v, p) ->
        F.fprintf fmt "LatestPrune: true(%a) %a" pvar_pp v PrunePairs.pp p
    | FalseBranch (v, p) ->
        F.fprintf fmt "LatestPrune: false(%a) %a" pvar_pp v PrunePairs.pp p
    | V (v, p1, p2) ->
        F.fprintf fmt "LatestPrune: v(%a) %a / %a" pvar_pp v PrunePairs.pp p1 PrunePairs.pp p2


  let ( <= ) ~lhs ~rhs =
    if phys_equal lhs rhs then true
    else
      match (lhs, rhs) with
      | _, Top ->
          true
      | Top, _ ->
          false
      | Latest p1, Latest p2 ->
          PrunePairs.( <= ) ~lhs:p1 ~rhs:p2
      | TrueBranch (x1, p1), TrueBranch (x2, p2)
      | FalseBranch (x1, p1), FalseBranch (x2, p2)
      | TrueBranch (x1, p1), V (x2, p2, _)
      | FalseBranch (x1, p1), V (x2, _, p2) ->
          Pvar.equal x1 x2 && PrunePairs.( <= ) ~lhs:p1 ~rhs:p2
      | V (x1, ptrue1, pfalse1), V (x2, ptrue2, pfalse2) ->
          Pvar.equal x1 x2
          && PrunePairs.( <= ) ~lhs:ptrue1 ~rhs:ptrue2
          && PrunePairs.( <= ) ~lhs:pfalse1 ~rhs:pfalse2
      | _, _ ->
          false


  let join x y =
    match (x, y) with
    | _, _ when ( <= ) ~lhs:x ~rhs:y ->
        y
    | _, _ when ( <= ) ~lhs:y ~rhs:x ->
        x
    | Latest p1, Latest p2 ->
        Latest (PrunePairs.join p1 p2)
    | FalseBranch (x1, p1), FalseBranch (x2, p2) when Pvar.equal x1 x2 ->
        FalseBranch (x1, PrunePairs.join p1 p2)
    | TrueBranch (x1, p1), TrueBranch (x2, p2) when Pvar.equal x1 x2 ->
        TrueBranch (x1, PrunePairs.join p1 p2)
    | FalseBranch (x', pfalse), TrueBranch (y', ptrue)
    | TrueBranch (x', ptrue), FalseBranch (y', pfalse)
      when Pvar.equal x' y' ->
        V (x', ptrue, pfalse)
    | V (x1, ptrue1, pfalse1), V (x2, ptrue2, pfalse2) when Pvar.equal x1 x2 ->
        V (x1, PrunePairs.join ptrue1 ptrue2, PrunePairs.join pfalse1 pfalse2)
    | _, _ ->
        Top


  let widen ~prev ~next ~num_iters:_ = join prev next

  let top = Top
end

module MemReach = struct
  type astate =
    { stack_locs: StackLocs.astate
    ; mem_pure: MemPure.astate
    ; alias: Alias.astate
    ; latest_prune: LatestPrune.astate
    ; relation: Relation.astate }

  type t = astate

  let init : t =
    { stack_locs= StackLocs.bot
    ; mem_pure= MemPure.bot
    ; alias= Alias.bot
    ; latest_prune= LatestPrune.top
    ; relation= Relation.empty }


  let ( <= ) ~lhs ~rhs =
    if phys_equal lhs rhs then true
    else
      StackLocs.( <= ) ~lhs:lhs.stack_locs ~rhs:rhs.stack_locs
      && MemPure.( <= ) ~lhs:lhs.mem_pure ~rhs:rhs.mem_pure
      && Alias.( <= ) ~lhs:lhs.alias ~rhs:rhs.alias
      && LatestPrune.( <= ) ~lhs:lhs.latest_prune ~rhs:rhs.latest_prune
      && Relation.( <= ) ~lhs:lhs.relation ~rhs:rhs.relation


  let widen ~prev ~next ~num_iters =
    if phys_equal prev next then prev
    else
      { stack_locs= StackLocs.widen ~prev:prev.stack_locs ~next:next.stack_locs ~num_iters
      ; mem_pure= MemPure.widen ~prev:prev.mem_pure ~next:next.mem_pure ~num_iters
      ; alias= Alias.widen ~prev:prev.alias ~next:next.alias ~num_iters
      ; latest_prune= LatestPrune.widen ~prev:prev.latest_prune ~next:next.latest_prune ~num_iters
      ; relation= Relation.widen ~prev:prev.relation ~next:next.relation ~num_iters }


  let join : t -> t -> t =
   fun x y ->
    { stack_locs= StackLocs.join x.stack_locs y.stack_locs
    ; mem_pure= MemPure.join x.mem_pure y.mem_pure
    ; alias= Alias.join x.alias y.alias
    ; latest_prune= LatestPrune.join x.latest_prune y.latest_prune
    ; relation= Relation.join x.relation y.relation }


  let pp : F.formatter -> t -> unit =
   fun fmt x ->
    F.fprintf fmt "StackLocs:@;%a@;MemPure:@;%a@;Alias:@;%a@;%a" StackLocs.pp x.stack_locs
      MemPure.pp x.mem_pure Alias.pp x.alias LatestPrune.pp x.latest_prune ;
    if Option.is_some Config.bo_relational_domain then
      F.fprintf fmt "@;Relation:@;%a" Relation.pp x.relation


  let is_stack_loc : Loc.t -> t -> bool = fun l m -> StackLocs.mem l m.stack_locs

  let find_opt : Loc.t -> t -> Val.t option = fun l m -> MemPure.find_opt l m.mem_pure

  let find_stack : Loc.t -> t -> Val.t = fun l m -> Option.value (find_opt l m) ~default:Val.bot

  let find_heap : Loc.t -> t -> Val.t = fun l m -> Option.value (find_opt l m) ~default:Val.Itv.top

  let find : Loc.t -> t -> Val.t =
   fun l m -> if is_stack_loc l m then find_stack l m else find_heap l m


  let find_set : PowLoc.t -> t -> Val.t =
   fun locs m ->
    let find_join loc acc = Val.join acc (find loc m) in
    PowLoc.fold find_join locs Val.bot


  let find_alias : Ident.t -> t -> AliasTarget.astate option = fun k m -> Alias.find k m.alias

  let find_simple_alias : Ident.t -> t -> Loc.t option =
   fun k m ->
    match Alias.find k m.alias with
    | Some (AliasTarget.Simple l) ->
        Some l
    | Some (AliasTarget.Empty _) | None ->
        None


  let find_ret_alias : t -> AliasTarget.astate option = fun m -> Alias.find_ret m.alias

  let load_alias : Ident.t -> AliasTarget.astate -> t -> t =
   fun id loc m -> {m with alias= Alias.load id loc m.alias}


  let store_simple_alias : Loc.t -> Exp.t -> t -> t =
   fun loc e m -> {m with alias= Alias.store_simple loc e m.alias}


  let store_empty_alias : Val.t -> Loc.t -> t -> t =
   fun formal loc m -> {m with alias= Alias.store_empty formal loc m.alias}


  let add_stack_loc : Loc.t -> t -> t = fun k m -> {m with stack_locs= StackLocs.add k m.stack_locs}

  let add_stack : Loc.t -> Val.t -> t -> t =
   fun k v m ->
    {m with stack_locs= StackLocs.add k m.stack_locs; mem_pure= MemPure.add k v m.mem_pure}


  let replace_stack : Loc.t -> Val.t -> t -> t =
   fun k v m -> {m with mem_pure= MemPure.add k v m.mem_pure}


  let add_heap : Loc.t -> Val.t -> t -> t =
   fun x v m ->
    let v =
      let sym = if Itv.is_empty (Val.get_itv v) then Relation.Sym.bot else Relation.Sym.of_loc x in
      let offset_sym, size_sym =
        if ArrayBlk.is_bot (Val.get_array_blk v) then (Relation.Sym.bot, Relation.Sym.bot)
        else (Relation.Sym.of_loc_offset x, Relation.Sym.of_loc_size x)
      in
      {v with Val.sym; Val.offset_sym; Val.size_sym}
    in
    {m with mem_pure= MemPure.add x v m.mem_pure}


  let add_unknown_from :
      Ident.t -> callee_pname:Typ.Procname.t option -> location:Location.t -> t -> t =
   fun id ~callee_pname ~location m ->
    let val_unknown = Val.unknown_from ~callee_pname ~location in
    add_stack (Loc.of_id id) val_unknown m |> add_heap Loc.unknown val_unknown


  let strong_update : PowLoc.t -> Val.t -> t -> t =
   fun locs v m ->
    let strong_update1 l m = if is_stack_loc l m then replace_stack l v m else add_heap l v m in
    PowLoc.fold strong_update1 locs m


  let transform_mem : f:(Val.t -> Val.t) -> PowLoc.t -> t -> t =
   fun ~f locs m ->
    let transform_mem1 l m =
      let add, find =
        if is_stack_loc l m then (replace_stack, find_stack) else (add_heap, find_heap)
      in
      add l (f (find l m)) m
    in
    PowLoc.fold transform_mem1 locs m


  let weak_update locs v m = transform_mem ~f:(fun v' -> Val.join v' v) locs m

  let update_mem : PowLoc.t -> Val.t -> t -> t =
   fun ploc v s ->
    if can_strong_update ploc then strong_update ploc v s
    else
      let () = L.d_printfln "Weak update for %a <- %a" PowLoc.pp ploc Val.pp v in
      weak_update ploc v s


  let remove_temp : Ident.t -> t -> t =
   fun temp m ->
    let l = Loc.of_id temp in
    { m with
      stack_locs= StackLocs.remove l m.stack_locs
    ; mem_pure= MemPure.remove l m.mem_pure
    ; alias= Alias.remove_temp temp m.alias }


  let remove_temps : Ident.t list -> t -> t =
   fun temps m -> List.fold temps ~init:m ~f:(fun acc temp -> remove_temp temp acc)


  let set_prune_pairs : PrunePairs.astate -> t -> t =
   fun prune_pairs m -> {m with latest_prune= LatestPrune.Latest prune_pairs}


  let apply_latest_prune : Exp.t -> t -> t =
   fun e m ->
    match (m.latest_prune, e) with
    | LatestPrune.V (x, prunes, _), Exp.Var r
    | LatestPrune.V (x, _, prunes), Exp.UnOp (Unop.LNot, Exp.Var r, _) -> (
      match find_simple_alias r m with
      | Some (Loc.Var (Var.ProgramVar y)) when Pvar.equal x y ->
          PrunePairs.fold (fun l v acc -> update_mem (PowLoc.singleton l) v acc) prunes m
      | _ ->
          m )
    | _ ->
        m


  let update_latest_prune : Exp.t -> Exp.t -> t -> t =
   fun e1 e2 m ->
    match (e1, e2, m.latest_prune) with
    | Lvar x, Const (Const.Cint i), LatestPrune.Latest p ->
        if IntLit.isone i then {m with latest_prune= LatestPrune.TrueBranch (x, p)}
        else if IntLit.iszero i then {m with latest_prune= LatestPrune.FalseBranch (x, p)}
        else {m with latest_prune= LatestPrune.Top}
    | _, _, _ ->
        {m with latest_prune= LatestPrune.Top}


  let get_reachable_locs_from : PowLoc.t -> t -> PowLoc.t =
    let add_reachable1 ~root loc v acc =
      if Loc.equal root loc then PowLoc.union acc (Val.get_all_locs v)
      else if Loc.is_field_of ~loc:root ~field_loc:loc then PowLoc.add loc acc
      else acc
    in
    let rec add_from_locs heap locs acc = PowLoc.fold (add_from_loc heap) locs acc
    and add_from_loc heap loc acc =
      if PowLoc.mem loc acc then acc
      else
        let reachable_locs = MemPure.fold (add_reachable1 ~root:loc) heap PowLoc.empty in
        add_from_locs heap reachable_locs (PowLoc.add loc acc)
    in
    fun locs m -> add_from_locs m.mem_pure locs PowLoc.empty


  let range : filter_loc:(Loc.t -> bool) -> t -> Polynomials.NonNegativePolynomial.astate =
   fun ~filter_loc {mem_pure} -> MemPure.range ~filter_loc mem_pure


  let get_relation : t -> Relation.astate = fun m -> m.relation

  let is_relation_unsat : t -> bool = fun m -> Relation.is_unsat m.relation

  let lift_relation : (Relation.astate -> Relation.astate) -> t -> t =
   fun f m -> {m with relation= f m.relation}


  let meet_constraints : Relation.Constraints.t -> t -> t =
   fun constrs -> lift_relation (Relation.meet_constraints constrs)


  let store_relation :
         PowLoc.t
      -> Relation.SymExp.t option * Relation.SymExp.t option * Relation.SymExp.t option
      -> t
      -> t =
   fun locs symexp_opts -> lift_relation (Relation.store_relation locs symexp_opts)


  let forget_locs : PowLoc.t -> t -> t = fun locs -> lift_relation (Relation.forget_locs locs)

  let init_param_relation : Loc.t -> t -> t = fun loc -> lift_relation (Relation.init_param loc)

  let init_array_relation :
      Allocsite.t -> offset:Itv.t -> size:Itv.t -> size_exp_opt:Relation.SymExp.t option -> t -> t
      =
   fun allocsite ~offset ~size ~size_exp_opt ->
    lift_relation (Relation.init_array allocsite ~offset ~size ~size_exp_opt)


  let instantiate_relation : Relation.SubstMap.t -> caller:t -> callee:t -> t =
   fun subst_map ~caller ~callee ->
    { caller with
      relation= Relation.instantiate subst_map ~caller:caller.relation ~callee:callee.relation }
end

module Mem = struct
  include AbstractDomain.BottomLifted (MemReach)

  type t = astate

  let bot : t = Bottom

  let init : t = NonBottom MemReach.init

  let f_lift_default : default:'a -> (MemReach.t -> 'a) -> t -> 'a =
   fun ~default f m -> match m with Bottom -> default | NonBottom m' -> f m'


  let f_lift : (MemReach.t -> MemReach.t) -> t -> t =
   fun f -> f_lift_default ~default:Bottom (fun m' -> NonBottom (f m'))


  let is_stack_loc : Loc.t -> t -> bool =
   fun k -> f_lift_default ~default:false (MemReach.is_stack_loc k)


  let find : Loc.t -> t -> Val.t = fun k -> f_lift_default ~default:Val.bot (MemReach.find k)

  let find_stack : Loc.t -> t -> Val.t =
   fun k -> f_lift_default ~default:Val.bot (MemReach.find_stack k)


  let find_set : PowLoc.t -> t -> Val.t =
   fun k -> f_lift_default ~default:Val.bot (MemReach.find_set k)


  let find_opt : Loc.t -> t -> Val.t option =
   fun k -> f_lift_default ~default:None (MemReach.find_opt k)


  let find_alias : Ident.t -> t -> AliasTarget.astate option =
   fun k -> f_lift_default ~default:None (MemReach.find_alias k)


  let find_simple_alias : Ident.t -> t -> Loc.t option =
   fun k -> f_lift_default ~default:None (MemReach.find_simple_alias k)


  let find_ret_alias : t -> AliasTarget.astate option =
    f_lift_default ~default:None MemReach.find_ret_alias


  let load_alias : Ident.t -> AliasTarget.astate -> t -> t =
   fun id loc -> f_lift (MemReach.load_alias id loc)


  let load_simple_alias : Ident.t -> Loc.t -> t -> t =
   fun id loc -> load_alias id (AliasTarget.Simple loc)


  let store_simple_alias : Loc.t -> Exp.t -> t -> t =
   fun loc e -> f_lift (MemReach.store_simple_alias loc e)


  let store_empty_alias : Val.t -> Loc.t -> t -> t =
   fun formal loc -> f_lift (MemReach.store_empty_alias formal loc)


  let add_stack_loc : Loc.t -> t -> t = fun k -> f_lift (MemReach.add_stack_loc k)

  let add_stack : Loc.t -> Val.t -> t -> t = fun k v -> f_lift (MemReach.add_stack k v)

  let add_heap : Loc.t -> Val.t -> t -> t = fun k v -> f_lift (MemReach.add_heap k v)

  let add_unknown_from : Ident.t -> callee_pname:Typ.Procname.t -> location:Location.t -> t -> t =
   fun id ~callee_pname ~location ->
    f_lift (MemReach.add_unknown_from id ~callee_pname:(Some callee_pname) ~location)


  let add_unknown : Ident.t -> location:Location.t -> t -> t =
   fun id ~location -> f_lift (MemReach.add_unknown_from id ~callee_pname:None ~location)


  let strong_update : PowLoc.t -> Val.t -> t -> t = fun p v -> f_lift (MemReach.strong_update p v)

  let weak_update : PowLoc.t -> Val.t -> t -> t = fun p v -> f_lift (MemReach.weak_update p v)

  let get_reachable_locs_from : PowLoc.t -> t -> PowLoc.t =
   fun locs -> f_lift_default ~default:PowLoc.empty (MemReach.get_reachable_locs_from locs)


  let update_mem : PowLoc.t -> Val.t -> t -> t = fun ploc v -> f_lift (MemReach.update_mem ploc v)

  let transform_mem : f:(Val.t -> Val.t) -> PowLoc.t -> t -> t =
   fun ~f ploc -> f_lift (MemReach.transform_mem ~f ploc)


  let remove_temps : Ident.t list -> t -> t = fun temps -> f_lift (MemReach.remove_temps temps)

  let set_prune_pairs : PrunePairs.astate -> t -> t =
   fun prune_pairs -> f_lift (MemReach.set_prune_pairs prune_pairs)


  let apply_latest_prune : Exp.t -> t -> t = fun e -> f_lift (MemReach.apply_latest_prune e)

  let update_latest_prune : Exp.t -> Exp.t -> t -> t =
   fun e1 e2 -> f_lift (MemReach.update_latest_prune e1 e2)


  let get_relation : t -> Relation.astate =
   fun m -> f_lift_default ~default:Relation.bot MemReach.get_relation m


  let meet_constraints : Relation.Constraints.t -> t -> t =
   fun constrs -> f_lift (MemReach.meet_constraints constrs)


  let is_relation_unsat m = f_lift_default ~default:true MemReach.is_relation_unsat m

  let store_relation :
         PowLoc.t
      -> Relation.SymExp.t option * Relation.SymExp.t option * Relation.SymExp.t option
      -> t
      -> t =
   fun locs symexp_opts -> f_lift (MemReach.store_relation locs symexp_opts)


  let forget_locs : PowLoc.t -> t -> t = fun locs -> f_lift (MemReach.forget_locs locs)

  let init_param_relation : Loc.t -> t -> t = fun loc -> f_lift (MemReach.init_param_relation loc)

  let init_array_relation :
      Allocsite.t -> offset:Itv.t -> size:Itv.t -> size_exp_opt:Relation.SymExp.t option -> t -> t
      =
   fun allocsite ~offset ~size ~size_exp_opt ->
    f_lift (MemReach.init_array_relation allocsite ~offset ~size ~size_exp_opt)


  let instantiate_relation : Relation.SubstMap.t -> caller:t -> callee:t -> t =
   fun subst_map ~caller ~callee ->
    match callee with
    | Bottom ->
        caller
    | NonBottom callee ->
        f_lift (fun caller -> MemReach.instantiate_relation subst_map ~caller ~callee) caller
end
