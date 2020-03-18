# Code derived from Robin Deits' RegionTrees and AdaptiveDistanceFields
# The RegionTrees.jl package is licensed under the MIT "Expat" License
# The AdaptiveDistanceFields.jl package is licensed under the MIT "Expat" License

# this is designed to avoid allocation of a full octtree and generate a mesh
# while sampling

function vertices(h::HyperRectangle, ::Type{SV}) where SV
    o = SV(h.origin...)
    w = SV(h.widths...)
    @inbounds (o,
     o.+SV(w[1],0,0),
     o.+SV(w[1],w[2],0),
     o.+SV(0,w[2],0),
     o.+SV(0,0,w[3]),
     o.+SV(w[1],0,w[3]),
     o.+w,
     o.+SV(0,w[2],w[3]))
end

function face_center_vertices(h::HyperRectangle)
    SV = SVector{3,Float64}
    o = SV(h.origin...)
    w = SV(h.widths...)
    hw = w.*0.5
    (SV(center(h)...),
     o.+SV(hw[1],hw[2],    0),
     o.+SV(hw[1],    0,hw[3]),
     o.+SV(0    ,hw[2],hw[3]),
     o.+SV(hw[1],hw[2], w[3]),
     o.+SV(hw[1], w[2],hw[3]),
     o.+SV( w[1],hw[2],hw[3]))
end

center(rect::HyperRectangle) = rect.origin + 0.5 * rect.widths

function octsplit(h::HyperRectangle)
    ET = eltype(h.origin)
    VT = Vec{3,ET}
    z = zero(ET)
    hw = h.widths
    nw = h.widths.*ET(0.5)
    no = h.origin
    @inbounds begin
        (HyperRectangle(no, nw),
        HyperRectangle(no.+nw, nw),
        HyperRectangle(no.+VT(nw[1],z,z), nw),
        HyperRectangle(no.+VT(z,nw[2],z), nw),
        HyperRectangle(no.+VT(z,z,nw[3]), nw),
        HyperRectangle(no.+VT(nw[1],nw[2],z), nw),
        HyperRectangle(no.+VT(nw[1],z,nw[3]), nw),
        HyperRectangle(no.+VT(z,nw[2],nw[3]), nw),
        HyperRectangle(no.+VT(z,z,nw[3]), nw))
    end
end

function get_iso_vals(f, val_store, points::NTuple{N,T}) where {N, T}
    @inbounds begin
        return ntuple(N) do i
            get_iso_vals(f,val_store,points[i])
        end
    end
end

function get_iso_vals(f, val_store, pt)
    # tuples are faster to hash than SVec
    key_tup = pt.data # tuple in SVectors/GeometryTypes, probably shoudl make more generic
    if haskey(val_store,key_tup)
        val_store[key_tup]
    else
        val_store[key_tup] = f(pt)
    end
end

@inline function _get_interpindex(iso_vals, iso)
    cubeindex = iso_vals[1] < iso ? 0x01 : 0x00
    iso_vals[2] < iso && (cubeindex |= 0x02)
    iso_vals[3] < iso && (cubeindex |= 0x04)
    iso_vals[4] < iso && (cubeindex |= 0x08)
    iso_vals[5] < iso && (cubeindex |= 0x10)
    iso_vals[6] < iso && (cubeindex |= 0x20)
    iso_vals[7] < iso && (cubeindex |= 0x40)
    cubeindex
end

"""
    _get_cubeindex_pos(iso_vals, iso)

given `iso_vals` and iso, return an 8 bit value corresponding
to each corner of a cube. In each bit position,
0 indicates in the isosurface and 1 indicates outside the surface,
where the sign convention indicates positive inside the surface
"""
@inline function _get_interpindex_pos(iso_vals, iso)
    cubeindex = iso_vals[1] > iso ? 0x01 : 0x00
    iso_vals[2] > iso && (cubeindex |= 0x02)
    iso_vals[3] > iso && (cubeindex |= 0x04)
    iso_vals[4] > iso && (cubeindex |= 0x08)
    iso_vals[5] > iso && (cubeindex |= 0x10)
    iso_vals[6] > iso && (cubeindex |= 0x20)
    iso_vals[7] > iso && (cubeindex |= 0x40)
    cubeindex
