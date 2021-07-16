using LinearAlgebra
using Test

using KNITRO

using ADNLPModels, NLPModels, NLPModelsKnitro

function test_unconstrained()
  nlp = ADNLPModel(x -> (x[1] - 1)^2 + 100 * (x[2] - x[1]^2)^2, [-1.2; 1.0])
  stats = knitro(nlp, outlev = 0)
  @test isapprox(stats.solution, [1.0; 1.0], rtol = 1e-6)
  @test stats.status == :first_order
end

function test_qp()
  nlp =
    ADNLPModel(x -> (x[1] - 1)^2 + 4 * (x[2] - 3)^2, zeros(2), x -> [sum(x) - 1.0], [0.0], [0.0])
  stats = knitro(nlp, outlev = 0)
  @test isapprox(stats.solution, [-1.4; 2.4], rtol = 1e-6)
  @test stats.iter == 1
  @test stats.status == :first_order
end

function test_qp_with_solver_and_evals()
  nlp =
    ADNLPModel(x -> (x[1] - 1)^2 + 4 * (x[2] - 3)^2, zeros(2), x -> [sum(x) - 1.0], [0.0], [0.0])
  solver = KnitroSolver(nlp, outlev = 0)
  stats = knitro!(nlp, solver)
  @test isapprox(stats.solution, [-1.4; 2.4], rtol = 1e-6)
  @test stats.iter == 1
  @test stats.status == :first_order

  gx = KNITRO.KN_get_objgrad_values(solver.kc)[2]
  @test isapprox(gx, [-4.8; -4.8], rtol = 1e-6)
  cx = KNITRO.KN_get_con_values(solver.kc)
  @test isapprox(norm(cx), 0, atol = 1e-6)
  Jx = KNITRO.KN_get_jacobian_values(solver.kc)
  @test Jx[1] == [0; 0]
  @test Jx[2] == [0; 1]
  @test Jx[3] == [1; 1]
  finalize(solver)
end

function test_constrained()
  nlp = ADNLPModel(x -> (x[1] - 1)^2 + 4 * (x[2] - 3)^2, zeros(2), x -> [dot(x, x)], [0.0], [1.0])
  stats = knitro(nlp, outlev = 0)
  @test isapprox(stats.solution, [0.11021046172567574, 0.9939082725775202], rtol = 1e-6)
  @test stats.status == :first_order

  # test with a good primal-dual initial guess
  x0 = copy(stats.solution)
  y0 = copy(stats.multipliers)
  z0 = copy(stats.multipliers_L)
  stats = knitro(nlp, x0 = x0, y0 = y0, z0 = z0, outlev = 0)
  @test stats.status == :first_order
  @test isapprox(stats.solution, [0.11021046172567574, 0.9939082725775202], rtol = 1e-6)
  @test stats.iter == 2
end

function test_with_params()
  nlp = ADNLPModel(x -> (x[1] - 1)^2 + 100 * (x[2] - x[1]^2)^2, [-1.2; 1.0])
  stats = knitro(nlp, opttol = 1e-12, presolve = 0, outlev = 0)
  @test isapprox(stats.solution, [1.0; 1.0], rtol = 1e-6)
  @test stats.status == :first_order
end

function test_with_callback()
  function callback(kc, x, lambda_, userParams)
    if KNITRO.KN_get_number_iters(kc) > 1
      return KNITRO.KN_RC_USER_TERMINATION
    end
    return 0
  end
  nlp = ADNLPModel(x -> (x[1] - 1)^2 + 100 * (x[2] - x[1]^2)^2, [-1.2; 1.0])
  stats = knitro(nlp, opttol = 1e-12, callback = callback, outlev = 0)
  @test stats.solver_specific[:internal_msg] == KNITRO.KN_RC_USER_TERMINATION
  @test stats.iter == 2
  @test stats.status == :exception
end

function test_maximize()
  meta = NLPModelMeta(1, x0 = [0.5], lvar = zeros(1), uvar = ones(1), minimize = false)
  nlp = ADNLPModel(meta, Counters(), ADNLPModels.ForwardDiffAD(1, 1), x -> x[1], x -> [])
  stats = knitro(nlp, outlev = 0)
  @test isapprox(stats.solution, ones(1), rtol = 1e-6)
  @test isapprox(stats.objective, 1.0, rtol = 1e-6)
  @test isapprox(stats.multipliers_L, -ones(1), atol = 1e-6)
  @test stats.status == :first_order
end

