export knitro

using NLPModels, NLPModelsModifiers, SolverCore

# Knitro does not accept least-squares problems with constraints other than bounds.
# We must treat those as general NLPs.
# If an NLSModel has constraints other than bounds, we convert it to a FeasibilityFormNLS.
# Because FeasibilityFormNLS <: AbstractNLSModel, we need a trait to dispatch on.
_is_general_nlp(nlp::AbstractNLPModel) = Val{true}()
_is_general_nlp(nls::AbstractNLSModel) = Val{isa(nls, FeasibilityFormNLS)}()

"""`output = knitro(nlp; kwargs...)`

Solves the `NLPModel` problem `nlp` using KNITRO.

# Optional keyword arguments
* `x0`: a vector of size `nlp.meta.nvar` to specify an initial primal guess
* `y0`: a vector of size `nlp.meta.ncon` to specify an initial dual guess for the general constraints
* `z0`: a vector of size `nlp.meta.nvar` to specify initial multipliers for the bound constraints
* `callback`: a user-defined `Function` called by KNITRO at each iteration.

For more information on callbacks, see https://www.artelys.com/docs/knitro/2_userGuide/callbacks.html and
the docstring of `KNITRO.KN_set_newpt_callback`.

All other keyword arguments will be passed to KNITRO as an option.
See https://www.artelys.com/docs/knitro/3_referenceManual/userOptions.html for the list of options accepted.
"""
knitro(nlp::AbstractNLPModel, args...; kwargs...) =
  _knitro(_is_general_nlp(nlp), nlp, args...; kwargs...)

function knitro_statuses(code::Integer)
  if code == 0
    return :first_order
  end
  if code == -100
    return :acceptable
  end
  if -103 ≤ code ≤ -101
    return :stalled #feasible
  end
  if -299 ≤ code ≤ -200
    return :infeasible
  end
  if -301 ≤ code ≤ -300
    return :unbounded
  end
  if code == -400 || code == -410  # -400 = feasible, -410 = infeasible
    return :max_iter
  end
  if code == -401 || code == -411  # -401 = feasible, -411 = infeasible
    return :max_time
  end
  if code == -402 || code == -412  # -402 = feasible, -412 = infeasible
    return :max_eval
  end
  if -600 ≤ code ≤ -500
    return :exception
  end
  return :unknown
end

