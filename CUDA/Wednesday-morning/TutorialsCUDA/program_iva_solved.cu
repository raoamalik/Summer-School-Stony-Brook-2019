#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>
#include <math.h>
#include <sys/time.h>

//-----------------------------------------------------------------------------
// GpuConstantsPackage: a struct to hold many constants (including pointers
//                      to allocated memory on the device) that can be
//                      uploaded all at once.  Placing this in the "constants
//                      cache" is a convenient and performant way of handling
//                      constant information on the GPU.
//-----------------------------------------------------------------------------
struct GpuConstantsPackage {
  int     nparticle;
  int*    partType;
  int*    gblbpos;
  float*  partX;
  float*  partY;
  float*  partZ;
  float*  partFrcX;
  float*  partFrcY;
  float*  partFrcZ;
  float*  partQ;
  float*  Etot;
};
typedef struct GpuConstantsPackage cribSheet;

// This device constant is available to all functions in this CUDA unit
__device__ __constant__ cribSheet cSh;

//-----------------------------------------------------------------------------
// GpuMirroredInt: a struct holding mirrored int data on both the CPU and the
//                 GPU.  Functions below will operate on this struct
//                 (because this isn't a workshop on C++)
//-----------------------------------------------------------------------------
struct GpuMirroredInt {
  int len;          // Length of the array (again, this is not a C++ course)
  int IsPinned;     // "Pinned" memory is best for Host <= => GPU transfers.
                    //   In fact, if non-pinned memory is transferred to the
                    //   GPU from the host, a temporary allocation of pinned
                    //   memory will be created and then destroyed.  Pinned
                    //   memory is not host-pageable, but the only performance
                    //   implication is that creating lots of pinned memory
                    //   may make it harder for the host OS to manage large
                    //   memory jobs.
  int* HostData;    // Pointer to allocated memory on the host
  int* DevcData;    // Pointer to allocated memory on the GPU.  Note that the
                    //   host can know what the address of memory on the GPU
                    //   is, but it cannot simply de-reference that pointer
                    //   in host code.
};
typedef struct GpuMirroredInt gpuInt;

//-----------------------------------------------------------------------------
// GpuMirroredInt: a struct holding mirrored fp32 data on both the CPU and the
//                 GPU.  Functions below will operate on this struct
//                 (because this isn't a workshop on C++)
//-----------------------------------------------------------------------------
struct GpuMirroredFloat {
  int len;          // Length of the array (again, this is not a C++ course)
  int IsPinned;     // "Pinned" memory is best for Host <= => GPU transfers.
                    //   In fact, if non-pinned memory is transferred to the
                    //   GPU from the host, a temporary allocation of pinned
                    //   memory will be created and then destroyed.  Pinned
                    //   memory is not host-pageable, but the only performance
                    //   implication is that creating lots of pinned memory
                    //   may make it harder for the host OS to manage large
                    //   memory jobs.
  float* HostData;  // Pointer to allocated memory on the host
  float* DevcData;  // Pointer to allocated memory on the GPU.  Note that the
                    //   host can know what the address of memory on the GPU
                    //   is, but it cannot simply de-reference that pointer
                    //   in host code.
};
typedef struct GpuMirroredFloat gpuFloat;

//-----------------------------------------------------------------------------
// InitializeForces: kernel to set all forces in device memory to zero
//-----------------------------------------------------------------------------
__global__ void InitializeForces()
{
  int i;

  i = (blockIdx.x * blockDim.x) + threadIdx.x;
  while (i < cSh.nparticle) {
    cSh.partFrcX[i] = (float)0.0;
    cSh.partFrcY[i] = (float)0.0;
    cSh.partFrcZ[i] = (float)0.0;
    i += gridDim.x * blockDim.x;
  }
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    int nstripes = (cSh.nparticle + 31) / 32;
    cSh.gblbpos[0] = nstripes - (gridDim.x * (blockDim.x / 32)) - 1;
  }
}

