module NFFT

import Base.ind2sub
using Base.Cartesian

export NFFTPlan, nfft, nfft_adjoint, ndft, ndft_adjoint, nfft_performance,
       sdc

# Some internal documentation (especially for people familiar with the nfft)
#
# - Currently the window cannot be changed and defaults to the kaiser-bessel
#   window. This is done for simplicity and due to the fact that the 
#   kaiser-bessel window usually outperforms any other window
#
# - The window is precomputed during construction of the NFFT plan
#   When performing the nfft convolution, the LUT of the window is used to
#   perform linear interpolation. This approach is reasonable fast and does not
#   require too much memory. There are, however alternatives known that are either 
#   faster or require no extra memory at all.

function window_kaiser_bessel(x,n,m,sigma)
  b = pi*(2-1/sigma)
  arg = m^2-n^2*x^2
  if abs(x) < m/n
    y = sinh(b*sqrt(arg))/sqrt(arg)/pi
  elseif abs(x) > m/n
    y = zero(x)
  else
    y = b/pi
  end
  return y
end

function window_kaiser_bessel_hat(k,n,m,sigma)
  b = pi*(2-1/sigma)
  return besseli(0,m*sqrt(b^2-(2*pi*k/n)^2))
end

type NFFTPlan{D,T}
  N::NTuple{D,Int64}
  M::Int64
  x::Matrix{T}
  m::Int64
  sigma::T
  n::NTuple{D,Int64}
  K::Int64
  windowLUT::Vector{Vector{T}}
  windowHatInvLUT::Vector{Vector{T}}
  tmpVec::Array{Complex{T},D}
end

function NFFTPlan{D,T}(x::Matrix{T}, N::NTuple{D,Int}, m=4, sigma=2.0, K=2000)
  
  if D != size(x,1)
    throw(ArgumentError())
  end

  n = ntuple(d->round(Int,sigma*N[d]), D)

  tmpVec = zeros(Complex{T}, n)

  M = size(x,2)

  # Create lookup table
  
  windowLUT = Array(Vector{T},D)
  for d=1:D
    Z = round(Int,3*K/2)
    windowLUT[d] = zeros(T, Z)
    for l=1:Z
      y = ((l-1) / (K-1)) * m/n[d]
      windowLUT[d][l] = window_kaiser_bessel(y, n[d], m, sigma)
    end
  end

  windowHatInvLUT = Array(Vector{T}, D)
  for d=1:D
    windowHatInvLUT[d] = zeros(T, N[d])
    for k=1:N[d]
      windowHatInvLUT[d][k] = 1. / window_kaiser_bessel_hat(k-1-N[d]/2, n[d], m, sigma)
    end
  end

  NFFTPlan(N, M, x, m, sigma, n, K, windowLUT, windowHatInvLUT, tmpVec )
end

function NFFTPlan{T}(x::Vector{T}, N::Integer, m=4, sigma=2.0)
  NFFTPlan(reshape(x,1,length(x)), (N,), m, sigma)
end

function consistencyCheck{T,D}(p::NFFTPlan{D}, f::AbstractArray{T,D}, fHat::AbstractVector{T})
	if p.N != size(f) || p.M != length(fHat)
		throw(DimensionMismatch("Data is not consistent with NFFTPlan"))
	end
end

### nfft functions ###

function nfft!{T,D}(p::NFFTPlan{D}, f::AbstractArray{T,D}, fHat::StridedVector{T})
  consistencyCheck(p, f, fHat)

  fill!(p.tmpVec, zero(T))
  @inbounds apodization!(p, f, p.tmpVec)
  fft!(p.tmpVec)
  @inbounds convolve!(p, p.tmpVec, fHat)
  return fHat
end

function nfft{T,D}(p::NFFTPlan, f::AbstractArray{T,D})
  fHat = zeros(T, p.M)
  nfft!(p, f, fHat)
  return fHat
end

function nfft{T,D}(x, f::AbstractArray{T,D})
  p = NFFTPlan(x, size(f) )
  return nfft(p, f)
end


function nfft_adjoint!{T,D}(p::NFFTPlan{D}, fHat::AbstractArray{T}, f::StridedArray{T,D})
  consistencyCheck(p, f, fHat)

  @inbounds convolve_adjoint!(p, fHat, p.tmpVec)
  ifft!(p.tmpVec)
  scale!(p.tmpVec, prod(p.n))
  @inbounds apodization_adjoint!(p, p.tmpVec, f)
  return f
end

function nfft_adjoint{T,D}(p::NFFTPlan{D}, fHat::AbstractVector{Complex{T}})
  f = zeros(Complex{T},p.N)
  nfft_adjoint!(p, fHat, f)
  return f
end

function nfft_adjoint{T,D}(x, N::NTuple{D,Int}, fHat::AbstractVector{T})
  p = NFFTPlan(x, N)
  return nfft_adjoint(p, fHat)