function _knitro(
  ::Val{true},
  nlp::AbstractNLPModel;
  callback::Union{Function, Nothing} = nothing,
  kwargs...,
)
  n, m = nlp.meta.nvar, nlp.meta.ncon

  kc = KNITRO.KN_new()
  release = KNITRO.get_release()
  KNITRO.KN_reset_params_to_defaults(kc)
  if nlp.meta.minimize
    KNITRO.KN_set_obj_goal(kc, KNITRO.KN_OBJGOAL_MINIMIZE)
  else
    KNITRO.KN_set_obj_goal(kc, KNITRO.KN_OBJGOAL_MAXIMIZE)
  end

  # add variables and bound constraints
  KNITRO.KN_add_vars(kc, n)

  lvarinf = isinf.(nlp.meta.lvar)
  if !all(lvarinf)
    lvar = nlp.meta.lvar
    if any(lvarinf)
      lvar = copy(nlp.meta.lvar)
      lvar[lvarinf] .= -KNITRO.KN_INFINITY
    end
    KNITRO.KN_set_var_lobnds(kc, lvar)
  end

  uvarinf = isinf.(nlp.meta.uvar)
  if !all(uvarinf)
    uvar = nlp.meta.uvar
    if any(uvarinf)
      uvar = copy(nlp.meta.uvar)
      uvar[uvarinf] .= KNITRO.KN_INFINITY
    end
    KNITRO.KN_set_var_upbnds(kc, uvar)
  end

  # add constraints
  KNITRO.KN_add_cons(kc, m)
  lcon = nlp.meta.lcon
  lconinf = isinf.(lcon)
  if any(lconinf)
    lcon = copy(nlp.meta.lcon)
    lcon[lconinf] .= -KNITRO.KN_INFINITY
  end
  ucon = nlp.meta.ucon
  uconinf = isinf.(ucon)
  if any(uconinf)
    ucon = copy(nlp.meta.ucon)
    ucon[uconinf] .= KNITRO.KN_INFINITY
  end
  KNITRO.KN_set_con_lobnds(kc, lcon)
  KNITRO.KN_set_con_upbnds(kc, ucon)

  # set primal and dual initial guess
  kwargs = Dict(kwargs)
  if :x0 ∈ keys(kwargs)
    KNITRO.KN_set_var_primal_init_values(kc, kwargs[:x0])
    pop!(kwargs, :x0)
  else
    KNITRO.KN_set_var_primal_init_values(kc, nlp.meta.x0)
  end
  if :y0 ∈ keys(kwargs)
    KNITRO.KN_set_con_dual_init_values(kc, kwargs[:y0])
    pop!(kwargs, :y0)
  end
  if :z0 ∈ keys(kwargs)
    KNITRO.KN_set_var_dual_init_values(kc, kwargs[:z0])
    pop!(kwargs, :z0)
  end

  jrows, jcols = m > 0 ? jac_structure(nlp) : (Int[], Int[])
  hrows, hcols = hess_structure(nlp)

  # define evaluation callback
  function evalAll(kc, cb, evalRequest, evalResult, userParams)
    x = evalRequest.x
    evalRequestCode = evalRequest.evalRequestCode

    if evalRequestCode == KNITRO.KN_RC_EVALFC
      evalResult.obj[1] = obj(nlp, x)
      m > 0 && cons!(nlp, x, evalResult.c)
    elseif evalRequestCode == KNITRO.KN_RC_EVALGA
      grad!(nlp, x, evalResult.objGrad)
      m > 0 && jac_coord!(nlp, x, evalResult.jac)
    elseif evalRequestCode == KNITRO.KN_RC_EVALH
      if m > 0
        hess_coord!(
          nlp,
          x,
          view(evalRequest.lambda, 1:m),
          evalResult.hess,
          obj_weight = evalRequest.sigma,
        )
      else
        hess_coord!(nlp, x, evalResult.hess, obj_weight = evalRequest.sigma)
      end
    elseif evalRequestCode == KNITRO.KN_RC_EVALHV
      vec = evalRequest.vec
      if m > 0
        hprod!(
          nlp,
          x,
          view(evalRequest.lambda, 1:m),
          vec,
          evalResult.hessVec,
          obj_weight = evalRequest.sigma,
        )
      else
        hprod!(nlp, x, vec, evalResult.hessVec, obj_weight = evalRequest.sigma)
      end
    elseif evalRequestCode == KNITRO.KN_RC_EVALH_NO_F  # it would be silly to call this on unconstrained problems but better be careful
      if m > 0
        hess_coord!(nlp, x, view(evalRequest.lambda, 1:m), evalResult.hess, obj_weight = 0.0)
      else
        hess_coord!(nlp, x, evalResult.hess, obj_weight = 0.0)
      end
    elseif evalRequestCode == KNITRO.KN_RC_EVALHV_NO_F
      vec = evalRequest.vec
      if m > 0
        hprod!(nlp, x, view(evalRequest.lambda, 1:m), vec, evalResult.hessVec, obj_weight = 0.0)
      else
        hprod!(nlp, x, vec, evalResult.hessVec, obj_weight = 0.0)
      end
    else
      return KNITRO.KN_RC_CALLBACK_ERR
    end
    return 0
  end

  # register callbacks
  cb = KNITRO.KN_add_eval_callback_all(kc, evalAll)
  KNITRO.KN_set_cb_grad(
    kc,
    cb,
    evalAll,
    jacIndexCons = convert(Vector{Int32}, jrows .- 1),  # indices must be 0-based
    jacIndexVars = convert(Vector{Int32}, jcols .- 1),
  )
  KNITRO.KN_set_cb_hess(
    kc,
    cb,
    nlp.meta.nnzh,
    evalAll,
    hessIndexVars1 = convert(Vector{Int32}, hcols .- 1),  # Knitro wants the upper triangle
    hessIndexVars2 = convert(Vector{Int32}, hrows .- 1),
  )

  # specify that we are able to provide the Hessian without including the objective
  KNITRO.KN_set_param(kc, KNITRO.KN_PARAM_HESSIAN_NO_F, KNITRO.KN_HESSIAN_NO_F_ALLOW)

  # pass options to KNITRO
  for (k, v) in kwargs
    KNITRO.KN_set_param(kc, string(k), v)
  end

  # set user-defined callback called after each iteration
  callback == nothing || KNITRO.KN_set_newpt_callback(kc, callback)

  t = @timed begin
    nStatus = KNITRO.KN_solve(kc)
  end

  nStatus, obj_val, x, lambda_ = KNITRO.KN_get_solution(kc)
  primal_feas = KNITRO.KN_get_abs_feas_error(kc)
  dual_feas = KNITRO.KN_get_abs_opt_error(kc)
  iter = KNITRO.KN_get_number_iters(kc)
  if KNITRO_VERSION ≥ v"12.0"
    Δt = KNITRO.KN_get_solve_time_cpu(kc)
    real_time = KNITRO.KN_get_solve_time_real(kc)
  else
    Δt = real_time = t[2]
  end
  gx = KNITRO.KN_get_objgrad_values(kc)[2]
  # @show KNITRO.KN_get_objgrad_nnz(kc)
  # @show norm(KNITRO.KN_get_objgrad_values(kc)[2], Inf)
  # @show norm(grad(nlp, x), Inf)
  # https://github.com/jump-dev/KNITRO.jl/blob/master/src/kn_attributes.jl

  KNITRO.KN_reset_params_to_defaults(kc)
  KNITRO.KN_free(kc)

  return GenericExecutionStats(
    knitro_statuses(nStatus),
    nlp,
    solution = x,
    objective = obj_val,
    dual_feas = dual_feas,
    iter = convert(Int, iter),
    primal_feas = primal_feas,
    elapsed_time = Δt,
    multipliers = lambda_[1:m],
    multipliers_L = lambda_[(m + 1):(m + n)],  # don't know how to get those separately
    multipliers_U = eltype(x)[],
    solver_specific = Dict(:internal_msg => nStatus, :real_time => real_time, :gx => gx),
  )