//-----------------------------------------------------------------------------
// ParticleSimulator: run a rudimentary simulation of particles
//-----------------------------------------------------------------------------
__global__ void ParticleSimulator()
{
  int i;
  
  int warpIdx = threadIdx.x / 32;
  int tgx = (threadIdx.x & 31);

  // Expanding the earlier method, using a warp counter in global
  float qq = (float)0.0;
  int nstripes = (cSh.nparticle + 31) / 32;
  int bpos = nstripes - (blockIdx.x * (blockDim.x / 32)) - warpIdx - 1;
  while (bpos >= 0) {

    // Read 32 particles into registers rather than __shared__ memory.
    int prtclIdx = 32*bpos + tgx;
    float pX, pY, pZ, pQ;
    if (prtclIdx < cSh.nparticle) {
      pX = cSh.partX[prtclIdx];
      pY = cSh.partY[prtclIdx];
      pZ = cSh.partZ[prtclIdx];
      pQ = cSh.partQ[prtclIdx];
    }
    else {
      pX = (float)10000.0 + (float)(prtclIdx);
      pY = (float)10000.0 + (float)(prtclIdx);
      pZ = (float)10000.0 + (float)(prtclIdx);
      pQ = (float)0.0;
    }
    
   // Loop over all particle pairs in the lower half triangle as before
    int tpos = 0;
    while (tpos <= bpos) {

      // Initialize particles as in the outer loop
      int prtclIdx = 32*tpos + tgx;
      float tX, tY, tZ, tQ;
      if (prtclIdx < cSh.nparticle) {
        tX = cSh.partX[prtclIdx];
        tY = cSh.partY[prtclIdx];
        tZ = cSh.partZ[prtclIdx];
        tQ = cSh.partQ[prtclIdx];
      }
      else {

        // The offsets for particle positions must run along a different
        // (parallel, but distinct) line so that not even dummy particles
        // can ever occupy the same positions and cause a divide-by-zero.
        // As before, the charge of the dummy particles is zero.
        tX = (float)10100.0 + (float)(prtclIdx);
        tY = (float)10200.0 + (float)(prtclIdx);
        tZ = (float)10300.0 + (float)(prtclIdx);
        tQ = (float)0.0;
      }

      // Initialize tile force accumulators
      float sfpX = (float)0.0;
      float sfpY = (float)0.0;
      float sfpZ = (float)0.0;
      float sftX = (float)0.0;
      float sftY = (float)0.0;
      float sftZ = (float)0.0;

      // Indexing gets a bit more complex.  Again, if we are on a
      // diagonal tile skip the first iteration of the loop, as
      // boths sets of 32 particles are the same.
      int imin = (bpos == tpos);
      float anti2xCountingFactor = (bpos == tpos) ? (float)0.5 : (float)1.0;
      for (i = imin; i < 32; i++) {

	// Find the thread to query
        int j = tgx + i;
        j -= (j >= 32) * 32;

	// Compute the interaction
        float dx    = __shfl_sync(0xffffffff, tX, j) - pX;
        float dy    = __shfl_sync(0xffffffff, tY, j) - pY;
        float dz    = __shfl_sync(0xffffffff, tZ, j) - pZ;
        float r2    = dx*dx + dy*dy + dz*dz;
        float r     = sqrt(r2);
        float qfac  = anti2xCountingFactor *
                      __shfl_sync(0xffffffff, tQ, j) * pQ;
        qq         += qfac / sqrt(r2);

	// Log the interaction on this thread
	float fmag = qfac / (r2 * r);
	float fx = dx * fmag;
	float fy = dy * fmag;
	float fz = dz * fmag;
	sfpX -= fx;
	sfpY -= fy;
	sfpZ -= fz;

	// Find the other thread that queried this one.
	// __shfl_sync contains a warp synchronization
	// instruction, so no __syncwarp() is needed.
	int k = tgx - i;
	k += (k < 0) * 32;
	sftX += __shfl_sync(0xffffffff, fx, k);
	sftY += __shfl_sync(0xffffffff, fy, k);
	sftZ += __shfl_sync(0xffffffff, fz, k);
      }

       // Contribute the tile force accumulations atomically to global memory
      // (DRAM).  This is only about 2x slower than atomic accumulation to
      // __shared__.  Accumulating things like this atomically to __shared__
      // would make the kernel run only about 30% slower than accumulating
      // them in an unsafe manner, willy-nilly.  Fast atomics to global are
      // a tremendous accomplishment by NVIDIA engineers!
      //
      // Note, the correspondence between 32*bpos + tgx or 32*tpos + tgx
      // and 32*warpIdx + tgx.  32*warpIdx + tgx is, again, threadIdx.x.
      atomicAdd(&cSh.partFrcX[32*bpos + tgx], sfpX);
      atomicAdd(&cSh.partFrcY[32*bpos + tgx], sfpY);
      atomicAdd(&cSh.partFrcZ[32*bpos + tgx], sfpZ);
      atomicAdd(&cSh.partFrcX[32*tpos + tgx], sftX);
      atomicAdd(&cSh.partFrcY[32*tpos + tgx], sftY);
      atomicAdd(&cSh.partFrcZ[32*tpos + tgx], sftZ);

      // Increment the tile counter
      tpos++;
    }

    // Increment stripe counter
    if (tgx == 0) {
      bpos = atomicAdd(&cSh.gblbpos[0], -1);
    }
    bpos = __shfl_sync(0xffffffff, bpos, 0);
  }
  
  // Reduce the energy contributions in each warp.
  // Add the warp contribution to the global sum.
  qq += __shfl_down_sync(0xffffffff, qq, 16);
  qq += __shfl_down_sync(0xffffffff, qq,  8);
  qq += __shfl_down_sync(0xffffffff, qq,  4);
  qq += __shfl_down_sync(0xffffffff, qq,  2);
  qq += __shfl_down_sync(0xffffffff, qq,  1);
  if (tgx == 0) {
    atomicAdd(&cSh.Etot[0], qq);
  }
}