end

### ndft functions ###

# fallback for 1D 
function ind2sub{T}(::Array{T,1}, idx::Int)
  idx
end

function ndft{T,D}(plan::NFFTPlan{D}, f::AbstractArray{T,D})
  plan.N == size(f) || throw(DimensionMismatch("Data is not consistent with NFFTPlan"))

  g = zeros(T, plan.M)

  for l=1:prod(plan.N)
    idx = ind2sub(plan.N,l)

    for k=1:plan.M
      arg = zero(T)
      for d=1:D
        arg += plan.x[d,k] * ( idx[d] - 1 - plan.N[d] / 2 )
      end
      g[k] += f[l] * exp(-2*pi*1im*arg)
    end
  end

  return g
end

function ndft_adjoint{T,D}(plan::NFFTPlan{D}, fHat::AbstractArray{T,1})
  plan.M == length(fHat) || throw(DimensionMismatch("Data is not consistent with NFFTPlan"))

  g = zeros(T, plan.N)

  for l=1:prod(plan.N)
    idx = ind2sub(plan.N,l)

    for k=1:plan.M
      arg = zero(T)
      for d=1:D
        arg += plan.x[d,k] * ( idx[d] - 1 - plan.N[d] / 2 )
      end
      g[l] += fHat[k] * exp(2*pi*1im*arg)
    end
  end

  return g
end



### convolve! ###

function convolve!{T}(p::NFFTPlan{1}, g::AbstractVector{T}, fHat::StridedVector{T})
  fill!(fHat, zero(T))
  scale = 1.0 / p.m * (p.K-1)
  n = p.n[1]

  for k=1:p.M # loop over nonequispaced nodes
    c = floor(Int, p.x[k]*n)
    for l=(c-p.m):(c+p.m) # loop over nonzero elements
      gidx = rem(l+n, n) + 1
      idx = abs( (p.x[k]*n - l)*scale ) + 1
      idxL = floor(Int, idx)

      fHat[k] += g[gidx] * (p.windowLUT[1][idxL] + ( idx-idxL ) * (p.windowLUT[1][idxL+1] - p.windowLUT[1][idxL]))
    end
  end
end

@generated function convolve!{T,D}(p::NFFTPlan{D}, g::AbstractArray{T,D}, fHat::StridedVector{T})
	quote
		fill!(fHat, zero(T))
		scale = 1.0 / p.m * (p.K-1)

		for k in 1:p.M
			@nexprs $D d -> xscale_d = p.x[d,k] * p.n[d]
			@nexprs $D d -> c_d = floor(Int, xscale_d)

			@nloops $D l d -> (c_d-p.m):(c_d+p.m) d->begin
				# preexpr
				gidx_d = rem(l_d+p.n[d], p.n[d]) + 1 
				idx = abs( (xscale_d - l_d)*scale ) + 1
				idxL = floor(idx)
				idxInt = Int(idxL)
				tmpWin_d = p.windowLUT[d][idxInt] + ( idx-idxL ) * (p.windowLUT[d][idxInt+1] - p.windowLUT[d][idxInt])
			end begin
				# bodyexpr
				v = @nref $D g gidx
				@nexprs $D d -> v *= tmpWin_d
				fHat[k] += v
			end
		end
	end
end


### convolve_adjoint! ###

function convolve_adjoint!{T}(p::NFFTPlan{1}, fHat::AbstractVector{T}, g::StridedVector{T})
  fill!(g, zero(T))
  scale = 1.0 / p.m * (p.K-1)
  n = p.n[1]

  for k=1:p.M # loop over nonequispaced nodes
    c = round(Int,p.x[k]*n)
    for l=(c-p.m):(c+p.m) # loop over nonzero elements
      gidx = rem(l+n, n) + 1
      idx = abs( (p.x[k]*n - l)*scale ) + 1
      idxL = round(Int, idx)

      g[gidx] += fHat[k] * (p.windowLUT[1][idxL] + ( idx-idxL ) * (p.windowLUT[1][idxL+1] - p.windowLUT[1][idxL]))
    end
  end
end

@generated function convolve_adjoint!{T,D}(p::NFFTPlan{D}, fHat::AbstractVector{T}, g::StridedArray{T,D})
	quote
		fill!(g, zero(T))
		scale = 1.0 / p.m * (p.K-1)

		for k in 1:p.M
			@nexprs $D d -> xscale_d = p.x[d,k] * p.n[d]
			@nexprs $D d -> c_d = floor(Int, xscale_d)

			@nloops $D l d -> (c_d-p.m):(c_d+p.m) d->begin
				# preexpr
				gidx_d = rem(l_d+p.n[d], p.n[d]) + 1 
				idx = abs( (xscale_d - l_d)*scale ) + 1
				idxL = floor(idx)
				idxInt = Int(idxL)
				tmpWin_d = p.windowLUT[d][idxInt] + ( idx-idxL ) * (p.windowLUT[d][idxInt+1] - p.windowLUT[d][idxInt])
			end begin
				# bodyexpr
				v = fHat[k]
				@nexprs $D d -> v *= tmpWin_d
				(@nref $D g gidx) += v
			end
		end
	end
