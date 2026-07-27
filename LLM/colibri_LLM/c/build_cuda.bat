@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d C:\Users\autismo\Documents\GitHub\GodBrain\LLM\colibri_LLM\c
"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3\bin\nvcc" -O3 -std=c++17 -arch=sm_89 -Xcompiler="-W3 /arch:AVX2" -shared -DCOLI_CUDA_BUILDING_DLL -L"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3\lib/x64" -lcudart backend_cuda.cu -o coli_cuda.dll
echo EXITCODE=%ERRORLEVEL%
