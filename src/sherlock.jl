function sbatch_spawn(tests::AbstractVector, objects::Dict;
                      batch_size=100,
                      time_per_batch="20:00",
                      data_dir=joinpath(get(ENV, "SCRATCH", tempdir()),
                                        string("sim_data_", Dates.format(Dates.now(),"u_d_HH_MM"))),
                      submit_command="submit",
                      template_name="sherlock.sh"
                      )

    stats = setup_stats(tests, objects)
    objects["tests"] = Dict([t.key=>t for t in tests])

    try
        mkdir(data_dir)
    catch ex
        warn("When creating data_dir, got error $ex. Does the dir already exist?\nContinuing anyways.")
    end
    objectname = joinpath(data_dir, string("objects_", Dates.format(Dates.now(),"u_d_HH_MM"), ".jld"))
    JLD.save(objectname, objects)
    println("objects saved to $objectname")

    nb_sims = nrow(stats)
    nb_batches = cld(nb_sims, batch_size)
    @assert rem(nb_sims, batch_size) == 0
    results_file_list = []

    for i in 1:nb_batches
        jobname = "$(i)_of_$nb_batches"
        println("preparing job $jobname")

        these_stats = stats[(i-1)*batch_size+1:i*batch_size, :]
        
        listname = joinpath(data_dir, string("list_", jobname, ".jld"))
        JLD.save(listname, Dict("stats"=>these_stats))

        tpl = readall(joinpath(Pkg.dir("Multilane"), "templates", template_name))
        sbatch = Mustache.render(tpl,
                        job_name=jobname,
                        outpath=joinpath(data_dir, string(jobname, ".out")),
                        errpath=joinpath(data_dir, string(jobname, ".err")),
                        time=time_per_batch,
                        object_file_path=objectname,
                        list_file_path=listname)

        sbatchname = joinpath(data_dir, string(jobname, ".sbatch"))
        open(sbatchname, "w") do f
            write(f, sbatch)
        end
        
        cmd = `$submit_command $sbatchname` 
        println("running $cmd ...")
        run(cmd)
        println("done")
        push!(results_file_list, joinpath(data_dir, string("results_", jobname, ".jld")))
    end

    return results_file_list
end

function gather_results(results_file_list; save_file::Nullable=Nullable())
    results = JLD.load(first(results_file_list))
    for f in results_file_list[2:end]
        results = merge_results!(results, JLD.load(f))
    end
    if !isnull(save_file)
        JLD.save(save_file, results)
    end
    return results
end
