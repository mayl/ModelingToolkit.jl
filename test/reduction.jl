using ModelingToolkit, OrdinaryDiffEq, Test, NonlinearSolve
using ModelingToolkit: topsort_equations

@variables t x(t) y(t) z(t) k(t)
eqs = [
       x ~ y + z
       z ~ 2
       y ~ 2z + k
      ]

sorted_eq = topsort_equations(eqs, [x, y, z, k])

ref_eq = [
          z ~ 2
          y ~ 2z + k
          x ~ y + z
         ]
@test ref_eq == sorted_eq

@test_throws ArgumentError topsort_equations([
                                             x ~ y + z
                                             z ~ 2
                                             y ~ 2z + x
                                            ], [x, y, z, k])

@parameters t σ ρ β
@variables x(t) y(t) z(t) a(t) u(t) F(t)
D = Differential(t)

test_equal(a, b) = @test isequal(simplify(a, expand=true), simplify(b, expand=true))

eqs = [
       D(x) ~ σ*(y-x)
       D(y) ~ x*(ρ-z)-y + β
       0 ~ z - x + y
       0 ~ a + z
       u ~ z + a
      ]

lorenz1 = ODESystem(eqs,t,name=:lorenz1)

lorenz1_aliased = structural_simplify(lorenz1)
io = IOBuffer(); show(io, MIME("text/plain"), lorenz1_aliased); str = String(take!(io))
@test all(s->occursin(s, str), ["lorenz1", "States (2)", "Parameters (3)"])
reduced_eqs = [
               D(x) ~ σ*(y - x)
               D(y) ~ β + x*(ρ - (x - y)) - y
              ]
test_equal.(equations(lorenz1_aliased), reduced_eqs)
@test isempty(setdiff(states(lorenz1_aliased), [x, y, z]))
test_equal.(observed(lorenz1_aliased), [
                                        u ~ 0
                                        z ~ x - y
                                        a ~ -z
                                       ])

# Multi-System Reduction

@variables s(t)
eqs1 = [
        D(x) ~ σ*(y-x) + F,
        D(y) ~ x*(ρ-z)-u,
        D(z) ~ x*y - β*z,
        u ~ x + y - z,
       ]

lorenz = name -> ODESystem(eqs1,t,name=name)
lorenz1 = lorenz(:lorenz1)
ss = ModelingToolkit.get_structure(initialize_system_structure(lorenz1))
@test isempty(setdiff(ss.fullvars, [D(x), F, y, x, D(y), u, z, D(z)]))
lorenz2 = lorenz(:lorenz2)

connected = ODESystem([s ~ a + lorenz1.x
                       lorenz2.y ~ s
                       lorenz1.F ~ lorenz2.u
                       lorenz2.F ~ lorenz1.u],t,systems=[lorenz1,lorenz2])
@test length(Base.propertynames(connected)) == 10
@test isequal((@nonamespace connected.lorenz1.x), x)

# Reduced Flattened System

reduced_system = structural_simplify(connected)
reduced_system2 = structural_simplify(structural_simplify(structural_simplify(connected)))

@test isempty(setdiff(states(reduced_system), states(reduced_system2)))
@test isequal(equations(reduced_system), equations(reduced_system2))
@test isequal(observed(reduced_system), observed(reduced_system2))
@test setdiff(states(reduced_system), [
        s
        a
        lorenz1.x
        lorenz1.y
        lorenz1.z
        lorenz1.u
        lorenz2.x
        lorenz2.y
        lorenz2.z
        lorenz2.u
       ]) |> isempty

@test setdiff(parameters(reduced_system), [
        lorenz1.σ
        lorenz1.ρ
        lorenz1.β
        lorenz2.σ
        lorenz2.ρ
        lorenz2.β
       ]) |> isempty

reduced_eqs = [
               D(lorenz1.x) ~ lorenz1.σ*((lorenz1.y) - (lorenz1.x)) - ((lorenz2.z) - (lorenz2.x) - (lorenz2.y))
               D(lorenz1.y) ~ lorenz1.z + lorenz1.x*(lorenz1.ρ - (lorenz1.z)) - (lorenz1.x) - (lorenz1.y)
               D(lorenz1.z) ~ lorenz1.x*lorenz1.y - (lorenz1.β*(lorenz1.z))
               D(lorenz2.x) ~ lorenz2.σ*((lorenz2.y) - (lorenz2.x)) - ((lorenz1.z) - (lorenz1.x) - (lorenz1.y))
               D(lorenz2.y) ~ lorenz2.z + lorenz2.x*(lorenz2.ρ - (lorenz2.z)) - (lorenz2.x) - (lorenz2.y)
               D(lorenz2.z) ~ lorenz2.x*lorenz2.y - (lorenz2.β*(lorenz2.z))
              ]

test_equal.(equations(reduced_system), reduced_eqs)

observed_eqs = [
                s ~ lorenz2.y
                a ~ lorenz2.y - lorenz1.x
                lorenz1.F ~ -((lorenz2.z) - (lorenz2.x) - (lorenz2.y))
                lorenz2.F ~ -((lorenz1.z) - (lorenz1.x) - (lorenz1.y))
                lorenz2.u ~ lorenz1.F
                lorenz1.u ~ lorenz2.F
               ]
test_equal.(observed(reduced_system), observed_eqs)

pp = [
      lorenz1.σ => 10
      lorenz1.ρ => 28
      lorenz1.β => 8/3
      lorenz2.σ => 10
      lorenz2.ρ => 28
      lorenz2.β => 8/3
     ]
