using IRTools: Block, IR, Statement, Variable
using IRTools: arguments, argument!, block, blocks, branches, branch!, xcall
import IRTools: block!, return!


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
    tape::Union{Variable, Nothing}

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

return!(builder, block, argument, record) = branch!(block, builder.return_block, argument, record)

"""Substitute the variable `x` in original IR with its replacement in the newly built IR."""
substitute_variable(builder::TrackBuilder, x) = get(builder.variable_map, x, x)
substitute_variable(builder::TrackBuilder) = x -> substitute_variable(builder, x)

"""Record variable `x` in original IR to be substituted by `y` in the new IR."""
record_new_variable!(builder::TrackBuilder, x, y) = (push!(builder.variable_map, x => y); builder)

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

"""Check whether there exists a jump to block `block`"""
hasjumpto(builder, block) = haskey(builder.jump_targets, block.id)


"""Push the `record!` call for a statement, an record the result a a new variable substitution."""
function pushrecord!(builder::TrackBuilder, block::Block, args...;
                     substituting = nothing, line = 0)
    record = IRTools.stmt(DCGCall.record!(builder.tape, args...), line = line)
    r = push!(block, record)
    !isnothing(substituting) && record_new_variable!(builder, substituting, r)
    return r
end


function track_branches!(builder::TrackBuilder, new_block::Block, branches)
    # called only from within a non-primitive call
    for (position, branch) in enumerate(branches)
        index = DCGCall.BranchIndex(new_block.id, position)
        args = map(substitute_variable(builder), branch.args)
        reified_args = map(reify_quote, branch.args)
        
        if IRTools.isreturn(branch)
            return_record = push!(new_block, DCGCall.Return(reified_args[1], args[1], index))
            # the return is converted to a branch, redirecting to a new last block, where it
            # gets recorded
            return!(builder, new_block, args[1], return_record)
        else
            condition = substitute_variable(builder, branch.condition)
            reified_condition = reify_quote(branch.condition)
            
            # remember from where and why we branched in target_info
            arg_exprs = xcall(:vect, reified_args...)
            arg_values = xcall(:vect, args...)
            branch_record = push!(new_block, DCGCall.Branch(branch.block, arg_exprs, arg_values,
                                                            reified_condition, index))

            # extend branch args by target_info
            branch!(new_block, branch.block, args..., branch_record; unless = condition)
        end
    end

    return new_block
end


function track_statement!(builder::TrackBuilder, new_block::Block,
                          variable::Variable, statement::Statement)
    index = DCGCall.VarIndex(new_block.id, variable.id)
    expr = statement.expr
    reified_expr = reify_quote(statement.expr)
    
    if Meta.isexpr(expr, :call)
        # normal call expression; nested vs. primitive is handled in `record!`
        args = map(substitute_variable(builder), expr.args)
        pushrecord!(builder, new_block, index, reified_expr, args...,
                    substituting = variable, line = statement.line)
    elseif expr isa Expr
        # other special things, like `:new`, `:boundscheck`, or `:foreigncall`
        args = map(substitute_variable(builder), expr.args)
        special_value = push!(new_block, Expr(expr.head, args...))
        special_expr = DCGCall.SpecialStatement(reified_expr, special_value, index)
        pushrecord!(builder, new_block, special_expr,
                    substituting = variable, line = statement.line)
    elseif expr isa QuoteNode || expr isa GlobalRef
        # for statements that are just constants (like type literals), or global values
        constant_expr = DCGCall.Constant(expr, index)
        # TODO: make constant_expr itself a constant :)
        pushrecord!(builder, new_block, constant_expr,
                    substituting = variable, line = statement.line)
    else
        # currently unhandled
        error("Found statement of unknown type: ", statement)
    end

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
        # this is the first block, here we set up the tape
        builder.tape = push!(new_block, DCGCall.GraphTape(copy(builder.original_ir)))
    end

    if hasjumpto(builder, old_block)
        # record jumps to here, if there are any, by adding a new argument and recording it
        branch_argument = argument!(new_block, insert = false)
        pushrecord!(builder, new_block, branch_argument)
    end

    # track rest of the arguments from the old block
    for argument in arguments(old_block)
        index = DCGCall.VarIndex(new_block.id, argument.id)
        new_argument = substitute_variable(builder, argument)
        pushrecord!(builder, new_block, DCGCall.Argument(new_argument, index))
    end

    return new_block
end


function track_block!(builder::TrackBuilder, new_block::Block, old_block::Block; isfirst = false)
    @assert isfirst || isdefined(builder, :tape)

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
    return!(return_block, xcall(:tuple, return_value, builder.tape))
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