//-----------------------------------------------------------------------------
// CreateGpuInt: constructor function for allocating memory in a gpuInt
//               instance.
//
// Arguments:
//   len:      the length of array to allocate
//   pin:      flag to have the memory pinned (non-pageable on the host side
//             for optimal transfer speed to the device)
//-----------------------------------------------------------------------------
gpuInt CreateGpuInt(int len, int pin)
{
  gpuInt G;

  G.len = len;
  G.IsPinned = pin;
  
  // Now that the official length is recorded, upgrade the real length
  // to the next convenient multiple of 128, so as to always allocate
  // GPU memory in 512-byte blocks.  This is for alignment purposes,
  // and keeping host to device transfers in line.
  len = ((len + 127) / 128) * 128;
  if (pin == 1) {
    cudaHostAlloc((void **)&G.HostData, len * sizeof(int),
                  cudaHostAllocMapped);
  }
  else {
    G.HostData = (int*)malloc(len * sizeof(int));
  }
  cudaMalloc((void **)&G.DevcData, len * sizeof(int));
  memset(G.HostData, 0, len * sizeof(int));
  cudaMemset((void *)G.DevcData, 0, len * sizeof(int));

  return G;
}

//-----------------------------------------------------------------------------
// DestroyGpuInt: destructor function for freeing memory in a gpuInt
//                instance.
//-----------------------------------------------------------------------------
void DestroyGpuInt(gpuInt *G)
{
  if (G->IsPinned == 1) {
    cudaFreeHost(G->HostData);
  }
  else {
    free(G->HostData);
  }
  cudaFree(G->DevcData);
}

//-----------------------------------------------------------------------------
// UploadGpuInt: upload an integer array from the host to the device.
//-----------------------------------------------------------------------------
void UploadGpuInt(gpuInt *G)
{
  cudaMemcpy(G->DevcData, G->HostData, G->len * sizeof(int),
             cudaMemcpyHostToDevice);
}

//-----------------------------------------------------------------------------
// DownloadGpuInt: download an integer array from the host to the device.
//-----------------------------------------------------------------------------
void DownloadGpuInt(gpuInt *G)
{
  cudaMemcpy(G->HostData, G->DevcData, G->len * sizeof(int),
             cudaMemcpyHostToDevice);
}

//-----------------------------------------------------------------------------
// CreateGpuFloat: constructor function for allocating memory in a gpuFloat
//                 instance.
//
// Arguments:
//   len:      the length of array to allocate
//   pin:      flag to have the memory pinned (non-pageable on the host side
//             for optimal transfer speed ot the device)
//-----------------------------------------------------------------------------
gpuFloat CreateGpuFloat(int len, int pin)
{
  gpuFloat G;

  G.len = len;
  G.IsPinned = pin;
  
  // Now that the official length is recorded, upgrade the real length
  // to the next convenient multiple of 128, so as to always allocate
  // GPU memory in 512-byte blocks.  This is for alignment purposes,
  // and keeping host to device transfers in line.
  len = ((len + 127) / 128) * 128;
  if (pin == 1) {
    cudaHostAlloc((void **)&G.HostData, len * sizeof(float),
                  cudaHostAllocMapped);
  }
  else {
    G.HostData = (float*)malloc(len * sizeof(float));
  }
  cudaMalloc((void **)&G.DevcData, len * sizeof(float));
  memset(G.HostData, 0, len * sizeof(float));
  cudaMemset((void *)G.DevcData, 0, len * sizeof(float));

  return G;
}

