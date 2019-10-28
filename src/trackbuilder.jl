using IRTools: Block, IR, Statement, Variable
using IRTools: arguments, argument!, block, blocks, branches, branch!, return!, xcall
import IRTools: block!


"""
Context type used to build up new IR with tracking functionality from some original IR.
Keeps track of necessary intermediate information.
"""
mutable struct TrackBuilder
    original_ir::IR
    new_ir::IR
    """Map from SSA variable in the original IR to the respective variables in the new IR."""
    variable_map::Dict{Any, Any}
    jump_targets::Dict{Int, Vector{Int}}
    return_block::Int
    recorder::Union{Variable, Nothing}

    TrackBuilder(o, n, v, j, r) = new(o, n, v, j, r)
end

function TrackBuilder(ir::IR)
    new_ir = empty(ir)
    variable_map = Dict{Any, Any}()
    jump_targets = jumptargets(ir)
    return_block = length(ir.blocks) + 1

    TrackBuilder(ir, new_ir, variable_map, jump_targets, return_block)
end


block!(builder::TrackBuilder) = block!(builder.new_ir)
block!(builder::TrackBuilder, i) =
    (i == 1) ? block(builder.new_ir, 1) : block!(builder.new_ir)

"""Substitute the variable `x` in original IR with its replacement in the newly built IR."""
substitute_variable(builder::TrackBuilder, x) = get(builder.variable_map, x, x)
substitute_variable(builder::TrackBuilder) = x -> substitute_variable(builder, x)

"""Record variable `x` in original IR to be substituted by `y` in the new IR."""
record_new_variable!(builder::TrackBuilder, x, y) = (push!(builder.variable_map, x => y); builder)

"""Check whether there exists a jump to block `block`"""
hasjumpto(builder::TrackBuilder, block) = haskey(builder.jump_targets, block.id)


"""Extract a dictionary mapping each block to the blocks to which you can jump from there."""
function jumptargets(ir::IR)
    targets = Dict{Int, Vector{Int}}()
    pushtarget!(from, to) = push!(get!(targets, to, Int[]), from)
    
    for block in blocks(ir), branch in branches(block)
        if !IRTools.isreturn(branch)
            pushtarget!(block.id, branch.block)

            if IRTools.isconditional(branch) && branch == branches(block)[end]
                # conditional branch with fallthrough (last of all)
                pushtarget!(block.id, block.id + 1)
            end
        end
    end

    return targets
end


function tapevalue(builder::TrackBuilder, value::IRTools.Variable)
    return DCGCall.tapeify(builder.recorder, QuoteNode(value))
end

function tapevalue(builder::TrackBuilder, value::Symbol)
    # this is a case occoring in special calls, which uses symbols at expression-level to
    # signify values (e.g., Expr(:boundscheck, :pop), Expr(:meta, :inline))
    return DCGCall.TapeConstant(QuoteNode(value))
end

function tapevalue(builder::TrackBuilder, value::Any)
    return DCGCall.TapeConstant(value)
end

function tapevalues(builder::TrackBuilder, values)
    return xcall(:getindex, TapeValue, tapevalue.(Ref(builder), values)...)
end


function returnrecord(builder::TrackBuilder, location, branch)
    argument_repr = tapevalue(builder, branch.args[1])
    return DCGCall.ReturnNode(argument_repr, location)
end

function jumprecord(builder::TrackBuilder, location, branch)
    condition_repr = tapevalue(builder, branch.condition)
    arguments_repr = tapevalues(builder, branch.args)
    return DCGCall.JumpNode(branch.block, arguments_repr, condition_repr, location)
end

function callrecord(builder::TrackBuilder, location, call_expr)
    f_expr, arguments_expr = call_expr.args[1], call_expr.args[2:end]
    f = substitute_variable(builder, f_expr)
    arguments = xcall(:tuple, map(substitute_variable(builder), arguments_expr)...)
    f_repr = tapevalue(builder, f_expr)
    arguments_repr = tapevalues(builder, arguments_expr)
    return DCGCall.dispatchcall(f, f_repr, arguments, arguments_repr, location)
end

function specialrecord(builder::TrackBuilder, location, special_expr)
    head = special_expr.head
    args = map(substitute_variable(builder), special_expr.args)
    form = Expr(head, args...)
    args_repr = tapevalues(builder, special_expr.args)
    form_repr = DCGCall.TapeSpecialForm(form, QuoteNode(head), args_repr)
    return DCGCall.SpecialCallNode(form_repr, location)
end

function constantrecord(builder::TrackBuilder, location, constant_expr)
    # TODO: make this itself a constant :)
    constant_repr = DCGCall.TapeConstant(constant_expr)
    return DCGCall.ConstantNode(constant_repr, location)
