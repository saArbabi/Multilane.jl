const PP = PhysicalParam(4)

const NORMAL_BEHAVIOR = IDMMOBILBehavior("normal", PP.v_med, PP.l_car, 1)
const THREE_BEHAVIORS = IDMMOBILBehavior[
                    NORMAL_BEHAVIOR,
                    IDMMOBILBehavior("cautious", PP.v_slow+0.5, PP.l_car, 2),
                    IDMMOBILBehavior("aggressive", PP.v_fast, PP.l_car, 3)
                    ]

const NINE_BEHAVIORS = IDMMOBILBehavior[IDMMOBILBehavior(x[1],x[2],x[3],idx) for (idx,x) in
                                                 enumerate(Iterators.product(["cautious","normal","aggressive"],
                                                        [PP.v_slow+0.5;PP.v_med;PP.v_fast],
                                                        [PP.l_car]))]


const DEFAULT_BEHAVIORS = Dict{UTF8String, Any}(
    "3_even" => DiscreteBehaviorSet(THREE_BEHAVIORS, WeightVec(ones(3))),
    "9_even" => DiscreteBehaviorSet(NINE_BEHAVIORS, WeightVec(ones(9)))
)

const DEFAULT_PROBLEM_PARAMS = Dict{Symbol, Any}( #NOTE VALUES ARE NOT VECTORS like in linked
    :behaviors => "9_even",
    :lambda => 1.0
    # :behavior_probabilities => 1
)

const INITIAL_RELEVANT = [:behaviors]

type TestSet
    solver_key::UTF8String
    problem_params::Dict{Symbol, Any}
    solver_problem_params::Dict{Symbol, Any}
    linked_problem_params::Dict{Symbol, AbstractVector}
    N::Int # number of initial conditions
    nb_problems::Int
    rng_seed::UInt32
    key::UTF8String
end

"""
Generate a test set.

The keyword arguments should be either
    1) fields of the TestSet type, or
    2) problem parameters.

If the the argument in is a problem parameter, if it begins with "solver_", it
will only be applied to the problem given to the solver, otherwise it will be 
applied to both problems. The arguments will be applied in order, so solver_
parameter values should come later.
"""
function TestSet(ts::TestSet=TestSet(randstring()); kwargs...)
    ts = deepcopy(ts)
    fn = fieldnames(TestSet)
    for (k,v) in kwargs
        if k in fn
            ts.(k) = v
        elseif isa(v, AbstractVector)
            if ts.nb_problems == 1
                ts.nb_problems = length(v)
            end
            if length(v) != ts.nb_problems
                error("""
                    All linked parameters in a TestSet must have the same number of values.
                    Argument $k had had $(length(v)) entries while others had $(ts.nb_problems) entries.
                    """)
            end
            ts.linked_problem_params[k] = v
            delete!(ts.problem_params, k)
            delete!(ts.solver_problem_params, k)
        elseif haskey(ts.problem_params, k)
            ts.problem_params[k] = v
            ts.solver_problem_params[k] = v
        else
            solver_match = match(r"solver_(.*)", string(k))
            if solver_match != nothing
                sk = Symbol(solver_match[1])
                if haskey(ts.solver_problem_params, sk)
                    ts.solver_problem_params[sk] = v
                end
            else
                warn("Unrecognized TestSet argument $k")
            end
        end
    end
    return ts::TestSet
end

function TestSet(key::AbstractString=randstring())
    return TestSet("",
            deepcopy(DEFAULT_PROBLEM_PARAMS),
            deepcopy(DEFAULT_PROBLEM_PARAMS),
            Dict{UTF8String, AbstractVector}(),
            500, 1, 1, key)
end

# function TestSet(;key::AbstractString=randstring(), kwargs...)
#=
function TestSet(;kwargs...)
    ts = TestSet("",
            deepcopy(default_problem_params),
            deepcopy(default_problem_params),
            deepcopy(linked_problem_params),
            500,
            1,
            randstring())
            # key)
    return TestSet(ts, kwargs...)