//-----------------------------------------------------------------------------
// DestroyGpuFloat: destructor function for freeing memory in a gpuFloat
//                  instance.
//-----------------------------------------------------------------------------
void DestroyGpuFloat(gpuFloat *G)
{
  if (G->IsPinned == 1) {
    cudaFreeHost(G->HostData);
  }
  else {
    free(G->HostData);
  }
  cudaFree(G->DevcData);
}

//-----------------------------------------------------------------------------
// UploadGpuFloat: upload an float array from the host to the device.
//-----------------------------------------------------------------------------
void UploadGpuFloat(gpuFloat *G)
{
  cudaMemcpy(G->DevcData, G->HostData, G->len * sizeof(float),
             cudaMemcpyHostToDevice);
}

//-----------------------------------------------------------------------------
// DownloadGpuFloat: download an float array from the host to the device.
//-----------------------------------------------------------------------------
void DownloadGpuFloat(gpuFloat *G)
{
  cudaMemcpy(G->HostData, G->DevcData, G->len * sizeof(float),
             cudaMemcpyHostToDevice);
}

//-----------------------------------------------------------------------------
// main
//-----------------------------------------------------------------------------
int main()
{
  int i, j, k, np;
  struct timeval timings[4];
  gpuInt gpos;
  gpuFloat particleXcoord, particleYcoord, particleZcoord, particleCharge;
  gpuFloat particleXfrc, particleYfrc, particleZfrc;
  gpuFloat etot;

  // Start timing
  gettimeofday(&timings[0], NULL);
  
  // Create a small array of particles and populate it
  const int pdim = 64;
  particleXcoord = CreateGpuFloat(pdim * pdim * pdim, 1);
  particleYcoord = CreateGpuFloat(pdim * pdim * pdim, 1);
  particleZcoord = CreateGpuFloat(pdim * pdim * pdim, 1);
  particleXfrc   = CreateGpuFloat(pdim * pdim * pdim, 1);
  particleYfrc   = CreateGpuFloat(pdim * pdim * pdim, 1);
  particleZfrc   = CreateGpuFloat(pdim * pdim * pdim, 1);
  particleCharge = CreateGpuFloat(pdim * pdim * pdim, 1);

  // Allocate and initialize the total energy
  // accumulator on the host and on the device.
  etot = CreateGpuFloat(1, 1);
  gpos = CreateGpuInt(1, 1);
  
  // Initialize random number generator.  srand() SEEDS the generator,
  // thereafter each call to rand() will return a different number.
  // This is a reeally bad generator (much better methods with longer
  // periods before they start looping back over the same sequence are
  // available).
  srand(62052);
  
  // Allocate for many particles in a perturbed lattice (to ensure
  // that none are going to get too close to one another)
  float* xcrd = particleXcoord.HostData;
  float* ycrd = particleYcoord.HostData;
  float* zcrd = particleZcoord.HostData;
  float* qval = particleCharge.HostData;
  np = pdim * pdim * pdim;
  int prcon = 0;
  for (i = 0; i < pdim; i++) {
    double di = (double)i + 0.2;
    for (j = 0; j < pdim; j++) {
      double dj = (double)j + 0.2;
      for (k = 0; k < pdim; k++) {
        double dk = (double)k + 0.2;
        xcrd[prcon] = di + (0.6 * (double)rand() / (double)RAND_MAX);
        ycrd[prcon] = dj + (0.6 * (double)rand() / (double)RAND_MAX);
        zcrd[prcon] = dk + (0.6 * (double)rand() / (double)RAND_MAX);
        qval[prcon] = 0.5 - rand() / (double)RAND_MAX;
	prcon++;
      }
    }
  }
  
  // Start timing
  gettimeofday(&timings[1], NULL);
  
  // Compute the result on the CPU
  printf("Compute the CPU result:\n");
  double qqnrg = 0.0;
  float* xfrc = particleXfrc.HostData;
  float* yfrc = particleYfrc.HostData;
  float* zfrc = particleZfrc.HostData;
  for (i = 0; i < np; i++) {
    for (j = 0; j < i; j++) {
      float dx = xcrd[j] - xcrd[i];
      float dy = ycrd[j] - ycrd[i];
      float dz = zcrd[j] - zcrd[i];
      float r2 = dx*dx + dy*dy + dz*dz;
      float r  = sqrt(r2);
      float qfac = qval[i] * qval[j];
      float fmag = qfac / (r2 * r);
      xfrc[i] -= dx * fmag;
      yfrc[i] -= dy * fmag;
      zfrc[i] -= dz * fmag;
      xfrc[j] += dx * fmag;
      yfrc[j] += dy * fmag;
      zfrc[j] += dz * fmag;
      qqnrg += qfac / r;
    }
    if ((i & 31) == 0) {
      fprintf(stderr, "\rComputing for particle %7d / %7d", i, np);
      fflush(stderr);
    }
  }
  printf("\n");
  printf("CPU calculated energy = %9.4lf\n", qqnrg);
  for (i = 0; i < np; i += np/32) {
    printf("CPU force [ %7d ] = %9.4f %9.4f %9.4f\n", i, xfrc[i], yfrc[i],
	   zfrc[i]);
  }

  // Wipe the host-side forces clean, just
  // to be certain the GPU is solving them
  for (i = 0; i < np; i++) {
    xfrc[i] = (float)0.0;
    yfrc[i] = (float)0.0;
    zfrc[i] = (float)0.0;
  }

  // Start timing
  gettimeofday(&timings[2], NULL);
  
  // Stage critical constants--see cribSheet struct instance cSh above.
  cribSheet cnstage;
  cnstage.nparticle = np;
  cnstage.gblbpos   = gpos.DevcData;
  cnstage.partX     = particleXcoord.DevcData;
  cnstage.partY     = particleYcoord.DevcData;
  cnstage.partZ     = particleZcoord.DevcData;
  cnstage.partFrcX  = particleXfrc.DevcData;
  cnstage.partFrcY  = particleYfrc.DevcData;
  cnstage.partFrcZ  = particleZfrc.DevcData;
  cnstage.partQ     = particleCharge.DevcData;
  cnstage.Etot      = etot.DevcData; 

  // Upload all data to the device--note that forces are not getting
  // uploaded, as the memory is already allocated.  The forces will
  // be initialized and computed on the device.
  UploadGpuFloat(&particleXcoord);
  UploadGpuFloat(&particleYcoord);
  UploadGpuFloat(&particleZcoord);
  UploadGpuFloat(&particleCharge);

  // Upload the constants to the constants cache
  cudaMemcpyToSymbol(cSh, &cnstage, sizeof(cribSheet));  
  
  // Initialize energy and forces, then run the calculation on the
  // GPU.  The number of blocks and threads count in each kernel
  // must be consistent, as there is a global counter being set in
  // the initialization kernel based on the launch bounds.
  etot.HostData[0] = 0.0;
  UploadGpuFloat(&etot);
  int nblocks = 80;
  InitializeForces<<<nblocks, 1024>>>();
  ParticleSimulator<<<nblocks, 1024>>>();
  
  // Download the total energy
  DownloadGpuFloat(&etot);
  DownloadGpuFloat(&particleXfrc);
  DownloadGpuFloat(&particleYfrc);
  DownloadGpuFloat(&particleZfrc);
  
  // Device synchronization was handled by the download.  Print the output.
  printf("GPU calculated energy = %10.4f\n", etot.HostData[0]);
  for (i = 0; i < np; i += np/32) {
    printf("GPU force [ %7d ] = %9.4f %9.4f %9.4f\n", i, xfrc[i], yfrc[i],
	   zfrc[i]);
  }
  
  // Time for GPU execution (including data transfer)
  gettimeofday(&timings[3], NULL);

  // Report timings
  printf("\n");
  double tts = timings[1].tv_sec - timings[0].tv_sec +
               (1.0e-6)*(timings[1].tv_usec - timings[0].tv_usec);
  printf("Setup time :: %10.4f s\n", tts);
  tts = timings[2].tv_sec - timings[1].tv_sec +
        (1.0e-6)*(timings[2].tv_usec - timings[1].tv_usec);
  printf("CPU solver :: %10.4f s\n", tts);
  tts = timings[3].tv_sec - timings[2].tv_sec +
        (1.0e-6)*(timings[3].tv_usec - timings[2].tv_usec);
  printf("GPU kernel :: %10.4f s\n", tts);
  
  return 0;
}