end


function isosurface(f::Function, method::AdaptiveMarchingCubes, ::Type{VertType}=SVector{3,Float64}, ::Type{FaceType}=SVector{3, Int};
                    origin=VertType(-1,-1,-1), widths=VertType(2,2,2)) where {VertType, FaceType}

    ET = eltype(VertType)

    # arrays for vertices and faces
    vts = VertType[]
    fcs = FaceType[]

    # refinement queue
    refinement_queue = HyperRectangle{3,ET}[HyperRectangle{3,ET}(origin,widths)]

    val_store = Dict{NTuple{3,ET},ET}();

    @inbounds while true

        if isempty(refinement_queue)
            break
        end

        cell = pop!(refinement_queue)
        points = vertices(cell, VertType)

        iso_vals = get_iso_vals(f,val_store,points)

        # iso_vals = (f(points[1]),
        #             f(points[2]),
        #             f(points[3]),
        #             f(points[4]),
        #             f(points[5]),
        #             f(points[6]),
        #             f(points[7]),
        #             f(points[8]))

        #Determine the index into the edge table which
        #tells us which vertices are inside of the surface
        cubeindex = method.insidepositive ? _get_cubeindex_pos(iso_vals, method.iso) : _get_cubeindex(iso_vals, method.iso)
        #interpindex = method.insidepositive ? _get_interpindex_pos(iso_vals, method.iso) : _get_interpindex(iso_vals, method.iso)

        value_interp = sum(iso_vals)*0.125
        value_true = get_iso_vals(f, val_store, center(cell))

        if (cubeindex == 0xff && value_true < 0) || (iszero(cubeindex) && value_true > 0)
            continue
        elseif minimum(cell.widths) > method.atol && !isapprox(value_interp, value_true, rtol=method.rtol, atol=method.atol)
            append!(refinement_queue, octsplit(cell))
        else
            # Find the vertices where the surface intersects the cube
            # The underlying space is non-linear so there will be error otherwise
            vertlist = find_vertices_interp(points, iso_vals, cubeindex, method.iso, method.eps)

            # Create the triangle
            method.reduceverts && _mc_unique_triangles!(vts, fcs, vertlist, cubeindex, FaceType)
            !method.reduceverts && _mc_create_triangles!(vts, fcs, vertlist, cubeindex, FaceType)
        end
    end
    vts,fcs
end


function vertices_mt(h::HyperRectangle, ::Type{SV}) where SV
    o = SV(h.origin...)
    w = SV(h.widths...)
    @inbounds (o,
     o.+SV(0,w[2],0),
     o.+SV(w[1],w[2],0),
     o.+SV(w[1],0,0),
     o.+SV(0,0,w[3]),
     o.+SV(0,w[2],w[3]),
     o.+w,
     o.+SV(w[1],0,w[3]))
end

@inline function vertPos(e, width, origin, vals::V, iso, eps, ::Type{VertType}) where {V, VertType}
    T = eltype(vals)

    ixs     = voxEdgeCrnrs[e]
    srcVal  = vals[ixs[1]]
    tgtVal  = vals[ixs[2]]
    a       = min(max((iso-srcVal)/(tgtVal-srcVal), eps), one(T)-eps)
    b       = one(T)-a
    c1 = voxCrnrPos(VertType)[ixs[1]]
    c2 = voxCrnrPos(VertType)[ixs[2]]

    (c1 .* b + c2.* a) .* width .+ origin
end