u0 = [
      lorenz1.x => 1.0
      lorenz1.y => 0.0
      lorenz1.z => 0.0
      lorenz2.x => 1.0
      lorenz2.y => 0.0
      lorenz2.z => 0.0
     ]
prob1 = ODEProblem(reduced_system, u0, (0.0, 100.0), pp)
solve(prob1, Rodas5())

prob2 = SteadyStateProblem(reduced_system, u0, pp)
@test prob2.f.observed(lorenz2.u, prob2.u0, pp) === 1.0


# issue #724 and #716
let
    @parameters t
    D = Differential(t)
    @variables x(t) u(t) y(t)
    @parameters a b c d
    ol = ODESystem([D(x) ~ a * x + b * u; y ~ c * x + d * u], t, name=:ol)
    @variables u_c(t) y_c(t)
    @parameters k_P
    pc = ODESystem(Equation[u_c ~ k_P * y_c], t, name=:pc)
    connections = [
        ol.u ~ pc.u_c
        pc.y_c ~ ol.y
    ]
    connected = ODESystem(connections, t, systems=[ol, pc])
    @test equations(connected) isa Vector{Equation}
    reduced_sys = structural_simplify(connected)
    ref_eqs = [
               D(ol.x) ~ ol.a*ol.x + ol.b*ol.u
               0 ~ pc.k_P*(ol.c*ol.x + ol.d*ol.u) - ol.u
              ]
    @test ref_eqs == equations(reduced_sys)
end

# issue #889
let
    @parameters t
    D = Differential(t)
    @variables x(t)
    @named sys = ODESystem([0 ~ D(x) + x], t, [x], [])
    sys = structural_simplify(sys)
    @test_throws ModelingToolkit.InvalidSystemException ODEProblem(sys, [1.0], (0, 10.0))
end

# NonlinearSystem
@parameters t
@variables u1(t) u2(t) u3(t)
@parameters p
eqs = [
       u1 ~ u2
       u3 ~ u1 + u2 + p
       u3 ~ hypot(u1, u2) * p
      ]
sys = NonlinearSystem(eqs, [u1, u2, u3], [p])
reducedsys = structural_simplify(sys)
@test observed(reducedsys) == [u1 ~ 0.5(u3 - p); u2 ~ u1]

u0 = [
      u1 => 1
      u2 => 1
      u3 => 0.3
     ]
pp = [2]
nlprob = NonlinearProblem(reducedsys, u0, pp)
reducedsol = solve(nlprob, NewtonRaphson())
residual = fill(100.0, length(states(reducedsys)))
nlprob.f(residual, reducedsol.u, pp)
@test hypot(nlprob.f.observed(u2, reducedsol.u, pp), nlprob.f.observed(u1, reducedsol.u, pp)) * pp ≈ reducedsol.u atol=1e-9

@test all(x->abs(x) < 1e-5, residual)

N = 5
@variables xs[1:N]
A = reshape(1:N^2, N, N)
eqs = xs .~ A * xs
sys′ = NonlinearSystem(eqs, xs, [])
sys = structural_simplify(sys′)

# issue 958
@parameters t k₁ k₂ k₋₁ E₀
@variables E(t) C(t) S(t) P(t)
D = Differential(t)

eqs = [
       D(E) ~ k₋₁ * C - k₁ * E * S
       D(C) ~ k₁ * E * S - k₋₁ * C - k₂ * C
       D(S) ~ k₋₁ * C - k₁ * E * S
       D(P) ~ k₂ * C
       E₀ ~ E + C
      ]

@named sys = ODESystem(eqs, t, [E, C, S, P], [k₁, k₂, k₋₁, E₀])
@test_throws ModelingToolkit.InvalidSystemException structural_simplify(sys)

# Example 5 from Pantelides' original paper
@parameters t
params = collect(@parameters y1(t) y2(t))
sts = collect(@variables x(t) u1(t) u2(t))
D = Differential(t)
eqs = [
       0 ~ x + sin(u1 + u2)
       D(x) ~ x + y1
       cos(x) ~ sin(y2)
      ]
@named sys = ODESystem(eqs, t, sts, params)
@test_throws ModelingToolkit.InvalidSystemException structural_simplify(sys)

# issue #963
@parameters t
D = Differential(t)
@variables v47(t) v57(t) v66(t) v25(t) i74(t) i75(t) i64(t) i71(t) v1(t) v2(t)

eq = [
      v47 ~ v1
      v47 ~ sin(10t)
      v57 ~ v1 - v2
      v57 ~ 10.0i64
      v66 ~ v2
      v66 ~ 5.0i74
      v25 ~ v2
      i75 ~ 0.005 * D(v25)
      0 ~ i74 + i75 - i64
      0 ~ i64 + i71]


sys0 = ODESystem(eq, t)
sys = structural_simplify(sys0)
@test length(equations(sys)) == 1
eq = equations(sys)[1]
@test isequal(eq.lhs, 0)
dv25 = ModelingToolkit.value(ModelingToolkit.derivative(eq.rhs, v25))
ddv25 = ModelingToolkit.value(ModelingToolkit.derivative(eq.rhs, D(v25)))
dt = ModelingToolkit.value(ModelingToolkit.derivative(eq.rhs, sin(10t)))
@test dv25 ≈ 0.3
@test ddv25 == 0.005
@test dt == -0.1
