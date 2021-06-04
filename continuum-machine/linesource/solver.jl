using Kinetic, Plots, LinearAlgebra, JLD2, Flux
using ProgressMeter: @showprogress
using Flux: onecold

cd(@__DIR__)
D = Dict{Symbol,Any}()
begin
    D[:matter] = "gas"
    D[:case] = "cavity"
    D[:space] = "2d1f2v"
    D[:flux] = "kfvs"
    D[:collision] = "bgk"
    D[:nSpecies] = 1
    D[:interpOrder] = 2
    D[:limiter] = "vanleer"
    D[:boundary] = "fix"
    D[:cfl] = 0.5
    D[:maxTime] = 1.0

    D[:x0] = -1.5
    D[:x1] = 1.5
    D[:nx] = 40
    D[:y0] = -1.5
    D[:y1] = 1.5
    D[:ny] = 40
    D[:pMeshType] = "uniform"
    D[:nxg] = 0
    D[:nyg] = 0

    D[:umin] = -5.0
    D[:umax] = 5.0
    D[:nu] = 24
    D[:vmin] = -5.0
    D[:vmax] = 5.0
    D[:nv] = 24
    D[:vMeshType] = "rectangle"
    D[:nug] = 0
    D[:nvg] = 0

    D[:knudsen] = 0.005
    D[:mach] = 0.0
    D[:prandtl] = 1.0
    D[:inK] = 0.0
    D[:omega] = 0.81
    D[:alphaRef] = 1.0
    D[:omegaRef] = 0.5

    D[:uLid] = 0.15
    D[:vLid] = 0.0
    D[:tLid] = 1.0
end

ks = SolverSet(D)
ctr, a1face, a2face = init_fvm(ks, ks.ps, :dynamic_array; structarray = true)

s2 = 0.03^2
flr = 0.0001
init_density(x, y) = max(flr, 1.0 / (4.0 * pi * s2) * exp(-(x^2 + y^2) / 4.0 / s2))

function init_field!(ks, ctr, a1face, a2face)
    for i = 1:ks.ps.nx, j = 1:ks.ps.ny
        rho0 = init_density(ks.ps.x[i, j], ks.ps.y[i, j])

        ctr[i, j].prim .= [rho0, 0.0, 0.0, 0.0]
        ctr[i, j].w .= prim_conserve(ctr[i, j].prim, ks.gas.γ)
        ctr[i, j].f .= maxwellian(ks.vs.u, ks.vs.v, ctr[i, j].prim)
    end
    for i in eachindex(a1face)
        a1face[i].fw .= 0.0
        a1face[i].ff .= 0.0
    end
    for i in eachindex(a2face)
        a2face[i].fw .= 0.0
        a2face[i].ff .= 0.0
    end
end

init_field!(ks, ctr, a1face, a2face)

plot_contour(ks, ctr)