@inline function getVertId(e, width, vals, iso::Real, origin, vtsAry::Vector, vertex_store, eps::Real)

    VertType = eltype(vtsAry)

    # calculate vert position
    v = vertPos(e, width, origin, vals, iso, eps, VertType)
    vt_key = v.data
    if haskey(vertex_store, vt_key)
        return vertex_store[vt_key]
    else
        push!(vtsAry, v)
        l = length(vtsAry)
        vertex_store[vt_key] = l
        return l
    end
end

"""
    procVox(vals, iso::Real, x, y, z, nx, ny,
                    vts::Dict, vtsAry::Vector, fcs::Vector,
                    eps::Real)

Processes a voxel, adding any new vertices and faces to the given
containers as necessary.
"""
function procVox(vals, iso::Real, width, origin, vtsAry::Vector, vertex_store, fcs::Vector,
                 eps::Real, cubeindex)
    VertType = eltype(vtsAry)
    FaceType = eltype(fcs)
    # check each sub-tetrahedron in the voxel
    @inbounds for i = 1:6
        tIx = tetIx(i, cubeindex)
        (tIx == 0x00 || tIx == 0x0f) && continue

        e = tetTri[tIx]

        # add the face to the list
        push!(fcs, FaceType(
                    getVertId(voxEdgeId(i, e[1]), width, vals, iso, origin, vtsAry, vertex_store, eps),
                    getVertId(voxEdgeId(i, e[2]), width, vals, iso, origin, vtsAry, vertex_store, eps),
                    getVertId(voxEdgeId(i, e[3]), width, vals, iso, origin, vtsAry, vertex_store, eps)))

        # bail if there are no more faces
        iszero(e[4]) && continue
        push!(fcs, FaceType(
                    getVertId(voxEdgeId(i, e[4]), width, vals, iso, origin, vtsAry, vertex_store, eps),
                    getVertId(voxEdgeId(i, e[5]), width, vals, iso, origin, vtsAry, vertex_store, eps),
                    getVertId(voxEdgeId(i, e[6]), width, vals, iso, origin, vtsAry, vertex_store, eps)))
    end
end

function isosurface(f::Function, method::AdaptiveMarchingTetrahedra, ::Type{VertType}=SVector{3,Float64}, ::Type{FaceType}=SVector{3, Int};
                    origin=VertType(-1,-1,-1), widths=VertType(2,2,2)) where {VertType, FaceType}

    ET = eltype(VertType)

    # arrays for vertices and faces
    vts = VertType[]
    fcs = FaceType[]

    # refinement queue
    refinement_queue = HyperRectangle{3,ET}[HyperRectangle{3,ET}(origin,widths)]

    val_store = Dict{NTuple{3,ET},ET}();
    vertex_store = Dict{NTuple{3,ET},ET}();

    @inbounds while true

        if isempty(refinement_queue)
            break
        end

        cell = pop!(refinement_queue)
        points = vertices_mt(cell, VertType)

        iso_vals = get_iso_vals(f,val_store,points)

        #Determine the index into the edge table which
        #tells us which vertices are inside of the surface
        cubeindex = method.insidepositive ? _get_cubeindex_pos(iso_vals, method.iso) : _get_cubeindex(iso_vals, method.iso)
        #interpindex = method.insidepositive ? _get_interpindex_pos(iso_vals, method.iso) : _get_interpindex(iso_vals, method.iso)

        value_interp = sum(iso_vals)*0.125
        value_true = get_iso_vals(f, val_store, center(cell))

        if (cubeindex == 0xff && value_true < 0) || (iszero(cubeindex) && value_true > 0)
            continue
        elseif minimum(cell.widths) > method.atol && !isapprox(value_interp, value_true, rtol=method.rtol, atol=method.atol)
            append!(refinement_queue, octsplit(cell))
        else
            # Find the vertices where the surface intersects the cube
            # The underlying space is non-linear so there will be error otherwise
            procVox(iso_vals, method.iso, cell.widths, cell.origin, vts, vertex_store, fcs, method.eps, cubeindex)
        end
    end
    vts,fcs
end