end

function _knitro(
  ::Val{false},
  nls::AbstractNLSModel;
  callback::Union{Function, Nothing} = nothing,
  kwargs...,
)
  n, m, ne = nls.meta.nvar, nls.meta.ncon, nls.nls_meta.nequ

  if m > 0
    @warn "Knitro only treats bound-constrained least-squares problems; converting to feasibility form"
    return knitro(FeasibilityFormNLS(nls), callback = callback; kwargs...)
  end

  kc = KNITRO.KN_new()
  release = KNITRO.get_release()
  KNITRO.KN_reset_params_to_defaults(kc)
  if nls.meta.minimize
    KNITRO.KN_set_obj_goal(kc, KNITRO.KN_OBJGOAL_MINIMIZE)
  else
    KNITRO.KN_set_obj_goal(kc, KNITRO.KN_OBJGOAL_MAXIMIZE)
  end

  # add variables and bound constraints
  KNITRO.KN_add_vars(kc, n)

  lvarinf = isinf.(nls.meta.lvar)
  if !all(lvarinf)
    lvar = nls.meta.lvar
    if any(lvarinf)
      lvar = copy(nls.meta.lvar)
      lvar[lvarinf] .= -KNITRO.KN_INFINITY
    end
    KNITRO.KN_set_var_lobnds(kc, lvar)
  end

  uvarinf = isinf.(nls.meta.uvar)
  if !all(uvarinf)
    uvar = nls.meta.uvar
    if any(uvarinf)
      uvar = copy(nls.meta.uvar)
      uvar[uvarinf] .= KNITRO.KN_INFINITY
    end
    KNITRO.KN_set_var_upbnds(kc, uvar)
  end

  # set primal and dual initial guess
  kwargs = Dict(kwargs)
  if :x0 ∈ keys(kwargs)
    KNITRO.KN_set_var_primal_init_values(kc, kwargs[:x0])
    pop!(kwargs, :x0)
  else
    KNITRO.KN_set_var_primal_init_values(kc, nls.meta.x0)
  end
  if :z0 ∈ keys(kwargs)
    KNITRO.KN_set_var_dual_init_values(kc, kwargs[:z0])
    pop!(kwargs, :z0)
  end

  # add number of residual functions
  KNITRO.KN_add_rsds(kc, ne)

  jrows, jcols = jac_structure_residual(nls)

  # define callback for residual
  function callbackEvalR(kc, cb, evalRequest, evalResult, userParams)
    if evalRequest.evalRequestCode != KNITRO.KN_RC_EVALR
      @warn "callbackEvalR incorrectly called with eval request code " evalRequest.evalRequestCode
      return -1
    end
    residual!(nls, evalRequest.x, evalResult.rsd)
    return 0
  end

  # define callback for residual Jacobian
  function callbackEvalRJ(kc, cb, evalRequest, evalResult, userParams)
    if evalRequest.evalRequestCode != KNITRO.KN_RC_EVALRJ
      @warn "callbackEvalRJ incorrectly called with eval request code " evalRequest.evalRequestCode
      return -1
    end
    jac_coord_residual!(nls, evalRequest.x, evalResult.rsdJac)
    return 0
  end

  # register callbacks
  cb = KNITRO.KN_add_lsq_eval_callback(kc, callbackEvalR)
  KNITRO.KN_set_cb_rsd_jac(
    kc,
    cb,
    nls.nls_meta.nnzj,
    callbackEvalRJ,
    jacIndexRsds = convert(Vector{Int32}, jrows .- 1),  # indices must be 0-based
    jacIndexVars = convert(Vector{Int32}, jcols .- 1),
  )

  # pass options to KNITRO
  for (k, v) in kwargs
    KNITRO.KN_set_param(kc, string(k), v)
  end

  # set user-defined callback called after each iteration
  callback == nothing || KNITRO.KN_set_newpt_callback(kc, callback)

  t = @timed begin
    nStatus = KNITRO.KN_solve(kc)
  end

  nStatus, obj_val, x, lambda_ = KNITRO.KN_get_solution(kc)
  primal_feas = KNITRO.KN_get_abs_feas_error(kc)
  dual_feas = KNITRO.KN_get_abs_opt_error(kc)
  iter = KNITRO.KN_get_number_iters(kc)
  if KNITRO_VERSION ≥ v"12.0"
    Δt = KNITRO.KN_get_solve_time_cpu(kc)
    real_time = KNITRO.KN_get_solve_time_real(kc)
  else
    Δt = real_time = t[2]
  end

  KNITRO.KN_reset_params_to_defaults(kc)
  KNITRO.KN_free(kc)

  return GenericExecutionStats(
    knitro_statuses(nStatus),
    nls,
    solution = x,
    objective = obj_val,
    dual_feas = dual_feas,
    iter = convert(Int, iter),
    primal_feas = primal_feas,
    elapsed_time = Δt,
    multipliers = lambda_[1:m],
    multipliers_L = lambda_[(m + 1):(m + n)],  # don't know how to get those separately
    multipliers_U = eltype(x)[],
    solver_specific = Dict(:internal_msg => nStatus, :real_time => real_time),
  )
end
