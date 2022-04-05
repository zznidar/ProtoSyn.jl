module SeqDes

    using ProtoSyn
    using ProtoSyn.Calculators: EnergyFunctionComponent
    using PyCall
    using CUDA

    const np            = PyNULL()
    const seq_des       = PyNULL()
    const models        = PyNULL()
    const torch         = PyNULL()
    const sampler_util  = PyNULL()
    const loaded_models = Vector{PyObject}()

    models_default_dir = joinpath(ProtoSyn.Peptides.resource_dir, "Calculators/SeqDes")

    function __init__()
        numpy_instructions = """
        (1) Install NumPy: pip install numpy
        (2) Re-launch Julia and ProtoSyn
        """
        numpy_available = ProtoSyn.is_python_package_installed("numpy", numpy_instructions, "Peptides.SeqDes")
        if numpy_available
            copy!(np, pyimport("numpy"))
        end # if

        torch_instructions = """
        (1) Install Torch: pip install --pre torch torchvision -f https://download.pytorch.org/whl/nightly/cu100/torch_nightly.html
        (2) Re-launch Julia and ProtoSyn
        """
        torch_available = ProtoSyn.is_python_package_installed("torch", torch_instructions, "Peptides.SeqDes")
        if torch_available
            copy!(torch, pyimport("torch"))
        end # if

        seq_des_instructions = """
        (1) Install BioPython: pip install biopython
        (2) Install TensorBoardX: pip install tensorboardX
        (3) Download or clone the `seq_des` source code from GitHub (https://github.com/ProteinDesignLab/protein_seq_des)
        (4) Add the `seq_des` source code directory to the system's PYTHONPATH (\$ export PYTHONPATH="\${PYTHONPATH}:/path/to/seq_des/").
            Consider adding this line to your ~/.bashrc to permanently add `seq_des` to the system's PYTHONPATH.
        (5) Download the `seq_des` models (check the GitHub page for the link). The default location for the models is
            "ProtoSyn.jl/resources/Peptides/Calculators/SeqDes/". This can be changing by setting the
            `ProtoSyn.Peptides.Calculators.SeqDes.models_default_dir` variable.
        (6) Re-launch Julia and ProtoSyn
        """
        seq_des_available = ProtoSyn.is_python_package_installed("seq_des", seq_des_instructions, "Peptides.SeqDes")
        if seq_des_available
            copy!(seq_des, pyimport("seq_des"))
            copy!(models, pyimport("seq_des.models"))
            copy!(sampler_util, pyimport("seq_des.util.sampler_util"))
        end # if

        function load_model(model_path::String; use_cuda::Bool = false)
            model = models.seqPred(nic = 28)
            if use_cuda
                model.cuda()
            end # if
            if use_cuda
                state = torch.load(model_path)
            else
                state = torch.load(model_path, map_location="cpu")
            end # if
            for k in state.keys
                if occursin("module", k)
                    model = torch.nn.DataParallel(model)
                end
                break
            end # for
            if use_cuda
                model.load_state_dict(torch.load(model_path))
            else
                model.load_state_dict(torch.load(model_path, map_location="cpu"))
            end # if

            return model
        end # function

        function load_models(models_list::Vector{String}; use_cuda::Bool = false, models_dir::String = models_default_dir)
            loaded_models = []
            for model in models_list
                push!(loaded_models, load_model(joinpath(models_dir, model),
                    use_cuda = use_cuda))
            end

            return loaded_models
        end # function

        use_cuda = CUDA.has_cuda() && CUDA.has_cuda_gpu()
        _models  = load_models(readdir(models_default_dir), use_cuda = use_cuda)

        @assert length(_models) === 4 "Expected 4 models to be loaded, but only $(length(models)) were found at $models_default_dir"

        for model in _models
            model.eval()
        end # for

        copy!(loaded_models, _models)
    end # function



    atom_types = Dict{String, Int}(
        "N" => 1,
        "C" => 2,
        "O" => 3,
        "S" => 4,
        "P" => 5,
    )

    residue_types = Dict{String, Int}(
        "HIS" => 0, # Should be loaded from grammar
        "HIE" => 0, # Should be loaded from grammar
        "HID" => 0, # Should be loaded from grammar
        "LYS" => 1,
        "ARG" => 2,
        "ASP" => 3,
        "GLU" => 4,
        "SER" => 5,
        "THR" => 6,
        "ASN" => 7,
        "GLN" => 8,
        "ALA" => 9,
        "VAL" => 10,
        "LEU" => 11,
        "ILE" => 12,
        "MET" => 13,
        "PHE" => 14,
        "TYR" => 15,
        "TRP" => 16,
        "PRO" => 17,
        "GLY" => 18,
        "CYS" => 19,
        "MSE" => 13,
    )

    """
    # TODO: DOCUMENTATION
    Should return:
        - atom_coords: N x 3 Vector (atomic positions)
        - atom_data: N x 4 Vector(atomic data)
            • [residue_id, bb_ind, atom_type, residue_type], where `residue_id`
            is 0-indexed; `bb_ind` is either 1 or 0, if the corresponding atom
            is in the protein backbone or not, respectively; `atom_type` is the
            index of the atom element in the `Calculators.SeqDes.atom_types`
            dictionary; and `residue_type` is the index of the residue type in
            the  `Calculators.SeqDes.residue_types` dictionary.
        - residue_bb_index: Nr x 4 (atomic index of all backbone atoms + CB)
            • [N, CA, C, CB], where all atomic indexes are 0-indexed; for
            residues without CB, the -1 index is used.
        - residue_data: Dict('chain_code' => Nr x 4) (residue data)
            • [residue_id, residue_id_code, residue_index, residue_type], where
            `residue_id_code` can be ignored and set to ' ', residue_index is
            0-indexed and `residue_type` is the index of the residue type in the
            `Calculators.SeqDes.residue_types` dictionary.
        - residue_label: Nr x 1 (list of residue types)
        - chis: Nr x 2 x 4 (chi dihedral angle values)
            • [[chi1_v, chi2_v, chi3_v, chi4_v], [chi1, chi2, chi3, chi4]],
            where chi1_v, chi2_v, etc is the actual dihedral value (in a 4
            element array) and chi1, chi2, etc is either 1 or 0, if the
            corresponding chi dihedral exists or nor, respectively.

        Note: `N` is the number of atoms and `Nr` is the number of residues.
    """
    function get_pdb_data(pose::Pose, selection::Opt{AbstractSelection} = nothing)

        function get_residue_type(residue_name::ProtoSyn.ResidueName)
            if residue_name in keys(residue_types)
                return residue_types[residue_name]
            else
                return 20
            end # if
        end # function

        sidechain = SidechainSelection()(pose)

        if selection !== nothing
            atom_sele = ProtoSyn.promote(selection, Atom) & !as"H"
        else
            atom_sele = !as"H"
        end # if

        atoms       = atom_sele(pose, gather = true)
        residues    = collect(eachresidue(pose.graph))
        
        # Atomic descriptors (atom_coords & atom_data)
        T           = eltype(pose.state)
        atom_coords = Vector{Vector{Vector{T}}}()
        atom_data   = Vector{Vector{Vector{Union{Int}}}}()

        # Residue descriptors (residue_bb_index)
        _residue_bb_index = Dict{Int, Dict{String, Int}}()

        for residue in residues
            _residue_bb_index[residue.id] = Dict{String, Int}(
                "N" => -1, "CA" => -1, "C" => -1, "CB" => -1)
        end # for

        # Atom loop
        for (i, atom) in enumerate(atoms)
            # Note: i is the non-hydrogen index of the atom

            # Atom_coords
            push!(atom_coords, [Vector{T}(pose.state[atom].t)])

            # Atom_data
            residue_id       =  atom.container.id - 1
            bb_ind           = !sidechain[atom.id]
            if atom.symbol in keys(atom_types)
                atom_type    = atom_types[atom.symbol]
            else
                atom_type    = 6
            end # if
            residue_type = get_residue_type(atom.container.name)
            push!(atom_data, [Int[residue_id, bb_ind, atom_type, residue_type]])

            # Residue_bb_index (1/2)
            if atom.name in ["N", "CA", "C", "CB"]
                _residue_bb_index[atom.container.id][atom.name] = i - 1
            end # if
        end # for

        # Residue loop
        residue_bb_index = Vector{Vector{Int}}()
        residue_data     = Dict{String, Vector{Tuple{Int, String, Int, Int}}}()
        residue_label    = Vector{Int}()
        chis             = Vector{Vector{Vector{T}}}()
        for segment in eachsegment(pose.graph)
            nv = Vector{Tuple{Int, String, Int, Int}}()
            residue_data[string(segment.code)] = nv
        end # for

        for residue in residues
            
            # Residue_bb_index (2/2)
            r = _residue_bb_index[residue.id]
            push!(residue_bb_index, Int[r["N"], r["CA"], r["C"], r["CB"]])

            # Residue_data
            residue_id      = residue.id
            residue_id_code = " " # ?
            residue_index   = residue.id - 1
            residue_type    = get_residue_type(residue.name)
            push!(residue_data[string(residue.container.code)],
                (residue_id, residue_id_code, residue_index, residue_type))

            # Residue_label
            push!(residue_label, residue_type)

            # Chis
            n_chis = length(ProtoSyn.Peptides.Dihedral.chi_dict[residue.name])
            chi_vals = Vector{T}()
            chi_exs  = Vector{T}()
            for (i, chi) in enumerate([:chi1, :chi2, :chi3, :chi4])
                if i >= n_chis
                    chi_val = 0.0
                    chi_ex  = 0.0
                else
                    chi_fcn  = getproperty(ProtoSyn.Peptides.Dihedral, chi)
                    chi_atom = chi_fcn(residue)
                    chi_val  = ProtoSyn.getdihedral(pose.state, chi_atom)
                    chi_ex   = 1.0
                end # if
                push!(chi_vals, chi_val)
                push!(chi_exs, chi_ex)
            end # for
            push!(chis, Vector{Vector{T}}([chi_vals, chi_exs]))
        end # for

        return atom_coords, atom_data, residue_bb_index, residue_data,
            residue_label, chis
    end # function

    """
    # TODO: DOCUMENTATION
    # ! Only works with use_cuda = true
    Update forces does nothing.
    """
    function calc_seqdes(::Type{ProtoSyn.CUDA_2}, pose::Pose, selection::Opt{AbstractSelection}, update_forces::Bool = false; use_cuda::Bool = true)
        atom_coords, atom_data, residue_bb_index_list, res_data, res_label, chis = get_pdb_data(pose, selection)

        atom_coords           = PyObject(np.array(atom_coords, dtype = np.float32))
        atom_data             = PyObject(np.array(atom_data))
        residue_bb_index_list = PyObject(np.array(residue_bb_index_list))
        chis                  = PyObject(np.array(chis))

        logits, chi_feat, y, chi_1_logits, chi_2_logits, chi_3_logits, chi_4_logits, chi_1, chi_2, chi_3, chi_4, chi_angles, chi_mask = sampler_util.get_conv_feat(
            loaded_models, atom_coords, atom_data, residue_bb_index_list, res_data, res_label, chis, bb_only=0, return_chi=0, use_cuda=use_cuda
        )

        log_p_per_res, log_p_mean = sampler_util.get_energy_from_feat(
            loaded_models,
            logits,
            chi_feat,
            y,
            chi_1_logits,
            chi_2_logits,
            chi_3_logits,
            chi_4_logits,
            chi_1,
            chi_2,
            chi_3,
            chi_4,
            chi_angles,
            chi_mask,
            include_rotamer_probs=0,
            use_cuda=use_cuda,
        )

        return float(log_p_mean)(), nothing
    end

    calc_seqdes(pose::Pose, selection::Opt{AbstractSelection}, update_forces::Bool = false; use_cuda::Bool = true) = begin
        calc_seqdes(ProtoSyn.acceleration.active, pose, selection, update_forces, use_cuda = use_cuda)
    end

    function get_default_seqdes(;α::T = 1.0) where {T <: AbstractFloat}
        EnergyFunctionComponent(
            "SeqDes_ML_Model",
            calc_seqdes,
            nothing,
            Dict{Symbol, Any}(:use_cuda => true),
            α,
            false)
    end

end # module