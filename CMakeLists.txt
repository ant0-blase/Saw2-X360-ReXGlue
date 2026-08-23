# saw2 - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake. That file is refreshed by
# ReXGlue codegen and must stay aligned with the version recorded by the
# manifest.

cmake_minimum_required(VERSION 3.25)
project(saw2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(generated/rexglue.cmake)

set(SAW2_SOURCES
    src/main.cpp
)

if(WIN32)
    add_executable(saw2 WIN32 ${SAW2_SOURCES})
else()
    add_executable(saw2 ${SAW2_SOURCES})
endif()

rexglue_setup_target(saw2 GPU_PLUGINS xenos)
