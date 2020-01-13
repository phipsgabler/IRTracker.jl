using IRTools


####################################################################################################
# General graph query API, modelled after XPath axes, see:
# https://developer.mozilla.org/en-US/docs/Web/XPath/Axes

abstract type Axis end

abstract type Forward <: Axis end
abstract type Reverse <: Axis end

struct Parent <: Reverse end
struct Child <: Forward end
struct Preceding <: Reverse end # corresponding to preceding-sibling
struct Following <: Forward end # corresponding to following-sibling
struct Ancestor <: Reverse end
struct Descendant <: Forward end


query(node::AbstractNode, ::Type{Parent}) = getparent(node)

query(node::AbstractNode, ::Type{Child}) = Vector{AbstractNode}()
query(node::NestedCallNode, ::Type{Child}) = getchildren(node)

function query(node::AbstractNode, ::Type{Following})
    parent = query(node, Parent)
    if isnothing(parent)
        return Vector{AbstractNode}()
    else
        return @view parent.children[(getposition(node) + 1):end]
    end
end

function query(node::AbstractNode, ::Type{Preceding})
    parent = query(node, Parent)
    if isnothing(parent)
        return Vector{AbstractNode}()
    else
        return @view parent.children[1:(getposition(node) - 1)]
    end
end

function query(node::AbstractNode, ::Type{Ancestor})
    ancestors = Vector{AbstractNode}()
    current = query(node, Parent)
    while !isnothing(current)
        push!(ancestors, current)
        current = query(current, Parent)
    end

    return ancestors
end

function query(node::AbstractNode, ::Type{Descendant})
    descendants = copy(query(node, Child))
    first_unhandled = 1

    while first_unhandled ≤ length(descendants)
        for descendant in @view descendants[first_unhandled:end]
            append!(descendants, query(descendant, Child))
            first_unhandled += 1
        end
    end
    
    return descendants
end


####################################################################################################
# Accessor functions based on Query API, and specialized queries; node properties and metadata

"""
    getchildren(node) -> Vector{<:AbstractNode}

Return all sub-nodes of this node (only none-empty if `node` is a `NestedCallNode`).
"""
getchildren(node::NestedCallNode) = node.children
getchildren(node::AbstractNode) = Vector{AbstractNode}()

"""
    getparent(node) -> Union{Nothing, NestedCallNode}

Return the `NestedNode` `node` is a child of (the root call has no parent).
"""
getparent(node::AbstractNode) = getparent(node.info)


"""
    getarguments(node) -> Vector{ArgumentNode}

Return the sub-nodes representing the arguments of a nested call.
"""
getarguments(node::AbstractNode) = [child for child in node.children if child isa ArgumentNode]


# Make child nodes accessible by indexing
getindex(node::NestedCallNode, i) = node.children[i]
firstindex(node::NestedCallNode) = firstindex(node.children)
lastindex(node::NestedCallNode) = lastindex(node.children)


"""Return the IR index into the original IR statement, which `node` was recorded from."""
getlocation(node::AbstractNode) = getlocation(node.info)

"""Return the index of `node` in its parent node."""
getposition(node::AbstractNode) = getposition(node.info)

"""
Return the original IR this node was recorded from.  `original_ir(node)[location(node)]` will
return the precise statement.
"""
getir(node::AbstractNode) = getir(node.info)

getvalue(::JumpNode) = nothing
getvalue(::ReturnNode) = nothing
getvalue(node::SpecialCallNode) = getvalue(node.form)
getvalue(node::NestedCallNode) = getvalue(node.call)
getvalue(node::PrimitiveCallNode) = getvalue(node.call)
getvalue(node::ConstantNode) = getvalue(node.value)
getvalue(node::ArgumentNode) = getvalue(node.value)

getmetadata(node::AbstractNode) = getmetadata(node.info)