end


### apodization! ###

function apodization!{T}(p::NFFTPlan{1}, f::AbstractVector{T}, g::StridedVector{T})
  n = p.n[1]
  N = p.N[1]
  const offset = round( Int, n - N / 2 ) - 1
  for l=1:N
    g[((l+offset)% n) + 1] = f[l] * p.windowHatInvLUT[1][l]
  end
end

@generated function apodization!{T,D}(p::NFFTPlan{D}, f::AbstractArray{T,D}, g::StridedArray{T,D})
	quote
		@nexprs $D d -> offset_d = round(Int, p.n[d] - p.N[d]/2) - 1

		@nloops $D l f begin
			v = @nref $D f l
			@nexprs $D d -> v *= p.windowHatInvLUT[d][l_d]
			(@nref $D g d -> rem(l_d+offset_d, p.n[d]) + 1) = v
		end
	end
end


### apodization_adjoint! ###

function apodization_adjoint!{T}(p::NFFTPlan{1}, g::AbstractVector{T}, f::StridedVector{T})
  n = p.n[1]
  N = p.N[1]
  const offset = round( Int, n - N / 2 ) - 1
  for l=1:N
    f[l] = g[((l+offset)% n) + 1] * p.windowHatInvLUT[1][l]
  end
end

@generated function apodization_adjoint!{T,D}(p::NFFTPlan{D}, g::AbstractArray{T,D}, f::StridedArray{T,D})
	quote
		@nexprs $D d -> offset_d = round(Int, p.n[d] - p.N[d]/2) - 1

		@nloops $D l f begin
			v = @nref $D g d -> rem(l_d+offset_d, p.n[d]) + 1
			@nexprs $D d -> v *= p.windowHatInvLUT[d][l_d]
			(@nref $D f l) = v
		end
	end
end


function sdc{D,T}(p::NFFTPlan{D,T}; iters=20)
  # Weights for sample density compensation.
  # Uses method of Pipe & Menon, 1999. Mag Reson Med, 186, 179.
  weights = ones(Complex{T}, p.M)
  weights_tmp = similar(weights)
  # Pre-weighting to correct non-uniform sample density
  for i in 1:iters
    p.tmpVec[:] = 0.0
    convolve_adjoint!(p, weights, p.tmpVec)
    weights_tmp[:] = 0.0
    convolve!(p, p.tmpVec, weights_tmp)
    for j in 1:length(weights)
      weights[j] = weights[j] / (abs(weights_tmp[j]) + eps(T))
    end
  end
  # Post weights to correct image scaling
  # This finds c, where ||u - c*v||_2^2 = 0 and then uses
  # c to scale all weights by a scalar factor.
  u = ones(Complex{T}, p.N)
  f = nfft(p, u)
  f = f .* weights # apply weights from above
  v = nfft_adjoint(p, f)
  c = v[:] \ u[:]  # least squares diff
  abs(weights * c[1]) # [1] needed b/c 'c' is a 1x1 Array
end

### performance test ###

function nfft_performance()

  m = 4
  sigma = 2.0

  # 1D

  N = 2^19
  M = N

  x = rand(M) .- 0.5
  fHat = rand(M)*1im

  println("NFFT Performance Test 1D")

  tic()
  p = NFFTPlan(x,N,m,sigma)
  println("initialization")
  toc()

  tic()
  fApprox = nfft_adjoint(p,fHat)
  println("adjoint")
  toc()

  tic()
  fHat2 = nfft(p, fApprox);
  println("trafo")
  toc()

  N = 1024
  M = N*N

  x2 = rand(2,M) .- 0.5
  fHat = rand(M)*1im

  println("NFFT Performance Test 2D")

  tic()
  p = NFFTPlan(x2,(N,N),m,sigma)
  println("initialization")
  toc()

  tic()
  fApprox = nfft_adjoint(p,fHat)
  println("adjoint")
  toc()

  tic()
  fHat2 = nfft(p, fApprox);
  println("trafo")
  toc()
  
  N = 32
  M = N*N*N

  x3 = rand(3,M) .- 0.5
  fHat = rand(M)*1im

  println("NFFT Performance Test 3D")

  tic()
  p = NFFTPlan(x3,(N,N,N),m,sigma)
  println("initialization")
  toc()

  tic()
  fApprox = nfft_adjoint(p,fHat)
  println("adjoint")
  toc()

  tic()
  fHat2 = nfft(p, fApprox);
  println("trafo")
  toc()  

end


function nfft!{T,D}(p::NFFTPlan{1}, f::AbstractArray{T,D}, d::Integer, fHat::StridedArray{T,D})
end

end