end
=#

function gen_initials(tests::AbstractVector; behaviors::Dict{UTF8String,Any}=DEFAULT_BEHAVIORS, rng::AbstractRNG=MersenneTwister(123))
    initials = Dict{UTF8String,Any}()
    for t in tests
        add_initials!(initials, t, behaviors=behaviors, rng=rng)
    end
    return initials
end

function gen_base_problem()
    nb_lanes = 4
    desired_lane_reward = 10.
    rmodel = NoCrashRewardModel(desired_lane_reward*10., desired_lane_reward,2.5,nb_lanes)
    
    pp = PhysicalParam(nb_lanes,lane_length=100.)

    _discount = 1.0
    nb_cars = 10
    dmodel = NoCrashIDMMOBILModel(nb_cars, pp,
                              behaviors=DEFAULT_BEHAVIORS["9_even"],
                              lane_terminate=false)

    base_problem = NoCrashMDP(dmodel, rmodel, _discount)
end

function gen_problem(row, behaviors::Dict{UTF8String,Any}, rng::AbstractRNG)
    problem = deepcopy(gen_base_problem())
    # lambda
    problem.rmodel.cost_dangerous_brake = row[:lambda]*problem.rmodel.reward_in_desired_lane
    # p_normal
    problem.dmodel.behaviors = behaviors[row[:behaviors]]
    return problem
end

function gen_initial_physical(N; rng::AbstractRNG=MersenneTwister(123))
    base_problem = gen_base_problem()
    return [MLPhysicalState(initial_state(base_problem, rng)) for i in 1:N]
end

function add_initials!(objects::Dict{UTF8String, Any}, ts::TestSet; behaviors::Dict{UTF8String,Any}=DEFAULT_BEHAVIORS, rng::AbstractRNG=MersenneTwister(123))

    new_table = DataFrame()

    for p in ts.linked_problem_params
        if isempty(new_table)
            new_table = DataFrame(Dict(p))
        else
            new_table = join(new_table, DataFrame(Dict(p)), kind=:cross)
        end
    end
    
    # run through and check to see if all are the same
    different = false
    for (k,v) in ts.problem_params
        if ts.solver_problem_params[k] != v
            different = true
            break
        end
    end

    if different
        pairs = [k=>typeof(v)[v,ts.solver_problem_params[k]] for (k,v) in ts.problem_params]
        specific_table = DataFrame(Dict(pairs))
    else
        vectors = Dict([(k, DataArray(typeof(v)[v])) for (k,v) in ts.problem_params])
        specific_table = DataFrame(vectors)
    end

    new_table = join(new_table, specific_table, kind=:cross)
    param_list = names(new_table)

    problems = get(objects, "problems", Dict{UTF8String,Any}())
    initial_states = get(objects, "initial_states", Dict{UTF8String,Any}())
    state_lists = get(objects, "state_lists", Dict{UTF8String,Any}())
    initial_physical_states = get(objects,
                                  "initial_physical_states",
                                  gen_initial_physical(ts.N, rng=rng))

    if haskey(objects, "param_table")
        param_table = objects["param_table"]
        param_table = join(param_table, new_table, on=param_list, kind=:outer)
    else
        param_table = new_table
        param_table[:problem_key] = DataArray(UTF8String, nrow(param_table))
        param_table[:state_list_key] = DataArray(UTF8String, nrow(param_table))
    end

    # go through and make sure each row has a problem
    for row in eachrow(param_table)
        if first(isna(row[:problem_key]))
            key = randstring(rng)
            problems[key] = gen_problem(row, behaviors, rng)
            row[:problem_key] = key
        end
    end

    for g in groupby(param_table, INITIAL_RELEVANT)
        if isna(first(g[:state_list_key]))
            key = randstring(rng)
            pk = g[1,:problem_key]
            p = problems[pk]
            these_states = assign_keys([initial_state(p, initial_physical_states[i], rng) for i in 1:ts.N])
            merge!(initial_states, these_states)
            g[:,:state_list_key] = key
            state_lists[key] = collect(keys(these_states))
        end
    end
    
    objects["param_table"] = param_table
    objects["problems"] = problems
    objects["state_lists"] = state_lists
    objects["initial_states"] = initial_states
    objects["initial_physical_states"] = initial_physical_states

    return objects
