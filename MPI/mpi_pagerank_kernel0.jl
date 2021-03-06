# execute by running `➜ mpiexec -n $NUM_PROCS julia mpi_pagerank_kernel0.jl`

import MPI

MPI.Init()

###############################
# Generating vertices in the  #
###############################

function work_arrays(scale, edges_per_vertex)
    m = total_edges(scale, edges_per_vertex)
    start_vertex, end_vertex = Vector{Int}(m), Vector{Int}(m)
    rand_array = Vector{Float64}(2 * scale)
    return start_vertex, end_vertex, rand_array
end

# equivalent to `KronGraph500NoPerm` in the original version
function generate_vertices(scale, edges_per_vertex)
    generate_vertices!(work_arrays(scale, edges_per_vertex)..., scale)
end

function generate_vertices!(start_vertex, end_vertex, rand_array, scale)
    edges = length(start_vertex)

    # set R-MAT (2x2 Kronecker) coefficients
    a = 0.57
    b = 0.19
    c = 0.19
    d = 1.0 - (a + b + c)

    # calculate normalization coefficients
    a_plus_b = a + b
    c_norm = c / (1.0 - a_plus_b)
    a_norm = a / a_plus_b

    # loop over each scale
    @inbounds for j in 1:edges
        rand!(rand_array)
        start_node = one(eltype(start_vertex))
        end_node = one(eltype(end_vertex))
        @inbounds for i in 1:scale
            k = 1 << (i - 2)
            start_bit = rand_array[i] > a_plus_b
            end_bit = rand_array[i + scale] > ifelse(start_bit, c_norm, a_norm)
            start_node += k * start_bit
            end_node += k * end_bit
        end
        start_vertex[j] = start_node
        end_vertex[j] = end_node
    end

    return start_vertex, end_vertex
end

total_edges(scale, edges_per_vertex) = edges_per_vertex * 2^scale

############
# Kernel 0 #
############

# Write vertices to a file. This follows the same TSV specification used in the original
# MATLAB kernel 0 implementation.
function write_vertices!(buffer, file_name, start_vertex, end_vertex)
    for j in eachindex(start_vertex)
        write(buffer, string(start_vertex[j]))
        write(buffer, '\t')
        write(buffer, string(end_vertex[j]))
        write(buffer, '\n')
    end
    open(file_name, "w") do file
        write(file, takebuf_string(buffer))
    end
end

# the MPI-independent, serial part of kernel 0 (executed by each process)
function kernel0_serial(path, myfiles, scale, edges_per_vertex)
    # initialize buffer for edge writing
    buffer = IOBuffer()

    # initialize work arrays
    start_vertex, end_vertex, rand_array = work_arrays(scale, edges_per_vertex)

    # write to files
    for file_index in myfiles
        srand(file_index) # uniquely seed RNG specifically for this file
        file_name = joinpath(path, "$(file_index).tsv")

        # fill vertex vectors with computed edges
        generate_vertices!(start_vertex, end_vertex, rand_array, scale)

        # write vertices to the file
        write_vertices!(buffer, file_name, start_vertex, end_vertex)
    end
end

# kernel 0 (executed by each process)
function kernel0(path, nfiles, scale, edges_per_vertex)
    numprocs = MPI.Comm_size(MPI.COMM_WORLD)
    myrank = MPI.Comm_rank(MPI.COMM_WORLD)
    start_file = ceil(Int, 1 + (nfiles / numprocs) * myrank)
    end_file = ceil(Int, (nfiles / numprocs) * (myrank + 1))
    kernel0_serial(path, start_file:end_file, scale, edges_per_vertex)
end

function main()
    is_master_process = MPI.Comm_rank(MPI.COMM_WORLD) == 0

    # problem parameters
    scale = 18
    edges_per_vertex = 16     # must be power of 2
    nfiles = edges_per_vertex # must be power of 2

    # set up directoriess
    data_path = joinpath(pwd(), "pagerankdata")
    kernel0_path = joinpath(data_path, "kernel0")

    if is_master_process
        !(isdir(data_path)) && mkdir(data_path)
        !(isdir(kernel0_path)) && mkdir(kernel0_path)
    end

    is_master_process && println("starting kernel 0")
    is_master_process && tic()

    MPI.Barrier(MPI.COMM_WORLD)
    kernel0(kernel0_path, nfiles, scale, edges_per_vertex)
    MPI.Barrier(MPI.COMM_WORLD)

    is_master_process && toc()
    is_master_process && println("done")
end

main()

MPI.Finalize()