function test_unconstrained_nls()
  F_Rosen(x) = [x[1] - 1; 10 * (x[2] - x[1]^2)]
  nls = ADNLSModel(F_Rosen, [-1.2; 1.0], 2)
  stats = knitro(nls, outlev = 0)
  @test isapprox(stats.objective, 0, atol = 1.0e-6)
  @test isapprox(stats.solution, ones(2), rtol = 1e-6)
  @test stats.status == :first_order
end

function test_larger_unconstrained_nls()
  n = 100
  F_larger(x) = [[10 * (x[i + 1] - x[i]^2) for i = 1:(n - 1)]; [x[i] - 1 for i = 1:(n - 1)]]
  nls = ADNLSModel(F_larger, 0.9 * ones(n), 2 * (n - 1))  # there are local solutions other than ones(n)
  stats = knitro(nls, outlev = 0)
  @test isapprox(stats.objective, 0, atol = 1.0e-6)
  @test isapprox(stats.solution, ones(n), rtol = 1e-6)
  @test stats.status == :first_order

  # test with a good primalinitial guess
  x0 = copy(stats.solution)
  stats = knitro(nls, x0 = x0, outlev = 0)
  @test isapprox(stats.objective, 0, atol = 1.0e-6)
  @test isapprox(stats.solution, ones(n), rtol = 1e-6)
  @test stats.status == :first_order
  @test stats.iter == 0
end

function test_larger_unconstrained_nls_with_solver()
  n = 100
  F_larger(x) = [[10 * (x[i + 1] - x[i]^2) for i = 1:(n - 1)]; [x[i] - 1 for i = 1:(n - 1)]]
  nls = ADNLSModel(F_larger, 0.9 * ones(n), 2 * (n - 1))  # there are local solutions other than ones(n)
  solver = KnitroSolver(nls, outlev = 0)
  stats = knitro!(nls, solver)
  @test isapprox(stats.objective, 0, atol = 1.0e-6)
  @test isapprox(stats.solution, ones(n), rtol = 1e-6)
  @test stats.status == :first_order
  finalize(solver)
end

function test_constrained_nls()
  n = 3
  F_larger(x) = [[10 * (x[i + 1] - x[i]^2) for i = 1:(n - 1)]; [x[i] - 1 for i = 1:(n - 1)]]
  c_quad(x) = [sum(x .^ 2) - 5; prod(x) - 2]
  nls = ADNLSModel(
    F_larger,
    [0.5; 1.0; 1.5],
    2 * (n - 1),
    [1.0, 1.0, 1.0],
    [Inf, Inf, Inf],
    c_quad,
    zeros(2),
    zeros(2),
  )
  stats = knitro(nls, opttol = 1e-12, outlev = 0)
  # this constrained NLS problem will have been converted to a FeasibilityFormNLS; extract the solution
  x = stats.solution[1:n]
  @test isapprox(x, [1.0647319483656656, 1.21502560462289, 1.5459814546883264], rtol = 1e-5)
  @test stats.status == :first_order
end

function test_nls_maximize()
  meta = NLPModelMeta(1, x0 = [0.5], lvar = zeros(1), uvar = ones(1), minimize = false)
  nls_meta = NLSMeta(1, 1)
  nls = ADNLSModel(meta, nls_meta, NLSCounters(), ADNLPModels.ForwardDiffAD(1, 1), x -> x, x -> [])
  stats = knitro(nls, outlev = 0)
  @test isapprox(stats.solution, ones(1), rtol = 1e-6)
  @test isapprox(stats.objective, 0.5, rtol = 1e-6)
  @test stats.status == :first_order
end

function test_linear_constraints()
  meta = NLPModelMeta(2, x0 = zeros(2), ncon = 2, y0 = zeros(2), lcon = ones(2), ucon = ones(2), lin = Int32[1, 2])
  nlp = ADNLPModel(meta, Counters(), ADNLPModels.ForwardDiffAD(2, 2), x -> sum(x), x -> [1. 2.; 3. 4.] * x)
  stats = knitro(nlp, outlev = 0)
  @test stats.solution == [-1; 1]
  @test stats.objective == 0.0
  @test stats.status == :first_order
end

test_unconstrained()
test_qp()
test_qp_with_solver_and_evals()
test_constrained()
test_with_params()
test_with_callback()
test_maximize()
test_linear_constraints()

test_unconstrained_nls()
test_larger_unconstrained_nls()
test_larger_unconstrained_nls_with_solver()
test_constrained_nls()
test_nls_maximize()