end

function find_row(table::DataFrame, vals::Dict{Symbol,Any})
    for i in 1:nrow(table)
        found = true
        for (k,v) in vals
            if table[i,k] != v
                found = false
                break
            end
        end
        if found
            return table[i,:]
        end
    end
end

"""
Run the simulations in tests.
"""
function evaluate(tests::AbstractVector, objects::Dict{UTF8String,Any}; parallel=true, desc="Progress: ")

    solvers = objects["solvers"]
    problems = objects["problems"]
    initial_states = objects["initial_states"]
    param_table = objects["param_table"]
    state_lists = objects["state_lists"]

    nb_sims = sum([t.N*t.nb_problems for t in tests])

    stats = DataFrame(
        id=1:nb_sims,
        uuid=UInt128[Base.Random.uuid4() for i in 1:nb_sims],
        solver_key=DataArray(UTF8String,nb_sims),
        problem_key=DataArray(UTF8String,nb_sims),
        solver_problem_key=DataArray(UTF8String,nb_sims),
        test_key=DataArray(UTF8String,nb_sims),
        initial_key=DataArray(UTF8String,nb_sims),
        rng_seed=DataArray(Int,nb_sims),
        time=ones(nb_sims).*time(),
    )

    all_solvers = Array(Any, nb_sims)
    all_problems = Array(Any, nb_sims)
    all_solver_problems = Array(Any, nb_sims)
    all_initial = Array(Any, nb_sims)

    id = 0
    for t in tests
        test_key = t.key
        solver_key = t.solver_key
        for i in 1:t.nb_problems
            # find the row  
            d = Dict{Symbol, Any}()
            solver_d = Dict{Symbol, Any}()
            for (k,v) in t.problem_params
                d[k] = v
                solver_d[k] = t.solver_problem_params[k]
            end
            for (k,v) in t.linked_problem_params
                d[k] = v[i]
                solver_d[k] = v[i]
            end
            row = find_row(param_table, d)
            ep_key = first(row[:problem_key])
            solver_row = find_row(param_table, solver_d)
            sp_key = first(solver_row[:problem_key])
            is_keys = state_lists[first(row[:state_list_key])]
            for (is_i, is_key) in enumerate(take(is_keys, t.N))
                id += 1
                stats[:solver_key][id] = solver_key
                all_solvers[id] = deepcopy(solvers[solver_key])
                stats[:problem_key][id] = ep_key
                all_problems[id] = problems[ep_key]
                stats[:solver_problem_key][id] = sp_key
                all_solver_problems[id] = problems[sp_key]
                stats[:initial_key][id] = is_key
                all_initial[id] = initial_states[is_key]
                stats[:rng_seed][id] = is_i+t.rng_seed
                stats[:test_key][id] = test_key
            end
        end
    end

    sims = run_simulations(all_problems, all_initial, all_solver_problems, all_solvers, rng_seeds=stats[:rng_seed], parallel=parallel, desc=desc)
    fill_stats!(stats, all_problems, sims)

    results = deepcopy(objects)
    results["stats"] = stats
    results["histories"] = sims
    results["tests"] = Dict{UTF8String,Any}([(t.key, t) for t in tests])
    return results

    #=
    return Dict{UTF8String, Any}(
        "solvers"=>solvers,
        "problems"=>problems,
        "initial_states"=>initial_states,
        "stats"=>stats,
        "histories"=>sims,
        "tests"=>Dict{UTF8String,Any}([(t.key, t) for t in tests])
        )
        =#

end