end

function argumentrecord(builder::TrackBuilder, location, argument_expr)
    argument_repr = DCGCall.TapeConstant(substitute_variable(builder, argument_expr))
    return DCGCall.ArgumentNode(argument_repr, location)
end


function pushrecord!(builder::TrackBuilder, block::Block, record;
                     substituting = nothing, line = 0)
    r = push!(block, IRTools.stmt(DCGCall.record!(builder.recorder, record), line = line))
    isnothing(substituting) || record_new_variable!(builder, substituting, r)
    return r
end


function track_branches!(builder::TrackBuilder, new_block::Block, branches)
    # called only from within a non-primitive call
    for (i, branch) in enumerate(branches)
        location = DCGCall.BranchIndex(new_block.id, i)
        substituted_args = map(substitute_variable(builder), branch.args)
        
        if IRTools.isreturn(branch)
            # the return is converted to a branch, redirecting to a new last block,
            # where it gets recorded
            return_record = push!(new_block, returnrecord(builder, location, branch))
            branch!(new_block, builder.return_block, substituted_args..., return_record)
        else
            # remember from where and why we branched, and extend branch arguments
            branch_record = push!(new_block, jumprecord(builder, location, branch))
            branch!(new_block, branch.block, substituted_args..., branch_record;
                    unless = substitute_variable(builder, branch.condition))
        end
    end

    return new_block
end


function track_statement!(builder::TrackBuilder, new_block::Block,
                          variable::Variable, statement::Statement)
    location = DCGCall.VarIndex(new_block.id, variable.id)
    expr = statement.expr

    if Meta.isexpr(expr, :call)
        # normal call expression; nested vs. primitive is handled in `record!`
        record = callrecord(builder, location, expr)
    elseif expr isa Expr
        # other special things, like `:new`, `:boundscheck`, or `:foreigncall`
        record = specialrecord(builder, location, expr)
    else
        # everything else is a constant evaluating to itself
        record = constantrecord(builder, location, expr)
    end

    pushrecord!(builder, new_block, record, line = statement.line, substituting = variable)
    return new_block
end


function track_arguments!(builder::TrackBuilder, new_block::Block, old_block::Block; isfirst = false)
    # copy over arguments from old block
    for argument in arguments(old_block)
        # without `insert = false`, `nothing` gets added to branches pointing here
        new_argument = argument!(new_block, insert = false)
        record_new_variable!(builder, argument, new_argument)
    end

    if isfirst
        # this is the first block, here we set up the recorder
        builder.recorder = push!(new_block, DCGCall.GraphRecorder(copy(builder.original_ir)))
    end

    if hasjumpto(builder, old_block)
        # record jumps to here, if there are any, by adding a new argument and recording it
        branch_argument = argument!(new_block, insert = false)
        pushrecord!(builder, new_block, branch_argument)
    end

    # track rest of the arguments from the old block
    for argument in arguments(old_block)
        location = DCGCall.VarIndex(new_block.id, argument.id)
        record = argumentrecord(builder, location, argument)
        pushrecord!(builder, new_block, record)
    end

    return new_block
end


function track_block!(builder::TrackBuilder, new_block::Block, old_block::Block; isfirst = false)
    @assert isfirst || isdefined(builder, :recorder)

    track_arguments!(builder, new_block, old_block, isfirst = isfirst)

    for (v, stmt) in old_block
        track_statement!(builder, new_block, v, stmt)
    end

    # set up branch tracking
    track_branches!(builder, new_block, branches(old_block))

    return new_block
end


"""
Set up the common return block in tracking IR.  All returns in the original IR are replaced by 
explicit jumps to the common `builder.return_block`, to be able to record return statements.

This needs to be done _after_ all blocks of the new IR have been created from the old blocks!
"""
function insert_return_block!(builder::TrackBuilder)
    return_block = block!(builder)
    @assert return_block.id == builder.return_block
    
    return_value = argument!(return_block, insert = false)
    pushrecord!(builder, return_block, argument!(return_block, insert = false))
    tape_expr = xcall(:getfield, builder.recorder, :tape)
    return!(return_block, xcall(:tuple, return_value, tape_expr))
    return return_block
end


"""Create new IR with tracking code from original IR in the builder, and return it."""
function build_tracks!(builder::TrackBuilder)
    for (i, old_block) in enumerate(blocks(builder.original_ir))
        new_block = block!(builder, i)
        track_block!(builder, new_block, old_block, isfirst = i == 1)
    end
    
    # now we set up a block at the last position, to which all return statements redirect.
    insert_return_block!(builder)

    return builder.new_ir
end
