/*
 *
 * histogramPrivatizedPerThread32.cuh
 *
 * Implementation of histogram that uses 8-bit privatized counters
 * and uses 32-bit increments to process them.
 *
 * Requires: SM 1.2, for shared atomics.
 *
 * Copyright (c) 2011-2012, Archaea Software, LLC.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions 
 * are met: 
 *
 * 1. Redistributions of source code must retain the above copyright 
 *    notice, this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright 
 *    notice, this list of conditions and the following disclaimer in 
 *    the documentation and/or other materials provided with the 
 *    distribution. 
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

#define CACHE_IN_REGISTER 0

inline __device__ void
incPrivatized32Element( unsigned char pixval, int& cacheIndex, unsigned int& cacheValue )
{
    extern __shared__ unsigned int privHist[];
    unsigned int increment = 1<<8*(pixval&3);
    int index = pixval>>2;
#if CACHE_IN_REGISTER
    if ( index != cacheIndex ) {
        privHist[cacheIndex*blockDim.x+threadIdx.x] = cacheValue;
        cacheIndex = index;
        cacheValue = privHist[index*blockDim.x+threadIdx.x];
    }
    cacheValue += increment;
#else
    privHist[index*blockDim.x+threadIdx.x] += increment;
#endif
}

__global__ void
histogram1DPrivatizedPerThread32(
    unsigned int *pHist,
    const unsigned char *base, size_t N )
{
    extern __shared__ unsigned int privHist[];
    for ( int i = threadIdx.x;
              i < 64*blockDim.x;
              i += blockDim.x ) {
        privHist[i] = 0;
    }
    __syncthreads();
    int cacheIndex = 0;
    unsigned int cacheValue = 0;
    for ( int i = blockIdx.x*blockDim.x+threadIdx.x;
              i < N;
              i += blockDim.x*gridDim.x ) {
        incPrivatized32Element( base[i], cacheIndex, cacheValue );
    }
#if CACHE_IN_REGISTER
    privHist[cacheIndex*blockDim.x+threadIdx.x] = cacheValue;
#endif
    __syncthreads();

#if 0
    for ( int i = 0; i < 32; i++ ) {
        unsigned int *histBase0 = &privHist[i*64+threadIdx.x];
        unsigned int *histBase1 = &privHist[(i+32)*64+threadIdx.x];
        unsigned int my0 = histBase0[0];
        unsigned int my1 = histBase1[0];
        histBase0[0] = (my0 & 0xff00ff)+(my1 & 0xff00ff);
        my0 >>= 8;
        my1 >>= 8;
        histBase1[0] = (my0 & 0xff00ff)+(my1 & 0xff00ff);
    }
    if ( blockIdx.x==0 ) {
        pHist[threadIdx.x] = privHist[threadIdx.x];
    }
    return;
    
    __syncthreads();
    
    // now the top 32 rows have partial sums for bytes 0 and 2, and
    // the bottom 32 rows have partial sums for bytes 1 and 3
    //
    // do a log-step reduction by row
    //
    for ( int numRows = 16; numRows >= 1; numRows >>= 1 )  {
        for ( int i = 0; i < numRows; i++ ) {
            unsigned int *histBase02 = &privHist[i*64+threadIdx.x];
            histBase02[0] += histBase02[numRows*64];

            unsigned int *histBase13 = &privHist[(i+32)*64+threadIdx.x];
            histBase13[0] += histBase13[numRows*64];
        }
        __syncthreads();
    }

    // now row 0 has sums for bytes 0 and 2, and
    // row 32 has sums for bytes 1 and 3.

    if ( threadIdx.x < 32 ) {
        unsigned int sum02 = privHist[threadIdx.x];
        if ( sum02&0xffff ) atomicAdd( &pHist[threadIdx.x*4+0], sum02&0xffff );
        sum02 >>= 16;
        if ( sum02 ) atomicAdd( &pHist[threadIdx.x*4+2], sum02 );
    }
    else {
        unsigned int sum13 = privHist[64*32+threadIdx.x];
        if ( sum13&0xffff ) atomicAdd( &pHist[threadIdx.x*4+0], sum13&0xffff );
        sum13 >>= 16;
        if ( sum13 ) atomicAdd( &pHist[threadIdx.x*4+2], sum13 );
    }

#endif

#if 1
// this works and there is still room for improvement (by having threads 32-63 of the block do half the work)
// but we should be able to do a log-step reduction instead of looping 64 times.

    for ( int i = 0; i < 64; i++ ) {
        unsigned int sum;
        volatile unsigned int *histBase = &privHist[i*64+threadIdx.x];
        unsigned int myValue = histBase[0];
        unsigned int upperValue;
        if ( threadIdx.x < 32 ) {
            upperValue = histBase[32];
            histBase[ 0] = (myValue & 0xff00ff) + (upperValue & 0xff00ff);
            myValue >>= 8; upperValue >>= 8;
            histBase[32] = (myValue & 0xff00ff) + (upperValue & 0xff00ff);
        }
        __syncthreads();
        int offset = threadIdx.x<32 ? 16 : -16;
        histBase[0] += histBase[offset]; offset >>= 1;
        histBase[0] += histBase[offset]; offset >>= 1;
        histBase[0] += histBase[offset]; offset >>= 1;
        histBase[0] += histBase[offset]; offset >>= 1;
        sum = histBase[0] + histBase[offset];
        if ( threadIdx.x==0 ) atomicAdd( &pHist[i*4+0], sum&0xffff );
        if ( threadIdx.x==63 ) atomicAdd( &pHist[i*4+1], sum&0xffff );
        sum >>= 16;
        if ( threadIdx.x==0 ) atomicAdd( &pHist[i*4+2], sum&0xffff );
        if (threadIdx.x==63) atomicAdd( &pHist[i*4+3], sum&0xffff );
    }
#if 0
    for ( int i = 0; i < 64; i++ ) {
        unsigned int count = privHist[i*64/*blockDim.x*/+threadIdx.x];
        atomicAdd( &pHist[i*4+0], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[i*4+1], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[i*4+2], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[i*4+3], count );
    }
#endif
#else

    for ( int i = threadIdx.x;
              i < 64*blockDim.x;
              i += blockDim.x ) {
        int idx = i & 63;
        unsigned int count = privHist[i];
        atomicAdd( &pHist[idx*4+0], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[idx*4+1], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[idx*4+2], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[idx*4+3], count );
    }
#endif
}

void
GPUhistogramPrivatizedPerThread32(
    float *ms,
    unsigned int *pHist,
    const unsigned char *dptrBase, size_t dPitch,
    int x, int y,
    int w, int h, 
    dim3 threads )
{
    cudaError_t status;
    cudaEvent_t start = 0, stop = 0;
    int numthreads = threads.x*threads.y;
    int numblocks = INTDIVIDE_CEILING( w*h, numthreads*255 );

    CUDART_CHECK( cudaEventCreate( &start, 0 ) );
    CUDART_CHECK( cudaEventCreate( &stop, 0 ) );

    CUDART_CHECK( cudaMemset( pHist, 0, 256*sizeof(unsigned int) ) );

    CUDART_CHECK( cudaEventRecord( start, 0 ) );
    histogram1DPrivatizedPerThread32<<<numblocks,numthreads,numthreads*256>>>( pHist, dptrBase, w*h );
    CUDART_CHECK( cudaEventRecord( stop, 0 ) );
    CUDART_CHECK( cudaDeviceSynchronize() );
    CUDART_CHECK( cudaEventElapsedTime( ms, start, stop ) );
Error:
    cudaEventDestroy( start );
    cudaEventDestroy( stop );
    return;
}