function visualize(ks, ctr)
    sol = zeros(ks.ps.nx, ks.ps.ny, 4)
    for i = 1:ks.ps.nx, j = 1:ks.ps.ny
        sol[i, j, :] .= ctr.prim[i, j]
        sol[i, j, 4] = 1 / sol[i, j, 4]
    end
    p = [contourf(ks.ps.x[:, 1], ks.ps.y[1, :], sol[:, :, 1]'),
    contourf(ks.ps.x[:, 1], ks.ps.y[1, :], sol[:, :, 2]'),
    contourf(ks.ps.x[:, 1], ks.ps.y[1, :], sol[:, :, 3]'),
    contourf(ks.ps.x[:, 1], ks.ps.y[1, :], sol[:, :, 4]')]
end

p = visualize(ks, ctr)

p[3]

t = 0.0
dt = timestep(ks, ctr, t)
nt = Int(ks.set.maxTime ÷ dt) + 1
res = zero(ks.ib.wL)

@showprogress for iter = 1:10#nt
    reconstruct!(ks, ctr)
    #evolve!(ks, ctr, a1face, a2face, dt; mode = Symbol(ks.set.flux), bc = Symbol(ks.set.boundary))
    
    # horizontal flux
    @inbounds Threads.@threads for j = 1:ks.pSpace.ny
        for i = 2:ks.pSpace.nx
            #=w = (ctr[i-1, j].w .+ ctr[i, j].w) ./ 2
            sw = (ctr[i-1, j].sw .+ ctr[i, j].sw) ./ 2
            gra = (sw[:, 1].^2 + sw[:, 2].^2).^0.5
            prim = conserve_prim(w, ks.gas.γ)
            tau = vhs_collision_time(prim, ks.gas.μᵣ, ks.gas.ω)
            regime = nn([w; gra; tau]) |> onecold=#

            if false#regime == 1
                flux_gks!(
                    a1face[i, j].fw,
                    a1face[i, j].ff,
                    ctr[i-1, j].w .+ ctr[i-1, j].sw[:, 1] .* ks.ps.dx[i-1, j]/2,
                    ctr[i, j].w .- ctr[i, j].sw[:, 1] .* ks.ps.dx[i, j]/2,
                    ks.vSpace.u,
                    ks.vSpace.v,
                    ks.gas.K,
                    ks.gas.γ,
                    ks.gas.μᵣ,
                    ks.gas.ω,
                    dt,
                    ks.ps.dx[i-1, j]/2,
                    ks.ps.dx[i, j]/2,
                    a1face[i, j].len,
                    ctr[i-1, j].sw[:, 1],
                    ctr[i, j].sw[:, 1],
                )
            else
                flux_kfvs!(
                    a1face[i, j].fw,
                    a1face[i, j].ff,
                    ctr[i-1, j].f,
                    ctr[i, j].f,
                    ks.vSpace.u,
                    ks.vSpace.v,
                    ks.vSpace.weights,
                    dt,
                    a1face[i, j].len,
                )
            end
        end
    end
    
    # vertical flux
    vn = ks.vSpace.v
    vt = -ks.vSpace.u
    @inbounds Threads.@threads for j = 2:ks.pSpace.ny
        for i = 1:ks.pSpace.nx
            #=w = (ctr[i, j-1].w .+ ctr[i, j].w) ./ 2
            sw = (ctr[i, j-1].sw .+ ctr[i, j].sw) ./ 2
            gra = (sw[:, 1].^2 + sw[:, 2].^2).^0.5
            prim = conserve_prim(w, ks.gas.γ)
            tau = vhs_collision_time(prim, ks.gas.μᵣ, ks.gas.ω)
            regime = nn([w; gra; tau]) |> onecold=#

            wL = KitBase.local_frame(ctr[i, j-1].w, 0., 1.)
            wR = KitBase.local_frame(ctr[i, j].w, 0., 1.)
            swL = KitBase.local_frame(ctr[i, j-1].sw[:, 2], 0., 1.)
            swR = KitBase.local_frame(ctr[i, j].sw[:, 2], 0., 1.)

            if false#regime == 1
                flux_gks!(
                    a2face[i, j].fw,
                    a2face[i, j].ff,
                    wL .+ swL .* ks.ps.dy[i, j-1]/2,
                    wR .- swR .* ks.ps.dy[i, j]/2,
                    vn,
                    vt,
                    ks.gas.K,
                    ks.gas.γ,
                    ks.gas.μᵣ,
                    ks.gas.ω,
                    dt,
                    ks.ps.dy[i, j-1]/2,
                    ks.ps.dy[i, j]/2,
                    a2face[i, j].len,
                    swL,
                    swR,
                )
            else
                KitBase.flux_kfvs!(
                    a2face[i, j].fw,
                    a2face[i, j].ff,
                    ctr[i, j-1].f,
                    ctr[i, j].f,
                    vn,
                    vt,
                    ks.vSpace.weights,
                    dt,
                    a2face[i, j].len,
                )
            end

            a2face[i, j].fw .= KitBase.global_frame(a2face[i, j].fw, 0., 1.)
        end
    end
    
    update!(ks, ctr, a1face, a2face, dt, res; coll = Symbol(ks.set.collision), bc = Symbol(ks.set.boundary))

    t += dt
end

plot_contour(ks, ctr)