getmetadata(node::AbstractNode, key::Symbol) = getmetadata(node)[key]
getmetadata(node::AbstractNode, key::Symbol, default) = get(getmetadata(node), key, default)
getmetadata!(node::AbstractNode, key::Symbol, default) = get!(getmetadata(node), key, default)
getmetadata!(f, node::AbstractNode, key::Symbol) = get!(f, getmetadata(node), key)
setmetadata!(node::AbstractNode, key::Symbol, value) = getmetadata(node)[key] = value


####################################################################################################
# Data dependency analysis

"""
    referenced(node[, axis]) -> Vector{<:AbstractNode}

Return all nodes that `node` references; i.e., all data it immediately depends on.
"""
referenced(node::AbstractNode) = referenced(node, Preceding)

referenced(node::JumpNode, ::Type{Preceding}) =
    getindex.(reduce(append!, references.(node.arguments), init = references(node.condition)))
referenced(node::ReturnNode, ::Type{Preceding}) = getindex.(references(node.argument))
referenced(node::SpecialCallNode, ::Type{Preceding}) = getindex.(references(node.form))
referenced(node::NestedCallNode, ::Type{Preceding}) = getindex.(references(node.call))
referenced(node::PrimitiveCallNode, ::Type{Preceding}) = getindex.(references(node.call))
referenced(::ConstantNode, ::Type{Preceding}) = AbstractNode[]
referenced(::ArgumentNode, ::Type{Preceding}) = AbstractNode[]

referenced(node::AbstractNode, ::Type{Parent}) = AbstractNode[]
function referenced(node::ArgumentNode, ::Type{Parent})
    # first argument is always the function itself -- need to treat this separately
    if node.number == 1
        return getindex.(references(getparent(node).call.f))
    else
        return getindex.(references(getparent(node).call.arguments[node.number - 1]))
    end
end

referenced(node::AbstractNode, ::Type{Union{Preceding, Parent}}) = referenced(node, Preceding)
referenced(node::ArgumentNode, ::Type{Union{Preceding, Parent}}) = referenced(node, Parent)


"""
    backward(node[, axis]) -> Vector{AbstractNode}
    backward(f, node[, axis])

Traverse references backward in `axis` order (default: `Preceding`).  By default, `union` all nodes
onto an array.  If `f` is given, the current node and its references are passed in for every node of
which `node` is a data dependecy, and you can do arbitrary things to it.
"""
function backward(node::AbstractNode, axis::Type{<:Reverse} = Preceding)
    result = Vector{AbstractNode}()
    return backward(node, axis) do node, refs
        union!(result, refs)
    end
end

function backward(f, node::AbstractNode, axis::Type{<:Reverse} = Preceding)
    current_refs = Vector{AbstractNode}(referenced(node, axis))
    result = f(node, current_refs)
    
    while !isempty(current_refs)
        node = pop!(current_refs)
        new_refs = referenced(node, axis)
        result = f(node, new_refs)
        union!(current_refs, new_refs)
    end

    return result
end


"""
    dependents(node) -> Vector{<:AbstractNode}

Return all nodes that reference `node`; i.e., all data that immediately depends on it.
"""
function dependents(node::AbstractNode)
    return [f for f in query(node, Following) if node in referenced(f, Preceding)]
    # or: filter(f -> (node in referenced(f, Preceding))::Bool, query(node, Following))
    # an instance of https://github.com/JuliaLang/julia/issues/28889
end



"""
    forward(node) -> Vector{AbstractNode}
    forward(f, node)

Traverse dependencies forward.  By default, `union` all nodes onto an array.  If `f` is given, the
current node and its dependents are passed in for every node is a data dependecy of `node`, and you
can do arbitrary things to it.
"""
function forward(node::AbstractNode)
    result = Vector{AbstractNode}()
    return forward(node) do node, deps
        union!(result, deps)
    end
end

function forward(f, node::AbstractNode)
    current_deps = Vector{AbstractNode}(dependents(node))
    result = f(node, current_deps)
    
    while !isempty(current_deps)
        node = pop!(current_deps)
        new_deps = dependents(node)
        result = f(node, new_deps)
        union!(current_deps, new_deps)
    end

    return result
end








