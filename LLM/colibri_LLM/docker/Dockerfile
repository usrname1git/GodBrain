# Build this image with `LLM/colibri_LLM` as the build context, e.g. from the
# repository root:
#   docker build -f LLM/colibri_LLM/docker/Dockerfile -t colibri-i LLM/colibri_LLM
# or, with the terminal already inside LLM/colibri_LLM:
#   docker build -f docker/Dockerfile -t colibri-i .
# This builds the engine from the current checkout instead of cloning an
# upstream repository, so the image always matches the sources on disk.
FROM debian:stable-slim

# We install the necessary packages to compile the code
RUN apt-get update && \
	apt-get install -y locales build-essential python3 python3-pip && \
	rm -rf /var/lib/apt/lists/* && \
	mkdir /app

# Copy only the engine sources needed to build and run colibri (the `c/`
# directory is self-contained: Makefile, setup.sh, the `coli` CLI, and the
# C/CUDA/Metal sources).
WORKDIR /app
COPY c/ ./c/

WORKDIR /app/c
# It's time to compile
RUN sed -i 's/\r$//' setup.sh coli && \
	chmod +x setup.sh coli && \
	./setup.sh && \
	./coli build
